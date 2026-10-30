import AIUsageCore
import AppKit
import Network

/// One-shot HTTP server on 127.0.0.1 that captures the OAuth redirect.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let path: String
    private let queue = DispatchQueue(label: "ai-usage.loopback")
    private var continuation: CheckedContinuation<URLComponents, Error>?
    private var result: URLComponents?
    private var finished = false

    init(port: UInt16?, path: String) throws {
        self.path = path
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        listener = try NWListener(using: params)
    }

    /// Starts listening and returns the bound port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            // State callbacks run on `queue`, so this flag is only touched serially.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    cont.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let error):
                    once.done = true
                    cont.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> URLComponents {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let result = self.result { cont.resume(returning: result) } else { self.continuation = cont }
            }
        }
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            if !self.finished { self.finished = true; self.continuation?.resume(throwing: CancellationError()) }
            self.continuation = nil
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let comps = URLComponents(string: "http://localhost\(target)")
            let matches = comps?.path == self.path
            let body = matches
                ? "<html><body style='font:16px -apple-system;padding:40px'><h2>AI Usage</h2><p>Sign-in received. You can close this tab.</p></body></html>"
                : "Not found"
            let response = "HTTP/1.1 \(matches ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if matches, let comps, !self.finished {
                self.finished = true
                self.result = comps
                self.continuation?.resume(returning: comps)
                self.continuation = nil
                self.listener.cancel()
            }
        }
    }
}

/// Drives a browser sign-in for one new account.
@MainActor
final class LoginController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case waiting(url: URL, canPaste: Bool, manual: Bool)
        case exchanging
        case done(String)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var pasted = ""
    let provider: ProviderKind
    private let model: AppModel
    private let oauth: OAuthProvider
    private let client = URLSessionHTTPClient()
    private var pkce = PKCE()
    private var redirectURI = ""
    private var server: LoopbackServer?
    private var task: Task<Void, Never>?

    init?(provider: ProviderKind, model: AppModel) {
        guard let oauth = OAuthProviders.forProvider(provider) else { return nil }
        self.provider = provider
        self.model = model
        self.oauth = oauth
    }

    var supportsManualCode: Bool { oauth.manualRedirectURI != nil }

    /// `manual`: use the provider's hosted page that shows a code to paste (Claude only).
    func start(manual: Bool = false) {
        cancel()
        pkce = PKCE()
        task = Task {
            do {
                if manual, let manualURI = oauth.manualRedirectURI {
                    redirectURI = manualURI
                    let url = oauth.authorizeURL(pkce: pkce, redirectURI: redirectURI, manual: true)
                    phase = .waiting(url: url, canPaste: true, manual: true)
                    NSWorkspace.shared.open(url)
                    return // completes via submitPasted
                }
                let server = try LoopbackServer(port: oauth.loopbackPort, path: oauth.loopbackPath)
                self.server = server
                let port = try await server.start()
                redirectURI = "http://localhost:\(port)\(oauth.loopbackPath)"
                let url = oauth.authorizeURL(pkce: pkce, redirectURI: redirectURI, manual: false)
                phase = .waiting(url: url, canPaste: true, manual: false)
                NSWorkspace.shared.open(url)
                let comps = try await server.waitForCallback()
                let items = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
                await finish(code: items["code"], state: items["state"], error: items["error_description"] ?? items["error"])
            } catch is CancellationError {
            } catch {
                let port = oauth.loopbackPort.map { " (is another sign-in, e.g. `codex login`, using port \($0)?)" } ?? ""
                phase = .failed("Could not start sign-in: \(error.localizedDescription)\(port)")
            }
        }
    }

    /// Accepts a pasted code (`code#state`) or the full redirect URL from the browser's address bar.
    func submitPasted(_ text: String) {
        let parsed = parseOAuthCallback(text)
        server?.stop()
        Task { await finish(code: parsed.code, state: parsed.state, error: parsed.error) }
    }

    private func finish(code: String?, state: String?, error: String?) async {
        if let error { phase = .failed("Authorization failed: \(error)"); return }
        guard let code, !code.isEmpty else { phase = .failed("No authorization code received"); return }
        if let state, !state.isEmpty, state != pkce.state { phase = .failed("State mismatch — please start again"); return }
        phase = .exchanging
        do {
            let token = try await oauth.exchange(code: code, pkce: pkce, redirectURI: redirectURI, client: client)
            let label = await oauth.identity(token, client: client) ?? "\(provider.displayName) account"
            try await model.addManaged(provider: provider, label: label, credential: .oauth(token))
            phase = .done(label)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func cancel() {
        task?.cancel()
        server?.stop()
        server = nil
        if case .done = phase { return }
        phase = .idle
    }
}
