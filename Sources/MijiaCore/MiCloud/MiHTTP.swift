import Foundation

/// Minimal HTTP seam so login, cloud API and spec downloads can be stubbed in tests.
public protocol MiHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionMiTransport: MiHTTPTransport {
    private let session: URLSession
    private let followRedirects: Bool

    public init(timeout: TimeInterval = 30, followRedirects: Bool = true) {
        let config = URLSessionConfiguration.ephemeral
        // Cookies are attached by hand per request; a shared jar would leak one account's token into another login.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.followRedirects = followRedirects
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = followRedirects
            ? try await session.data(for: request)
            : try await session.data(for: request, delegate: NoRedirectDelegate())
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

extension JSONValue {
    /// Compact JSON with integral numbers written without a fraction (`40`, not `40.0`);
    /// MIoT rejects `40.0` for integer-format properties.
    public var compactJSONString: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            if n.isFinite, n == n.rounded(), abs(n) < 9.0e15 { return String(Int64(n)) }
            return String(n)
        case .string(let s): return Self.quote(s)
        case .array(let a): return "[" + a.map(\.compactJSONString).joined(separator: ",") + "]"
        case .object(let o):
            let body = o.keys.sorted().map { "\(Self.quote($0)):\(o[$0]!.compactJSONString)" }
            return "{" + body.joined(separator: ",") + "}"
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Mi APIs return ids as either numbers or strings.
    var idString: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int64(n)) : String(n)
        default: return nil
        }
    }
}

enum MiResponseText {
    static let startMarker = "&&&START&&&"

    static func parseJSON(_ data: Data) -> JSONValue? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix(startMarker) { text.removeFirst(startMarker.count) }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
