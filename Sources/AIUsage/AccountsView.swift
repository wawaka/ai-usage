import AIUsageCore
import SwiftUI

// View state lives in ObservableObjects instead of @State: with only the Command Line Tools
// installed, newer SDKs lack the SwiftUI macro plugin that @State needs.
final class Flag: ObservableObject {
    @Published var value = false
}

@MainActor
final class AccountsUIState: ObservableObject {
    @Published var adding: ProviderKind?
    @Published var renaming: Account?
    @Published var newName = ""
}

@MainActor
final class APIKeyForm: ObservableObject {
    @Published var name = ""
    @Published var key = ""
    @Published var region = "default"
    @Published var error: String?
    @Published var saving = false
}

struct AccountsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var ui = AccountsUIState()

    private var local: [Account] { model.accounts.filter(\.isLocal) }
    private var managed: [Account] { model.accounts.filter { !$0.isLocal } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.deniedKeychainItems.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    Text("Keychain access to \(model.deniedKeychainItems.sorted().joined(separator: ", ")) was denied, so AI Usage won't ask again.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Try again") { model.retryKeychainAccess() }
                }
                .padding(12)
                Divider()
            }
            List {
                Section {
                    if local.isEmpty {
                        Text("Nothing found. AI Usage reads Claude Code, Codex CLI, OpenCode, Pi and claude-lanes credentials, plus GLM/Kimi/MiniMax keys configured in Claude Code settings.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(local) { row($0) }
                } header: {
                    Text("Found on this Mac (read-only)")
                } footer: {
                    Text("These are only read, never changed. Tokens are not refreshed by AI Usage; if one expires, open the tool that owns it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Added in AI Usage") {
                    if managed.isEmpty {
                        Text("Sign in to more accounts, including several of the same provider.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(managed) { row($0) }
                }
            }
            Divider()
            HStack {
                Menu("Add Account") {
                    ForEach(ProviderKind.allCases) { p in
                        Button(p.usesOAuth ? "\(p.displayName) — sign in with browser…" : "\(p.displayName) — API key…") { ui.adding = p }
                    }
                }
                .fixedSize()
                Spacer()
                Button("Rescan") { model.refresh() }
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 420)
        .sheet(item: $ui.adding) { provider in
            if provider.usesOAuth, let login = LoginController(provider: provider, model: model) {
                OAuthLoginSheet(login: login) { ui.adding = nil }
            } else {
                APIKeySheet(provider: provider, model: model) { ui.adding = nil }
            }
        }
        .alert("Rename account", isPresented: Binding(get: { ui.renaming != nil }, set: { if !$0 { ui.renaming = nil } })) {
            TextField("Name", text: $ui.newName)
            Button("Save") { if let a = ui.renaming { model.rename(a, to: ui.newName) }; ui.renaming = nil }
            Button("Cancel", role: .cancel) { ui.renaming = nil }
        }
    }

    @ViewBuilder
    private func row(_ account: Account) -> some View {
        HStack(spacing: 10) {
            ProviderMark(provider: account.provider, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.label).font(.body)
                Text(account.sourceDescription).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Toggle("Show", isOn: Binding(get: { !model.hiddenIDs.contains(account.id) },
                                         set: { model.setHidden(account, !$0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .help("Show in menu bar")
            Menu {
                Button("Rename…") { ui.newName = account.label; ui.renaming = account }
                if !account.isLocal {
                    Button("Remove", role: .destructive) { model.remove(account) }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.vertical, 2)
    }
}

struct OAuthLoginSheet: View {
    @StateObject var login: LoginController
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProviderMark(provider: login.provider, size: 24)
                Text("Sign in to \(login.provider.displayName)").font(.title3.bold())
            }
            switch login.phase {
            case .idle:
                Text("Your browser will open the \(login.provider.displayName) sign-in page. The account you choose is added to AI Usage only; other apps' logins are not touched.")
                    .fixedSize(horizontal: false, vertical: true)
                if login.provider == .claude {
                    Text("To add another account, switch accounts on claude.ai in the browser first.").font(.caption).foregroundStyle(.secondary)
                }
            case .waiting(let url, _, let manual):
                Text(manual
                     ? "Authorize in the browser, then paste the code shown on the page."
                     : "Waiting for the browser… If the browser is on another device or the page fails to load, paste the final URL from its address bar.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField(manual ? "Paste code" : "Paste redirect URL (optional)", text: $login.pasted)
                        .textFieldStyle(.roundedBorder)
                    Button("Submit") { login.submitPasted(login.pasted) }.disabled(login.pasted.isEmpty)
                }
                HStack {
                    Button("Copy sign-in link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    if !manual && login.supportsManualCode {
                        Button("Use a code instead") { login.start(manual: true) }
                    }
                    if !manual { ProgressView().controlSize(.small) }
                }
            case .exchanging:
                HStack { ProgressView().controlSize(.small); Text("Finishing sign-in…") }
            case .done(let label):
                Label("Added \(label)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                switch login.phase {
                case .done:
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                case .idle, .failed:
                    Button("Cancel") { login.cancel(); close() }
                    Button(login.phase == .idle ? "Open Browser" : "Try Again") { login.start() }.keyboardShortcut(.defaultAction)
                default:
                    Button("Cancel") { login.cancel(); close() }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct APIKeySheet: View {
    let provider: ProviderKind
    @ObservedObject var model: AppModel
    let close: () -> Void
    @StateObject private var form = APIKeyForm()

    private var regions: [(String, String)] {
        switch provider {
        case .glm: return [("default", "open.bigmodel.cn (China)"), ("intl", "api.z.ai (International)")]
        case .minimax: return [("default", "api.minimaxi.com (China)"), ("intl", "api.minimax.io (International)")]
        default: return []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProviderMark(provider: provider, size: 24)
                Text("Add \(provider.displayName) API key").font(.title3.bold())
            }
            Form {
                TextField("Name", text: $form.name, prompt: Text("\(provider.displayName) account"))
                SecureField("API key", text: $form.key)
                if !regions.isEmpty {
                    Picker("Endpoint", selection: $form.region) {
                        ForEach(regions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
            }
            Text(provider == .deepseek ? "DeepSeek reports account balance, not usage windows." : "Usage is read from the provider's quota API with this key. The key is stored in your login Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = form.error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", action: close)
                Button("Add") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.key.trimmingCharacters(in: .whitespaces).isEmpty || form.saving)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() async {
        form.saving = true
        defer { form.saving = false }
        let trimmed = form.key.trimmingCharacters(in: .whitespacesAndNewlines)
        var cred = APIKeyCredential(key: trimmed)
        switch provider {
        case .glm: cred.baseURL = form.region == "intl" ? GLM.internationalBaseURL : GLM.defaultBaseURL
        case .minimax: cred.region = form.region == "intl" ? "global" : "cn"
        default: break
        }
        // Validate before saving so typos surface immediately.
        do {
            _ = try await UsageFetcher.fetch(provider, credential: .apiKey(cred), client: URLSessionHTTPClient())
        } catch {
            form.error = "Check failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            return
        }
        do {
            try await model.addManaged(provider: provider, label: form.name.isEmpty ? "\(provider.displayName) account" : form.name, credential: .apiKey(cred))
            close()
        } catch {
            form.error = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Show", selection: $settings.titleMode) {
                    ForEach(TitleMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Style", selection: $settings.titleStyle) {
                    ForEach(TitleStyle.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Updates") {
                Picker("Refresh every", selection: $settings.refreshMinutes) {
                    ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                Toggle("Show remaining quota instead of used", isOn: $settings.showRemaining)
                Toggle("Notify when an account nears its limit", isOn: $settings.notifyAtLimit)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
            Section {
                Toggle("Read Claude Code login from Keychain", isOn: $settings.readClaudeKeychain)
            } footer: {
                Text("macOS asks once before AI Usage can read it; AI Usage then keeps a copy in its own Keychain item and asks again only when that token expires. Choose “Allow” to keep Claude Code's item unchanged. If you deny, it won't ask again until you turn this back on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
