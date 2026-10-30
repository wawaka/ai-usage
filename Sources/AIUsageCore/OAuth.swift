import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Browser OAuth (PKCE) against the public clients used by Claude Code and Codex CLI.
/// Tokens obtained here belong to AI Usage only; tokens read from other tools are never refreshed.
public protocol OAuthProvider: Sendable {
    /// Fixed loopback port, or nil for "any free port".
    var loopbackPort: UInt16? { get }
    var loopbackPath: String { get }
    /// Redirect used when the browser cannot reach localhost; the page shows a code to paste.
    var manualRedirectURI: String? { get }
    func authorizeURL(pkce: PKCE, redirectURI: String, manual: Bool) -> URL
    func exchange(code: String, pkce: PKCE, redirectURI: String, client: HTTPClient) async throws -> OAuthToken
    func refresh(_ token: OAuthToken, client: HTTPClient) async throws -> OAuthToken
    /// Best-effort account label (email) for a new login.
    func identity(_ token: OAuthToken, client: HTTPClient) async -> String?
}

public enum OAuthProviders {
    public static func forProvider(_ p: ProviderKind) -> OAuthProvider? {
        switch p {
        case .claude: return ClaudeOAuth()
        case .codex: return CodexOAuth()
        default: return nil
        }
    }
}

/// Parses what the user pasted: a full redirect URL, a query string, or Anthropic's `code#state`.
public func parseOAuthCallback(_ text: String) -> (code: String?, state: String?, error: String?) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var query: String?
    if t.contains("://"), let comps = URLComponents(string: t) {
        query = comps.percentEncodedQuery
    } else if t.hasPrefix("?") || t.contains("code=") {
        query = String(t.drop { $0 == "?" })
    }
    if let query {
        var items: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            items[kv[0]] = kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]
        }
        return (items["code"], items["state"], items["error_description"] ?? items["error"])
    }
    let parts = t.split(separator: "#", maxSplits: 1).map(String.init)
    return (parts.first, parts.count > 1 ? parts[1] : nil, nil)
}

func tokenFromResponse(_ obj: [String: Any], previous: OAuthToken? = nil) throws -> OAuthToken {
    guard let access = string(obj["access_token"]) else { throw UsageError.decoding("token response missing access_token") }
    let expires = number(obj["expires_in"]).map { Date().addingTimeInterval($0) }
    return OAuthToken(accessToken: access,
                      refreshToken: string(obj["refresh_token"]) ?? previous?.refreshToken,
                      expiresAt: expires,
                      accountId: previous?.accountId,
                      idToken: string(obj["id_token"]) ?? previous?.idToken)
}

public struct ClaudeOAuth: OAuthProvider {
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let scopes = "org:create_api_key user:profile user:inference"
    // The token endpoint moved hosts; try the new one first.
    public static let tokenURLs = [
        URL(string: "https://platform.claude.com/v1/oauth/token")!,
        URL(string: "https://console.anthropic.com/v1/oauth/token")!,
    ]

    public init() {}
    public var loopbackPort: UInt16? { nil }
    public var loopbackPath: String { "/callback" }
    public var manualRedirectURI: String? { "https://console.anthropic.com/oauth/code/callback" }

    public func authorizeURL(pkce: PKCE, redirectURI: String, manual: Bool) -> URL {
        var c = URLComponents(string: "https://claude.ai/oauth/authorize")!
        c.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return c.url!
    }

    func post(_ body: [String: Any], client: HTTPClient) async throws -> [String: Any] {
        var lastError: Error = UsageError.other("no token endpoint")
        for url in Self.tokenURLs {
            do { return try await HTTP.postJSON(client, url, body) } catch let e as UsageError {
                // Only fall through to the legacy host when the endpoint itself looks missing.
                if case .http(let code, _) = e, code == 404 || code == 405 || code >= 500 { lastError = e; continue }
                throw e
            } catch { lastError = error; continue }
        }
        throw lastError
    }

    public func exchange(code: String, pkce: PKCE, redirectURI: String, client: HTTPClient) async throws -> OAuthToken {
        try tokenFromResponse(try await post([
            "grant_type": "authorization_code", "code": code, "state": pkce.state,
            "client_id": Self.clientID, "redirect_uri": redirectURI, "code_verifier": pkce.verifier,
        ], client: client))
    }

    public func refresh(_ token: OAuthToken, client: HTTPClient) async throws -> OAuthToken {
        guard let rt = token.refreshToken else { throw UsageError.unauthorized("no refresh token; sign in again") }
        return try tokenFromResponse(try await post([
            "grant_type": "refresh_token", "refresh_token": rt, "client_id": Self.clientID,
        ], client: client), previous: token)
    }

    public func identity(_ token: OAuthToken, client: HTTPClient) async -> String? {
        await Claude.profile(token: token, client: client).email
    }
}

public struct CodexOAuth: OAuthProvider {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    public init() {}
    /// The Codex client only accepts this redirect port.
    public var loopbackPort: UInt16? { 1455 }
    public var loopbackPath: String { "/auth/callback" }
    public var manualRedirectURI: String? { nil }

    public func authorizeURL(pkce: PKCE, redirectURI: String, manual: Bool) -> URL {
        var c = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        c.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
            // Always show the account picker so a second ChatGPT account can be added.
            URLQueryItem(name: "prompt", value: "login"),
        ]
        return c.url!
    }

    public func exchange(code: String, pkce: PKCE, redirectURI: String, client: HTTPClient) async throws -> OAuthToken {
        var token = try tokenFromResponse(try await HTTP.postForm(client, Self.tokenURL, [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": Self.clientID, "code_verifier": pkce.verifier,
        ]))
        token.accountId = Codex.accountId(fromJWT: token.idToken ?? "") ?? Codex.accountId(fromJWT: token.accessToken)
        return token
    }

    public func refresh(_ token: OAuthToken, client: HTTPClient) async throws -> OAuthToken {
        guard let rt = token.refreshToken else { throw UsageError.unauthorized("no refresh token; sign in again") }
        return try tokenFromResponse(try await HTTP.postJSON(client, Self.tokenURL, [
            "client_id": Self.clientID, "grant_type": "refresh_token", "refresh_token": rt,
            "scope": "openid profile email",
        ]), previous: token)
    }

    public func identity(_ token: OAuthToken, client: HTTPClient) async -> String? {
        Codex.email(fromJWT: token.idToken ?? "") ?? Codex.email(fromJWT: token.accessToken)
    }
}
