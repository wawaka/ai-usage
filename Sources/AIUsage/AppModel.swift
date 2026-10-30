import AIUsageCore
import AppKit
import Combine
import ServiceManagement
import UserNotifications

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

    @Published var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }
    @Published var titleMode: TitleMode { didSet { defaults.set(titleMode.rawValue, forKey: "titleMode") } }
    @Published var titleStyle: TitleStyle { didSet { defaults.set(titleStyle.rawValue, forKey: "titleStyle") } }
    @Published var profile: BurnProfile { didSet { defaults.set(profile.rawValue, forKey: "profile") } }
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
        refreshMinutes = defaults.object(forKey: "refreshMinutes") as? Int ?? 5
        titleMode = TitleMode(rawValue: defaults.string(forKey: "titleMode") ?? "") ?? .auto
        titleStyle = TitleStyle(rawValue: defaults.string(forKey: "titleStyle") ?? "") ?? .bars
        profile = BurnProfile(rawValue: defaults.string(forKey: "profile") ?? "") ?? .low
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
    @Published private(set) var isRefreshing = false
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

        settings.$refreshMinutes.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.scheduleTimer() }
        }.store(in: &cancellables)
        settings.$profile.dropFirst().sink { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                await self.service.setProfile(p)
                self.refresh()
            }
        }.store(in: &cancellables)
        settings.$readClaudeKeychain.dropFirst().sink { [weak self] on in
            Task { @MainActor in
                self?.keychain.enabled = on
                self?.refresh()
            }
        }.store(in: &cancellables)

        Task {
            await service.setProfile(settings.profile)
            statuses = await service.cachedStatuses()
            await reloadAccounts()
            refresh()
        }
        scheduleTimer()
        // Refresh right after the Mac wakes instead of waiting for the next tick.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(1, settings.refreshMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 15
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let result = await service.refreshAll()
            statuses = result
            lastRefresh = Date()
            isRefreshing = false
            await reloadAccounts()
            notifyIfNeeded(result)
        }
    }

    func reloadAccounts() async {
        accounts = await service.allAccounts()
        hiddenIDs = await service.state.hidden
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
            let atLimit = status.analysis?.state == .limitRisk || status.analysis?.state == .depleted
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
