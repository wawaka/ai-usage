import Foundation

/// A credential found on disk / in the Keychain of another tool.
public struct DiscoveredCredential: Sendable {
    public var account: Account
    public var credential: Credential
    /// Tool name used in "open <tool> to renew" hints.
    public var tool: String
}

/// Read access to Keychain generic passwords (implemented with Security.framework on macOS).
public protocol KeychainReading: Sendable {
    /// Services/accounts of generic passwords whose service starts with `prefix`. Must not read secret data.
    func items(servicePrefix: String) -> [(service: String, account: String)]
    /// Secret data for one item. May show a macOS access prompt.
    func data(service: String, account: String) -> Data?
    /// Forget any cached secret so the next `data` call reads the Keychain again.
    func invalidate(service: String)
}

public extension KeychainReading {
    func invalidate(service: String) {}
}

/// Finds credentials other AI tools stored locally. Strictly read-only: it only opens files for
/// reading and never refreshes, rewrites or deletes anything it finds.
public struct LocalDiscovery: Sendable {
    public var home: URL
    public var environment: [String: String]
    public var keychain: KeychainReading?

    public init(home: URL = AppPaths.userHome,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                keychain: KeychainReading? = nil) {
        self.home = home
        self.environment = environment
        self.keychain = keychain
    }

    public func discover() -> [DiscoveredCredential] {
        var found: [DiscoveredCredential] = []
        found += claudeCode()
        found += codex()
        found += openCode()
        found += pi()
        found += anthropicCompatibleEnvs()
        return dedupe(found)
    }

    // MARK: helpers

    func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func tilde(_ url: URL) -> String {
        let p = url.path
        return p.hasPrefix(home.path) ? "~" + p.dropFirst(home.path.count) : p
    }

    /// Hidden dirs in $HOME whose name starts with `prefix` (".claude", ".claude-work", ...).
    func homeDirs(prefix: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return names.filter { $0 == prefix || $0.hasPrefix(prefix + "-") || $0.hasPrefix(prefix + "_") }
            .sorted()
            .map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0.path, isDirectory: &d) && d.boolValue }
    }

    func dedupe(_ list: [DiscoveredCredential]) -> [DiscoveredCredential] {
        var seen = Set<String>()
        return list.filter { item in
            let key: String
            switch item.credential {
            case .oauth(let t): key = "\(item.account.provider.rawValue):\(t.refreshToken ?? t.accessToken)"
            case .apiKey(let k): key = "\(item.account.provider.rawValue):\(k.key)"
            }
            return seen.insert(key).inserted
        }
    }

    // MARK: Claude Code

    /// Email stored by Claude Code next to its credentials (`.claude.json` → oauthAccount.emailAddress).
    func claudeEmail(configDir: URL) -> String? {
        let candidates = configDir.lastPathComponent == ".claude"
            ? [home.appendingPathComponent(".claude.json"), configDir.appendingPathComponent(".claude.json")]
            : [configDir.appendingPathComponent(".claude.json")]
        for url in candidates {
            if let email = string(dict(readJSON(url)?["oauthAccount"])?["emailAddress"]) { return email }
        }
        return nil
    }

    func claudeToken(_ blob: [String: Any]?) -> OAuthToken? {
        guard let o = dict(blob?["claudeAiOauth"]), let access = string(o["accessToken"]) else { return nil }
        return OAuthToken(accessToken: access, refreshToken: string(o["refreshToken"]), expiresAt: parseEpoch(o["expiresAt"]))
    }

    func claudeCode() -> [DiscoveredCredential] {
        var out: [DiscoveredCredential] = []
        var dirs = homeDirs(prefix: ".claude")
        if let custom = environment["CLAUDE_CONFIG_DIR"] { dirs.insert(URL(fileURLWithPath: custom), at: 0) }
        for dir in dirs {
            let file = dir.appendingPathComponent(".credentials.json")
            guard let token = claudeToken(readJSON(file)) else { continue }
            let label = claudeEmail(configDir: dir) ?? "Claude Code (\(tilde(dir)))"
            out.append(DiscoveredCredential(
                account: Account(id: "local:claude-code:\(tilde(file))", provider: .claude, label: label,
                                 origin: .local(source: "Claude Code · \(tilde(file))")),
                credential: .oauth(token), tool: "Claude Code"))
        }
        // On macOS Claude Code keeps credentials in the login Keychain instead of a file.
        if let keychain {
            for item in keychain.items(servicePrefix: "Claude Code-credentials") {
                guard let data = keychain.data(service: item.service, account: item.account),
                      let blob = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = claudeToken(blob) else { continue }
                let label = item.service == "Claude Code-credentials"
                    ? (claudeEmail(configDir: home.appendingPathComponent(".claude")) ?? "Claude Code")
                    : "Claude Code (\(item.service.dropFirst("Claude Code-credentials".count).trimmingCharacters(in: CharacterSet(charactersIn: "-"))))"
                out.append(DiscoveredCredential(
                    account: Account(id: "local:claude-code:keychain:\(item.service)", provider: .claude, label: label,
                                     origin: .local(source: "Claude Code · Keychain “\(item.service)”")),
                    credential: .oauth(token), tool: "Claude Code"))
            }
        }
        return out
    }

    // MARK: Codex CLI

    func codex() -> [DiscoveredCredential] {
        var dirs = homeDirs(prefix: ".codex")
        if let custom = environment["CODEX_HOME"] { dirs.insert(URL(fileURLWithPath: custom), at: 0) }
        var out: [DiscoveredCredential] = []
        for dir in dirs {
            let file = dir.appendingPathComponent("auth.json")
            guard let tokens = dict(readJSON(file)?["tokens"]), let access = string(tokens["access_token"]) else { continue }
            let idToken = string(tokens["id_token"])
            let token = OAuthToken(accessToken: access, refreshToken: string(tokens["refresh_token"]),
                                   expiresAt: parseEpoch(JWT.claims(access)["exp"]),
                                   accountId: string(tokens["account_id"]) ?? Codex.accountId(fromJWT: access),
                                   idToken: idToken)
            let label = Codex.email(fromJWT: idToken ?? "") ?? Codex.email(fromJWT: access) ?? "Codex (\(tilde(dir)))"
            out.append(DiscoveredCredential(
                account: Account(id: "local:codex:\(tilde(file))", provider: .codex, label: label,
                                 origin: .local(source: "Codex CLI · \(tilde(file))")),
                credential: .oauth(token), tool: "Codex"))
        }
        return out
    }

    // MARK: OpenCode

    func openCode() -> [DiscoveredCredential] {
        let files = [
            home.appendingPathComponent(".local/share/opencode/auth.json"),
            home.appendingPathComponent("Library/Application Support/opencode/auth.json"),
        ]
        var out: [DiscoveredCredential] = []
        for file in files {
            guard let auth = readJSON(file) else { continue }
            for (name, value) in auth.sorted(by: { $0.key < $1.key }) {
                guard let entry = dict(value) else { continue }
                let source = "OpenCode · \(tilde(file)) [\(name)]"
                let id = "local:opencode:\(tilde(file)):\(name)"
                if string(entry["type"]) == "oauth", let access = string(entry["access"]) {
                    let token = OAuthToken(accessToken: access, refreshToken: string(entry["refresh"]),
                                           expiresAt: parseEpoch(entry["expires"]),
                                           accountId: string(entry["accountId"]) ?? Codex.accountId(fromJWT: access))
                    if name == "anthropic" {
                        out.append(DiscoveredCredential(account: Account(id: id, provider: .claude, label: "Claude (OpenCode)", origin: .local(source: source)),
                                                        credential: .oauth(token), tool: "OpenCode"))
                    } else if name == "openai" || name == "openai-codex" {
                        let label = Codex.email(fromJWT: access).map { "\($0) (OpenCode)" } ?? "Codex (OpenCode)"
                        out.append(DiscoveredCredential(account: Account(id: id, provider: .codex, label: label, origin: .local(source: source)),
                                                        credential: .oauth(token), tool: "OpenCode"))
                    }
                } else if let key = string(entry["key"]), let (provider, cred) = classifyKeyProvider(name: name, key: key) {
                    out.append(DiscoveredCredential(account: Account(id: id, provider: provider, label: "\(provider.displayName) (OpenCode)", origin: .local(source: source)),
                                                    credential: .apiKey(cred), tool: "OpenCode"))
                }
            }
        }
        return out
    }

    /// Maps an OpenCode/Pi provider id holding an API key to one of our providers.
    func classifyKeyProvider(name: String, key: String) -> (ProviderKind, APIKeyCredential)? {
        let n = name.lowercased()
        if n.hasPrefix("zhipuai") { return (.glm, APIKeyCredential(key: key, baseURL: GLM.defaultBaseURL)) }
        if n == "zai" || n.hasPrefix("zai-") { return (.glm, APIKeyCredential(key: key, baseURL: GLM.internationalBaseURL)) }
        if n == "deepseek" { return (.deepseek, APIKeyCredential(key: key)) }
        if n.hasPrefix("minimax") { return (.minimax, APIKeyCredential(key: key, region: n.contains("cn") ? "cn" : "global")) }
        if n == "kimi-for-coding" || n == "kimi" { return (.kimi, APIKeyCredential(key: key)) }
        return nil
    }

    // MARK: Pi coding agent

    func pi() -> [DiscoveredCredential] {
        let file = home.appendingPathComponent(".pi/agent/auth.json")
        guard let auth = readJSON(file) else { return [] }
        var out: [DiscoveredCredential] = []
        for (name, value) in auth.sorted(by: { $0.key < $1.key }) {
            guard let entry = dict(value) else { continue }
            let source = "Pi · \(tilde(file)) [\(name)]"
            let id = "local:pi:\(name)"
            if let access = string(entry["access"]) {
                let token = OAuthToken(accessToken: access, refreshToken: string(entry["refresh"]), expiresAt: parseEpoch(entry["expires"]),
                                       accountId: string(entry["accountId"]) ?? Codex.accountId(fromJWT: access))
                if name == "anthropic" {
                    out.append(DiscoveredCredential(account: Account(id: id, provider: .claude, label: "Claude (Pi)", origin: .local(source: source)), credential: .oauth(token), tool: "Pi"))
                } else if name == "openai-codex" {
                    out.append(DiscoveredCredential(account: Account(id: id, provider: .codex, label: "Codex (Pi)", origin: .local(source: source)), credential: .oauth(token), tool: "Pi"))
                }
            } else if let key = string(entry["key"]), let (provider, cred) = classifyKeyProvider(name: name, key: key) {
                out.append(DiscoveredCredential(account: Account(id: id, provider: provider, label: "\(provider.displayName) (Pi)", origin: .local(source: source)), credential: .apiKey(cred), tool: "Pi"))
            }
        }
        return out
    }

    // MARK: Anthropic-compatible endpoints configured for Claude Code (GLM / Kimi / MiniMax plans)

    /// Maps an Anthropic-compatible base URL used with Claude Code to the provider's quota API.
    public static func classifyAnthropicBaseURL(_ base: String, token: String) -> (ProviderKind, APIKeyCredential)? {
        guard let host = URL(string: base)?.host?.lowercased() else { return nil }
        if host.hasSuffix("bigmodel.cn") { return (.glm, APIKeyCredential(key: token, baseURL: "https://\(host)")) }
        if host.hasSuffix("z.ai") { return (.glm, APIKeyCredential(key: token, baseURL: GLM.internationalBaseURL)) }
        if host.hasSuffix("kimi.com") { return (.kimi, APIKeyCredential(key: token, baseURL: Kimi.defaultBaseURL)) }
        if host.hasSuffix("minimaxi.com") { return (.minimax, APIKeyCredential(key: token, region: "cn")) }
        if host.hasSuffix("minimax.io") { return (.minimax, APIKeyCredential(key: token, region: "global")) }
        if host.hasSuffix("deepseek.com") { return (.deepseek, APIKeyCredential(key: token)) }
        return nil
    }

    func anthropicCompatibleEnvs() -> [DiscoveredCredential] {
        var out: [DiscoveredCredential] = []
        func add(base: String?, token: String?, id: String, source: String) {
            guard let base, let token, !token.isEmpty, let (provider, cred) = Self.classifyAnthropicBaseURL(base, token: token) else { return }
            out.append(DiscoveredCredential(account: Account(id: id, provider: provider, label: "\(provider.displayName) (\(source.components(separatedBy: " · ").first ?? source))",
                                                             origin: .local(source: source)),
                                            credential: .apiKey(cred), tool: provider.displayName))
        }
        // Claude Code settings.json "env" blocks.
        for dir in homeDirs(prefix: ".claude") {
            for name in ["settings.json", "settings.local.json"] {
                let file = dir.appendingPathComponent(name)
                guard let env = dict(readJSON(file)?["env"]) else { continue }
                add(base: string(env["ANTHROPIC_BASE_URL"]), token: string(env["ANTHROPIC_AUTH_TOKEN"]) ?? string(env["ANTHROPIC_API_KEY"]),
                    id: "local:claude-env:\(tilde(file))", source: "Claude Code settings · \(tilde(file))")
            }
        }
        // claude-lanes: CONFIG_<n>_BASE_URL / CONFIG_<n>_AUTH_TOKEN pairs.
        let lanes = home.appendingPathComponent(".config/claude-lanes/config.env")
        if let text = try? String(contentsOf: lanes, encoding: .utf8) {
            var entries: [String: String] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
                let key = t[..<eq].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "export ", with: "")
                entries[key] = t[t.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
            let indices = Set(entries.keys.compactMap { k -> Int? in
                guard k.hasPrefix("CONFIG_"), k.hasSuffix("_BASE_URL") else { return nil }
                return Int(k.dropFirst("CONFIG_".count).dropLast("_BASE_URL".count))
            }).sorted()
            for i in indices {
                add(base: entries["CONFIG_\(i)_BASE_URL"], token: entries["CONFIG_\(i)_AUTH_TOKEN"],
                    id: "local:claude-lanes:\(i)", source: "claude-lanes · \(tilde(lanes)) [\(i)]")
            }
        }
        // Process environment (useful for the CLI; GUI apps rarely inherit these).
        add(base: environment["ANTHROPIC_BASE_URL"], token: environment["ANTHROPIC_AUTH_TOKEN"] ?? environment["ANTHROPIC_API_KEY"],
            id: "local:env:anthropic", source: "Environment · ANTHROPIC_BASE_URL")
        return out
    }
}
