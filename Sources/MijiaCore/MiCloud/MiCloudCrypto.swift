import CryptoKit
import Foundation

/// RC4 + SHA signing used by the Mi Home app's `MIOT-ENCRYPT-ALGORITHM: ENCRYPT-RC4` API.
public enum MiCloudCrypto {
    public struct RC4 {
        private var s: [UInt8] = Array(0...255)
        private var i: UInt8 = 0
        private var j: UInt8 = 0

        public init(key: [UInt8], drop: Int = 1024) {
            precondition(!key.isEmpty, "RC4 key must not be empty")
            var j = 0
            for i in 0..<256 {
                j = (j + Int(s[i]) + Int(key[i % key.count])) & 0xFF
                s.swapAt(i, j)
            }
            if drop > 0 {
                _ = process([UInt8](repeating: 0, count: drop))
            }
        }

        public mutating func process(_ input: [UInt8]) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: input.count)
            for (idx, byte) in input.enumerated() {
                i &+= 1
                j &+= s[Int(i)]
                s.swapAt(Int(i), Int(j))
                out[idx] = byte ^ s[Int(s[Int(i)] &+ s[Int(j)])]
            }
            return out
        }
    }

    public enum CryptoError: Error, Equatable {
        case invalidBase64(String)
        case invalidUTF8
    }

    /// 8 random bytes followed by the big-endian minute counter.
    public static func makeNonce(now: Date = Date(), randomBytes: [UInt8]? = nil) -> String {
        var bytes = randomBytes ?? (0..<8).map { _ in UInt8.random(in: 0...255) }
        let minutes = UInt32(truncatingIfNeeded: Int64(now.timeIntervalSince1970 * 1000) / 60_000)
        withUnsafeBytes(of: minutes.bigEndian) { bytes.append(contentsOf: $0) }
        return Data(bytes).base64EncodedString()
    }

    public static func signedNonce(ssecurity: String, nonce: String) throws -> String {
        let a = try decodeBase64(ssecurity)
        let b = try decodeBase64(nonce)
        let digest = SHA256.hash(data: a + b)
        return Data(digest).base64EncodedString()
    }

    /// `base64(sha1("POST&<path>&k=v&...&<signedNonce>"))`, with params in insertion order.
    public static func sha1Signature(method: String = "POST", path: String, params: [(String, String)], signedNonce: String) -> String {
        var parts = [method.uppercased(), path]
        parts.append(contentsOf: params.map { "\($0.0)=\($0.1)" })
        parts.append(signedNonce)
        let digest = Insecure.SHA1.hash(data: Data(parts.joined(separator: "&").utf8))
        return Data(digest).base64EncodedString()
    }

    public static func encrypt(_ plain: String, signedNonce: String) throws -> String {
        var rc4 = RC4(key: [UInt8](try decodeBase64(signedNonce)))
        return Data(rc4.process(Array(plain.utf8))).base64EncodedString()
    }

    public static func decryptResponse(_ body: String, signedNonce: String) throws -> Data {
        let cipher = try decodeBase64(body.trimmingCharacters(in: .whitespacesAndNewlines))
        var rc4 = RC4(key: [UInt8](try decodeBase64(signedNonce)))
        return Data(rc4.process([UInt8](cipher)))
    }

    /// Builds the ordered form fields for an RC4-encrypted POST.
    /// `path` is the URL path with the leading `/app` removed, e.g. `/home/device_list`.
    public static func encryptParams(path: String, data: String, ssecurity: String, nonce: String) throws -> [(String, String)] {
        let signed = try signedNonce(ssecurity: ssecurity, nonce: nonce)
        let rc4Hash = sha1Signature(path: path, params: [("data", data)], signedNonce: signed)
        let encrypted: [(String, String)] = [
            ("data", try encrypt(data, signedNonce: signed)),
            ("rc4_hash__", try encrypt(rc4Hash, signedNonce: signed)),
        ]
        let signature = sha1Signature(path: path, params: encrypted, signedNonce: signed)
        return encrypted + [
            ("signature", signature),
            ("ssecurity", ssecurity),
            ("_nonce", nonce),
        ]
    }

    public static func formURLEncode(_ fields: [(String, String)]) -> String {
        fields.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
    }

    private static let formAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? s
    }

    private static func decodeBase64(_ s: String) throws -> Data {
        guard let d = Data(base64Encoded: s) else { throw CryptoError.invalidBase64(String(s.prefix(8))) }
        return d
    }
}
