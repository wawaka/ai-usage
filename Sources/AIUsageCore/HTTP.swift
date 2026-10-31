import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    /// Header fields with lowercased names.
    public var headers: [String: String]

    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        var request = request
        if request.timeoutInterval > 30 { request.timeoutInterval = 20 }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] {
            if let k = k as? String { headers[k.lowercased()] = "\(v)" }
        }
        return HTTPResponse(status: http?.statusCode ?? 0, body: data, headers: headers)
    }
}

enum HTTP {
    static let userAgent = "ai-usage/1.0"

    static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    /// Sends and returns the parsed JSON object, mapping auth failures to `.unauthorized`.
    static func json(_ client: HTTPClient, _ request: URLRequest) async throws -> [String: Any] {
        let response = try await client.send(request)
        let snippet = String(decoding: response.body.prefix(300), as: UTF8.self)
        if response.status == 401 || response.status == 403 {
            throw UsageError.unauthorized(snippet)
        }
        if response.status == 429 {
            throw UsageError.rateLimited(retryAfter: retryAfter(response.headers["retry-after"]))
        }
        guard (200..<300).contains(response.status) else {
            throw UsageError.http(response.status, snippet)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw UsageError.decoding(snippet)
        }
        return obj
    }

    static func postJSON(_ client: HTTPClient, _ url: URL, _ body: [String: Any]) async throws -> [String: Any] {
        var req = request(url, method: "POST", headers: ["Content-Type": "application/json"])
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await json(client, req)
    }

    /// `Retry-After` as seconds from now: either delta-seconds or an HTTP date.
    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return max(0, seconds) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    static func postForm(_ client: HTTPClient, _ url: URL, _ body: [String: String]) async throws -> [String: Any] {
        var req = request(url, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"])
        req.httpBody = formEncode(body).data(using: .utf8)
        return try await json(client, req)
    }

    static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }
}

// MARK: - Loose JSON accessors (provider payloads are inconsistent about types)

func number(_ value: Any?) -> Double? {
    switch value {
    case let d as Double: return d.isFinite ? d : nil
    case let i as Int: return Double(i)
    case let n as NSNumber: return n.doubleValue
    case let s as String:
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : Double(t)
    default: return nil
    }
}

func string(_ value: Any?) -> String? {
    switch value {
    case let s as String: return s.isEmpty ? nil : s
    case let n as NSNumber: return n.stringValue
    default: return nil
    }
}

func dict(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

func parseISODate(_ value: Any?) -> Date? {
    guard let s = string(value) else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFraction.date(from: s) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let d = plain.date(from: s) { return d }
    // Python-style microseconds ("2026-10-30T15:00:00.386242+00:00"): trim to millis.
    if let dot = s.firstIndex(of: "."),
       let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
        let frac = s[s.index(after: dot)..<tz].prefix(3)
        return withFraction.date(from: String(s[..<dot]) + "." + frac + String(s[tz...]))
    }
    return nil
}

/// Epoch value that may be seconds or milliseconds.
func parseEpoch(_ value: Any?) -> Date? {
    guard let n = number(value), n > 0 else { return nil }
    return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
}

// MARK: - JWT

public enum JWT {
    public static func claims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let data = base64URLDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
