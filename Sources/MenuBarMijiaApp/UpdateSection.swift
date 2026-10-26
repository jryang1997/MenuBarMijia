import AppKit
import MijiaCore
import SwiftUI

struct UpdateSection: View {
    let store: HomeStore

    var body: some View {
        let _ = store.effectiveLanguage
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("版本 \(UpdateChecker.bundleVersion)", "Version \(UpdateChecker.bundleVersion)"))
                        .font(.system(size: 11, weight: .semibold))
                    Text(statusSubtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(store.updateState.isFailure ? Color.red : Color.secondary)
                        .lineLimit(2)
                }
                Spacer()
                actionButtons
            }

            if case .downloading(_, let progress) = store.updateState {
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let release = store.updateState.associatedRelease,
               !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(release.notes.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 84)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Divider().overlay(Color.primary.opacity(0.06))

            HStack {
                Text(L10n.tr("自动检查更新", "Check for Updates Automatically"))
                    .font(.system(size: 12))
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { store.automaticallyChecksForUpdates },
                        set: { store.automaticallyChecksForUpdates = $0 }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .padding(12)
        .glassTile(isActive: false, accent: .accentColor, cornerRadius: 12)
    }

    private var statusSubtitle: String {
        switch store.updateState {
        case .idle:
            return L10n.tr("MenuBarMijia 更新发布在 GitHub Releases", "MenuBarMijia updates are published on GitHub Releases")
        case .checking:
            return L10n.tr("正在查看 GitHub 上的最新版本…", "Checking GitHub for the latest release…")
        case .upToDate:
            return L10n.tr("已是最新版本", "You're up to date")
        case .available(let release):
            if release.packageAsset != nil {
                return L10n.tr(
                    "发现新版本 v\(release.version)，可直接下载并安装",
                    "Version v\(release.version) is available to download and install"
                )
            }
            return L10n.tr(
                "有新版本 v\(release.version)，请前往发布页下载",
                "New version v\(release.version) available on GitHub Releases"
            )
        case .downloading(let release, let progress):
            return L10n.tr(
                "正在下载 v\(release.version)… \(progress.formattedSummary)",
                "Downloading v\(release.version)… \(progress.formattedSummary)"
            )
        case .verifying(let release):
            return L10n.tr(
                "正在校验 v\(release.version) 签名与完整性…",
                "Verifying v\(release.version) signature and integrity…"
            )
        case .readyToRelaunch(let staged):
            return L10n.tr(
                "v\(staged.release.version) 已就绪，重启应用即可完成更新",
                "v\(staged.release.version) is ready; relaunch to complete update"
            )
        case .installing(let release):
            return L10n.tr(
                "正在替换应用并重启至 v\(release.version)…",
                "Installing v\(release.version) and relaunching…"
            )
        case .failed(let failure):
            return failure.message
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch store.updateState {
        case .idle, .upToDate:
            Button(L10n.tr("检查更新", "Check for Updates")) {
                Task { await store.checkForUpdates() }
            }
            .buttonStyle(PillActionButtonStyle())

        case .checking:
            Button(L10n.tr("检查中…", "Checking…")) {}
                .buttonStyle(PillActionButtonStyle())
                .disabled(true)

        case .available(let release):
            if release.packageAsset != nil {
                Button(L10n.tr("下载并安装", "Update Now")) {
                    Task { await store.startUpdateInstallation() }
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
            }
            Button(L10n.tr("手动下载", "Manual Download")) {
                NSWorkspace.shared.open(release.pageURL)
            }
            .buttonStyle(PillActionButtonStyle())

        case .downloading, .verifying:
            Button(L10n.tr("取消", "Cancel")) {
                store.cancelUpdateInstallation()
            }
            .buttonStyle(PillActionButtonStyle())

        case .readyToRelaunch:
            Button(L10n.tr("立即重启并更新", "Relaunch & Update")) {
                store.confirmRelaunchForUpdate()
            }
            .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .green))
            Button(L10n.tr("稍后", "Later")) {
                store.cancelUpdateInstallation()
            }
            .buttonStyle(PillActionButtonStyle())

        case .installing:
            Button(L10n.tr("正在重启…", "Relaunching…")) {}
                .buttonStyle(PillActionButtonStyle())
                .disabled(true)

        case .failed(let failure):
            if failure.canRetryInstall {
                Button(L10n.tr("重试", "Retry")) {
                    Task { await store.startUpdateInstallation() }
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
            } else {
                Button(L10n.tr("重试", "Retry")) {
                    Task { await store.checkForUpdates() }
                }
                .buttonStyle(PillActionButtonStyle())
            }
            Button(L10n.tr("手动下载", "Manual Download")) {
                NSWorkspace.shared.open(failure.fallbackURL)
            }
            .buttonStyle(PillActionButtonStyle())
        }
    }
}
