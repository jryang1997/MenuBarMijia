import AppKit
import MijiaCore
import SwiftUI

// MARK: - Settings: 检查更新

/// Manual update check against GitHub Releases; opens the release page instead of installing.
struct UpdateSection: View {
    let store: HomeStore

    private enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed(String)
    }

    @State private var status: Status = .idle

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("版本 \(UpdateChecker.bundleVersion)")
                    .font(.system(size: 11, weight: .semibold))
                Text(statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if case .available(_, let url) = status {
                Button("去下载") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
            } else {
                Button(status == .checking ? "检查中…" : "检查更新") {
                    Task { await check() }
                }
                .buttonStyle(PillActionButtonStyle())
                .disabled(status == .checking)
            }
        }
        .padding(12)
        .glassTile(isActive: false, accent: .accentColor, cornerRadius: 12)
    }

    private var statusText: String {
        switch status {
        case .idle: return "MenuBarMijia 更新发布在 GitHub Releases"
        case .checking: return "正在查看 GitHub 上的最新版本…"
        case .upToDate: return "已是最新版本"
        case .available(let version, _): return "有新版本 \(version)，下载后拖进「应用程序」替换即可"
        case .failed(let message): return message
        }
    }

    private var statusIsError: Bool {
        if case .failed = status { return true }
        return false
    }

    private func check() async {
        status = .checking
        do {
            switch try await UpdateChecker(currentVersion: UpdateChecker.bundleVersion).check() {
            case .upToDate:
                status = .upToDate
            case .available(let version, let url, _):
                status = .available(version: version, url: url)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
