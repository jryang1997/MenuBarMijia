import Foundation

// MARK: - App Version

/// Dotted numeric version ("v1.10.0", "1.2"); trailing labels such as "-beta" are ignored.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") { text.removeFirst() }
        let core = text.split(whereSeparator: { $0 == "-" || $0 == "+" || $0 == " " }).first.map(String.init) ?? ""
        let numbers = core.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        var parts = numbers.compactMap { $0 }
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        self.parts = parts
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let l = i < lhs.parts.count ? lhs.parts[i] : 0
            let r = i < rhs.parts.count ? rhs.parts[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }
}

// MARK: - Update Checker

/// Reads the latest GitHub release of the repo. No auto-install: the app links to the release page,
/// so updates stay a deliberate user action until the build is Developer ID signed.
public struct UpdateChecker: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public enum Result: Equatable, Sendable {
        case upToDate
        case available(version: String, url: URL, notes: String)
    }

    public enum CheckError: LocalizedError, Equatable {
        case httpStatus(Int)
        case malformed

        public var errorDescription: String? {
            switch self {
            case .httpStatus(let code): return "检查更新失败（\(code)），稍后再试"
            case .malformed: return "检查更新失败：返回内容看不懂"
            }
        }
    }

    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/jryang1997/MenuBarMijia/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/jryang1997/MenuBarMijia/releases")!

    public let currentVersion: String
    private let transport: Transport

    public init(currentVersion: String, transport: Transport? = nil) {
        self.currentVersion = currentVersion
        self.transport = transport ?? { try await URLSession.shared.data(for: $0) }
    }

    /// The running app's CFBundleShortVersionString ("0" when run from `swift run`).
    public static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    public func check() async throws -> Result {
        var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 404 { return .upToDate }  // no release published yet
        guard (200..<300).contains(status) else { throw CheckError.httpStatus(status) }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let latest = AppVersion(tag) else { throw CheckError.malformed }
        guard let current = AppVersion(currentVersion), latest > current else { return .upToDate }
        let url = (object["html_url"] as? String).flatMap(URL.init(string:)) ?? Self.releasesPage
        let shown = tag.lowercased().hasPrefix("v") ? String(tag.dropFirst()) : tag
        return .available(version: shown, url: url, notes: object["body"] as? String ?? "")
    }
}
