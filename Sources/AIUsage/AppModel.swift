import AIUsageCore
import AppKit
import Combine
import ServiceManagement
@preconcurrency import UserNotifications

enum TitleMode: String, CaseIterable, Identifiable {
    case auto, full, single, icon
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (fit to menu bar)"
        case .full: return "All accounts"
        case .single: return "Most urgent account"
        case .icon: return "Icon only"
        }
    }
}

enum TitleStyle: String, CaseIterable, Identifiable {
    case bars, barsAndPercent, percent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bars: return "Bars"
        case .barsAndPercent: return "Bars + percent"
        case .percent: return "Percent"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Adaptive polling bounds: an account is polled every `pollMinMinutes` while its numbers change,
    /// backing off (doubling) up to `pollMaxMinutes` while they stay the same.
    @Published var pollMinMinutes: Int { didSet { defaults.set(pollMinMinutes, forKey: "pollMinMinutes") } }
    @Published var pollMaxMinutes: Int { didSet { defaults.set(pollMaxMinutes, forKey: "pollMaxMinutes") } }
    var pollPolicy: PollPolicy {
        PollPolicy(minInterval: TimeInterval(pollMinMinutes * 60), maxInterval: TimeInterval(pollMaxMinutes * 60))
    }
    @Published var titleMode: TitleMode { didSet { defaults.set(titleMode.rawValue, forKey: "titleMode") } }
    @Published var titleStyle: TitleStyle { didSet { defaults.set(titleStyle.rawValue, forKey: "titleStyle") } }
    /// Show how much quota is left instead of how much is used.
    @Published var showRemaining: Bool { didSet { defaults.set(showRemaining, forKey: "showRemaining") } }
    /// Usage refresh guide: an I-beam cursor on each usage bar at the point the window's time has reached.
    @Published var refreshGuide: Bool { didSet { defaults.set(refreshGuide, forKey: "refreshGuide") } }
    @Published var readClaudeKeychain: Bool { didSet { defaults.set(readClaudeKeychain, forKey: "readClaudeKeychain") } }
    @Published var notifyAtLimit: Bool { didSet { defaults.set(notifyAtLimit, forKey: "notifyAtLimit") } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("ai-usage: launch at login change failed: \(error)")
            }
        }
    }

    init() {
        pollMinMinutes = defaults.object(forKey: "pollMinMinutes") as? Int ?? 2
        pollMaxMinutes = defaults.object(forKey: "pollMaxMinutes") as? Int ?? 30
        titleMode = TitleMode(rawValue: defaults.string(forKey: "titleMode") ?? "") ?? .auto
        titleStyle = TitleStyle(rawValue: defaults.string(forKey: "titleStyle") ?? "") ?? .bars
        showRemaining = defaults.bool(forKey: "showRemaining")
        refreshGuide = defaults.object(forKey: "refreshGuide") as? Bool ?? true
        readClaudeKeychain = defaults.object(forKey: "readClaudeKeychain") as? Bool ?? true
        notifyAtLimit = defaults.object(forKey: "notifyAtLimit") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var statuses: [AccountStatus] = []
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var hiddenIDs: Set<String> = []
    /// Accounts shown in the panel but not in the menu bar title.
    @Published private(set) var notInMenuBarIDs: Set<String> = []
    /// Keychain items whose access prompt was denied (not asked again until retried).
    @Published private(set) var deniedKeychainItems: Set<String> = []
    /// Accounts with a fetch in flight (each shows its own spinner).
    @Published private(set) var refreshingIDs: Set<String> = []
    @Published private(set) var lastRefresh: Date?

    let settings: AppSettings
    let service: UsageService
    let keychain: SystemKeychainReader
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var alerted: Set<String> = []

    init(settings: AppSettings) {
        self.settings = settings
        let reader = SystemKeychainReader()
        reader.enabled = settings.readClaudeKeychain
        keychain = reader
        service = UsageService(secrets: KeychainSecretStore(), keychain: reader)

        settings.$pollMinMinutes.combineLatest(settings.$pollMaxMinutes).dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.service.setPolicy(self.settings.pollPolicy)
                self.poll()
            }
        }.store(in: &cancellables)
        settings.$readClaudeKeychain.dropFirst().sink { [weak self] on in
            Task { @MainActor in
                // Turning the option back on is an explicit request to be asked again.
                if on { self?.keychain.resetDenials() }
                self?.keychain.enabled = on
                self?.refresh()
            }
        }.store(in: &cancellables)

        Task {
            await service.setPolicy(settings.pollPolicy)
            statuses = await service.cachedStatuses()
            await reloadAccounts()
            refresh()
        }
        // Each account has its own adaptive schedule (UsageService); this tick only checks who is due.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer?.tolerance = 10
        // Update right after the Mac wakes instead of waiting for each account's next turn.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.service.markAllDue()
                self?.poll()
            }
        }
    }

    /// Fetches only the accounts whose automatic update is due.
    func poll() {
        Task {
            guard !(await service.dueAccounts()).isEmpty else { return }
            await rescanAndFetch { await $0.dueAccounts() }
        }
    }

    /// Re-reads local credentials and fetches every visible account now (accounts still inside a
    /// provider's rate limit are skipped by the service and keep showing when they can be tried).
    func refresh() {
        Task { await rescanAndFetch { await $0.visibleAccounts() } }
    }

    /// Fetches one account now.
    func refresh(_ account: Account) {
        fetch([account])
    }

    private func rescanAndFetch(_ pick: (UsageService) async -> [Account]) async {
        await service.rescan()
        let visible = await service.visibleAccounts()
        let cached = await service.cachedStatuses()
        // Keep current numbers (with fresh account names/order) while new ones load.
        statuses = visible.map { account in
            var s = statuses.first { $0.id == account.id } ?? cached.first { $0.id == account.id }
                ?? AccountStatus(account: account, snapshot: nil, error: nil, analysis: nil, lastAttempt: .distantPast)
            s.account = account
            return s
        }
        await reloadAccounts()
        fetch(await pick(service))
    }

    /// Each row updates as soon as its own request finishes; accounts already being fetched are skipped.
    private func fetch(_ accounts: [Account]) {
        let pending = accounts.filter { !refreshingIDs.contains($0.id) }
        refreshingIDs.formUnion(pending.map(\.id))
        for account in pending {
            Task {
                let status = await service.refresh(account)
                refreshingIDs.remove(account.id)
                if let i = statuses.firstIndex(where: { $0.id == account.id }) { statuses[i] = status }
                notifyIfNeeded([status])
                if refreshingIDs.isEmpty { lastRefresh = Date() }
            }
        }
    }

    func reloadAccounts() async {
        accounts = await service.allAccounts()
        hiddenIDs = await service.state.hidden
        notInMenuBarIDs = await service.state.notInMenuBar
        deniedKeychainItems = keychain.deniedServices
    }

    func retryKeychainAccess() {
        keychain.resetDenials()
        deniedKeychainItems = []
        refresh()
    }

    func setHidden(_ account: Account, _ hidden: Bool) {
        Task {
            await service.setHidden(account.id, hidden)
            await reloadAccounts()
            statuses = await service.cachedStatuses().map { cached in
                statuses.first { $0.id == cached.id } ?? cached
            }
        }
    }

    func setInMenuBar(_ account: Account, _ shown: Bool) {
        if shown { notInMenuBarIDs.remove(account.id) } else { notInMenuBarIDs.insert(account.id) }
        Task { await service.setInMenuBar(account.id, shown) }
    }

    func rename(_ account: Account, to name: String) {
        Task {
            await service.rename(account.id, to: name)
            await reloadAccounts()
            refresh()
        }
    }

    func remove(_ account: Account) {
        Task {
            await service.removeManaged(account.id)
            await reloadAccounts()
            statuses.removeAll { $0.id == account.id }
        }
    }

    func addManaged(provider: ProviderKind, label: String, credential: Credential) async throws {
        try await service.addManaged(provider: provider, label: label, credential: credential)
        await reloadAccounts()
        refresh()
    }

    // MARK: Notifications

    private func notifyIfNeeded(_ result: [AccountStatus]) {
        // UNUserNotificationCenter requires a real app bundle (not `swift run`).
        guard settings.notifyAtLimit, Bundle.main.bundleIdentifier != nil else { return }
        for status in result {
            let atLimit = status.analysis?.state == .limit || status.analysis?.state == .depleted
            if !atLimit { alerted.remove(status.id); continue }
            guard !alerted.contains(status.id) else { continue }
            alerted.insert(status.id)
            let content = UNMutableNotificationContent()
            content.title = "\(status.account.provider.displayName) usage is close to the limit"
            let pct = Format.bindingPercent(status.snapshot).map(Format.percent) ?? ""
            content.body = "\(status.account.label) \(pct)".trimmingCharacters(in: .whitespaces)
            let request = UNNotificationRequest(identifier: "limit-\(status.id)", content: content, trigger: nil)
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { center.add(request) }
            }
        }
    }
}
