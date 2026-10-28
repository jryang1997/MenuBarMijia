import AppKit
import MijiaCore
import Security

/// Explains the Keychain prompt that follows an upgrade before macOS shows it (#16).
///
/// Releases use a free self-signed certificate, so macOS asks once after every upgrade whether this build may read the
/// saved credentials. Without context that prompt looks like a phishing attempt; this alert runs first and tells the
/// user what to expect. It appears only when credentials exist on this Mac and the running build's code-signing hash
/// differs from the last one that read them.
@MainActor
enum KeychainUpgradeNotice {
    static let seenSignatureKey = "credential_vault_seen_cdhash"

    /// Call before anything reads a credential.
    static func presentIfNeeded(defaults: UserDefaults = .standard) {
        guard let current = currentCodeHash(),
              defaults.string(forKey: seenSignatureKey) != current,
              CredentialVault.hasStoredCredentials() else { return }
        present(mergingOldItems: !CredentialVault.hasVaultItem())
    }

    /// Call after the store has read its credentials. A declined prompt leaves the vault unread, so the next launch
    /// explains again before macOS asks again.
    static func recordIfLoaded(defaults: UserDefaults = .standard) {
        guard CredentialVault.shared.isLoaded, let current = currentCodeHash() else { return }
        defaults.set(current, forKey: seenSignatureKey)
    }

    private static func present(mergingOldItems: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.tr("MenuBarMijia 已更新", "MenuBarMijia was updated")
        let howMany = mergingOldItems
            ? L10n.tr(
                "这次会把旧版本分开保存的凭据合并成一份，所以可能会连续问几次（每份凭据一次）；以后每次更新只问一次。",
                "This update merges credentials that older versions stored separately, so macOS may ask a few "
                    + "times in a row (once per credential). Later updates ask only once."
            )
            : L10n.tr("每次更新后只问这一次。", "It asks only once per update.")
        alert.informativeText = L10n.tr(
            "接下来 macOS 会询问是否允许 MenuBarMijia 使用钥匙串里保存的登录信息。"
                + "\n\n请输入这台 Mac 的登录密码，然后点「始终允许」。" + howMany
                + "\n\n如果点「拒绝」，App 会显示为未登录，但保存的登录信息不会被删除，下次启动会再询问。",
            "Next, macOS will ask whether MenuBarMijia may use the sign-in details saved in your Keychain."
                + "\n\nEnter this Mac's login password, then click \u{201C}Always Allow\u{201D}. " + howMany
                + "\n\nIf you click \u{201C}Deny\u{201D}, the app shows as signed out, but your saved sign-in details "
                + "are not deleted and you will be asked again at the next launch."
        )
        alert.addButton(withTitle: L10n.tr("继续", "Continue"))
        NSApp.activate()
        alert.runModal()
    }

    /// The `cdhash` of the running build: the value macOS records in each Keychain item's partition list.
    private static func currentCodeHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let info = info as? [String: Any],
              let hash = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
