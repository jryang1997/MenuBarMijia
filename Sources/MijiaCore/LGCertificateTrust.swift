import CryptoKit
import Foundation
#if os(macOS)
import Security
#endif

/// First-use trust for a configured LG TV. All access, including the first write, is serialized so
/// concurrent TLS challenges cannot replace a pin. Production pins live beside the pairing key in
/// Keychain; isolated test suites store fingerprints only, never pairing credentials.
final class LGCertificateTrust: @unchecked Sendable {
    static let shared = LGCertificateTrust()

    enum Failure: Equatable, Sendable, LocalizedError {
        case changed
        case unavailable

        var errorDescription: String? {
            switch self {
            case .changed:
                return L10n.tr(
                    "电视证书已变化，已拒绝连接。请核对电视地址后在设置中重新配对",
                    "The TV certificate changed; connection refused. Verify its address and pair again in Settings."
                )
            case .unavailable:
                return L10n.tr(
                    "无法保存或读取电视证书，已停止连接",
                    "The TV certificate could not be stored or read; connection stopped."
                )
            }
        }
    }

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private var failures: [String: Failure] = [:]

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
    }

    func accepts(certificate: Data, host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let host = Self.normalizedHost(host)
        guard !host.isEmpty, !certificate.isEmpty else {
            failures[host] = .unavailable
            return false
        }
        let account = Self.account(for: host)
        let fingerprint = Self.fingerprint(certificate)
        do {
            if let saved = try load(account) {
                guard saved == fingerprint else {
                    failures[host] = .changed
                    return false
                }
            } else {
                guard save(fingerprint, account: account), try load(account) == fingerprint else {
                    failures[host] = .unavailable
                    return false
                }
            }
            failures.removeValue(forKey: host)
            return true
        } catch {
            failures[host] = .unavailable
            return false
        }
    }

    func failure(for host: String) -> Failure? {
        lock.lock()
        defer { lock.unlock() }
        return failures[Self.normalizedHost(host)]
    }

    /// Only a user-confirmed re-pair may discard the old identity.
    @discardableResult
    func reset(host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let host = Self.normalizedHost(host)
        let account = Self.account(for: host)
        do {
            guard save("", account: account), try load(account) == nil else { return false }
            failures.removeValue(forKey: host)
            return true
        } catch {
            failures[host] = .unavailable
            return false
        }
    }

    private func load(_ account: String) throws -> String? {
        if let defaults {
            guard let stored = defaults.object(forKey: account) else { return nil }
            guard let value = stored as? String, !value.isEmpty else { throw Failure.unavailable }
            return value
        }
        // A pin that cannot be read fails closed; only a pin that is known to be absent reads as nil.
        switch CredentialVault.shared.lookup(account) {
        case .missing:
            return nil
        case .unavailable:
            throw Failure.unavailable
        case .value(let data):
            guard let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw Failure.unavailable }
            return value
        }
    }

    private func save(_ value: String, account: String) -> Bool {
        if let defaults {
            if value.isEmpty { defaults.removeObject(forKey: account) }
            else { defaults.set(value, forKey: account) }
            return true
        }
        return KeychainHelper.writeKeychainSecret(value, account: account)
    }

    private static func account(for host: String) -> String {
        "lg_certificate_sha256_" + fingerprint(Data(host.utf8))
    }

    private static func fingerprint(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
