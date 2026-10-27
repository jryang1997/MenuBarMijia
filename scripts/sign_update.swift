#!/usr/bin/env swift
import CryptoKit
import Foundation

// 更新包离线签名工具（issue #17）。
//
// 用法：
//   MENUBARMIJIA_UPDATE_SIGNING_KEY="<私钥>" swift scripts/sign_update.swift <DMG 路径>
//
// 输出：
//   <DMG 路径>.ed25519.sig（base64 单行）。发布时把它和 DMG 一起作为 release 附件上传；
//   应用会在 SHA-256 校验之后、解包之前验证该签名，公钥编在 Sources/MijiaCore/UpdateChecker.swift。
//
// 私钥格式（MENUBARMIJIA_UPDATE_SIGNING_KEY，二选一）：
//   1. 32 字节 raw seed 的 base64（推荐；44 字符）
//   2. PKCS#8 PEM（OpenSSL 导出的私钥；从 DER 尾部取 32 字节）
//
// 私钥只应保存在离线介质或发布机的 secret 里，绝不提交到仓库。生成一对新密钥可用：
//   swift -e 'import CryptoKit; let k = Curve25519.Signing.PrivateKey(); print("private:", k.rawRepresentation.base64EncodedString()); print("public:", k.publicKey.rawRepresentation.base64EncodedString())'
// 轮换密钥时同步修改 UpdateChecker.updateSigningPublicKeyBase64 和本文档。

// 与 Sources/MijiaCore/UpdateChecker.swift 的 updateSigningPublicKeyBase64 保持一致；
// 轮换密钥时两处一起改，否则这里会拒绝签名。
let expectedPublicKeyBase64 = "SZe6sCJZy/U7JCW4mMU8dVBLJ2pIoWh1EhKCNA0wQRM="

enum SigningError: Error, CustomStringConvertible {
    case usage
    case missingKey
    case invalidKey(String)
    case keyMismatch(String)
    case invalidPackage(String)
    case writeFailed(String)

    var description: String {
        switch self {
        case .usage:
            return "用法：MENUBARMIJIA_UPDATE_SIGNING_KEY=<私钥> swift scripts/sign_update.swift <DMG 路径>"
        case .missingKey:
            return "缺少环境变量 MENUBARMIJIA_UPDATE_SIGNING_KEY（32 字节 seed 的 base64 或 PKCS#8 PEM）"
        case .invalidKey(let detail):
            return "私钥无效：\(detail)"
        case .keyMismatch(let detail):
            return "私钥与 App 内置公钥不匹配：\(detail)"
        case .invalidPackage(let detail):
            return "读取安装包失败：\(detail)"
        case .writeFailed(let detail):
            return "写入签名文件失败：\(detail)"
        }
    }
}

func decodeSeed(_ raw: String) throws -> Data {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw SigningError.missingKey }

    if trimmed.contains("-----BEGIN") {
        let payload = trimmed
            .split(whereSeparator: { $0.isNewline })
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: payload, options: .ignoreUnknownCharacters), der.count >= 32 else {
            throw SigningError.invalidKey("PKCS#8 PEM 不是合法的 base64 DER")
        }
        return Data(der.suffix(32))
    }

    guard let seed = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters), seed.count == 32 else {
        throw SigningError.invalidKey("必须是 32 字节 seed 的 base64 或 PKCS#8 PEM")
    }
    return seed
}

func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 1 else { throw SigningError.usage }
    guard let rawKey = ProcessInfo.processInfo.environment["MENUBARMIJIA_UPDATE_SIGNING_KEY"] else {
        throw SigningError.missingKey
    }

    let seed = try decodeSeed(rawKey)
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    guard publicKey == expectedPublicKeyBase64 else {
        throw SigningError.keyMismatch("私钥对应的公钥 \(publicKey) 与 App 内置公钥不一致，客户端会拒绝该更新")
    }
    let packageURL = URL(fileURLWithPath: arguments[0])
    guard FileManager.default.fileExists(atPath: packageURL.path) else {
        throw SigningError.invalidPackage("找不到 \(packageURL.path)")
    }

    let packageData: Data
    do {
        packageData = try Data(contentsOf: packageURL, options: .mappedIfSafe)
    } catch {
        throw SigningError.invalidPackage(error.localizedDescription)
    }
    let signature = try key.signature(for: packageData)
    let signatureURL = packageURL.appendingPathExtension("ed25519.sig")
    do {
        try (signature.base64EncodedString() + "\n").write(to: signatureURL, atomically: true, encoding: .utf8)
    } catch {
        throw SigningError.writeFailed(error.localizedDescription)
    }

    print("✅ 已生成 \(signatureURL.path)")
    print("   公钥（与 App 内置值一致）：\(publicKey)")
}

do {
    try main()
} catch {
    try? FileHandle.standardError.write(contentsOf: Data("❌ \(error)\n".utf8))
    exit(1)
}
