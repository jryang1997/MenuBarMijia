import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MijiaCore

public typealias MiAccountConnectionCard = MiAccountSection

public struct MiAccountSection: View {
    public let store: HomeStore

    private enum ScanPhase: Equatable {
        case idle
        case loadingTicket
        case waitingForScan(ticket: QRLoginTicket, expiresAt: Date)
        case failed(String)
    }

    @State private var phase: ScanPhase
    @State private var loginTask: Task<Void, Never>?

    public init(store: HomeStore, previewTicket: QRLoginTicket? = nil) {
        self.store = store
        if let previewTicket {
            self._phase = State(initialValue: .waitingForScan(ticket: previewTicket, expiresAt: Date().addingTimeInterval(previewTicket.timeout)))
        } else {
            self._phase = State(initialValue: .idle)
        }
    }

    public var body: some View {
        let _ = store.effectiveLanguage
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L10n.tr("云端服务器地区", "Cloud Region"))
                    .font(.system(size: DesignTokens.TypeSize.body))
                Spacer()
                Picker(
                    L10n.tr("云端服务器地区", "Cloud Region"),
                    selection: Binding(
                        get: { store.miCloudRegion },
                        set: { store.miCloudRegion = $0 }
                    )
                ) {
                    ForEach(MiCloudRegion.allCases) { region in
                        Text(region.label).tag(region)
                    }
                }
                .labelsHidden()
                .frame(width: DesignTokens.Settings.fieldWidth)
                .controlSize(.regular)
            }

            switch phase {
            case .idle:
                if let masked = store.miSessionMaskedUserId {
                    loggedInView(maskedUserId: masked)
                } else {
                    loggedOutView
                }

            case .loadingTicket:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.regular)
                    Text(L10n.tr("正在获取小米登录二维码…", "Fetching Xiaomi QR code…"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("取消", "Cancel")) {
                        cancelLogin()
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
                .padding(.vertical, 6)

            case .waitingForScan(let ticket, let expiresAt):
                qrCodeScanningView(ticket: ticket, expiresAt: expiresAt)

            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.9))
                    }

                    HStack {
                        Button(L10n.tr("取消", "Cancel")) {
                            cancelLogin()
                        }
                        .buttonStyle(PillActionButtonStyle())

                        Spacer()

                        Button(L10n.tr("重试获取二维码", "Retry QR Code")) {
                            startQRLogin()
                        }
                        .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                    }
                }
            }
        }
        .onDisappear {
            cancelLogin()
        }
    }

    private func loggedInView(maskedUserId: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(.green)
                Text(L10n.tr("已登录米家账号：\(maskedUserId)", "Signed in to Xiaomi Home: \(maskedUserId)"))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                Spacer()
            }

            if case .disconnected(let reason) = store.connectionStatus, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 6) {
                Button(L10n.tr("同步设备", "Sync Devices")) {
                    store.refreshNow()
                    store.showToast(L10n.tr("正在同步米家云端设备…", "Syncing Xiaomi Cloud devices…"))
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))

                Button(L10n.tr("重新扫码", "Rescan QR")) {
                    startQRLogin()
                }
                .buttonStyle(PillActionButtonStyle())

                Spacer()

                Button(L10n.tr("退出登录", "Sign Out")) {
                    store.logoutMiAccount()
                }
                .buttonStyle(PillActionButtonStyle())
            }
        }
    }

    private var loggedOutView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr(
                "无需额外部署 Home Assistant，扫码即可通过米家云端直连同步设备与房间。直连使用非官方客户端接口；若介意账号风控，请改用官方开源的 Home Assistant (xiaomi_home) 模式。",
                "No Home Assistant needed. Scan with the Mi Home app to sync devices and rooms directly from Xiaomi Cloud. Direct mode uses an unofficial client API; switch to Home Assistant (xiaomi_home) if you prefer Xiaomi's official integration."
            ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(L10n.tr("扫码登录米家账号", "Sign In with QR Code")) {
                    startQRLogin()
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
            }
        }
    }

    private func qrCodeScanningView(ticket: QRLoginTicket, expiresAt: Date) -> some View {
        VStack(spacing: 8) {
            if let qrImage = Self.makeQRImage(from: ticket.loginURL.absoluteString) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 144, height: 144)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.inset, style: .continuous))
            }

            Text(L10n.tr("使用手机「米家」App 或小米账号扫码确认登录", "Scan with the Mi Home app on your phone to confirm sign-in"))
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                .multilineTextAlignment(.center)

            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                let remaining = max(0, Int(expiresAt.timeIntervalSince(context.date).rounded()))
                Text(L10n.tr("二维码有效剩余 \(remaining)s", "QR code expires in \(remaining)s"))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Button(L10n.tr("取消", "Cancel")) {
                    cancelLogin()
                }
                .buttonStyle(PillActionButtonStyle())

                Button(L10n.tr("刷新二维码", "Refresh QR")) {
                    startQRLogin()
                }
                .buttonStyle(PillActionButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func startQRLogin() {
        loginTask?.cancel()
        phase = .loadingTicket
        let selectedRegion = store.miCloudRegion.rawValue
        loginTask = Task {
            let login = MiAccountLogin(region: selectedRegion)
            do {
                let ticket = try await login.start()
                guard !Task.isCancelled else { return }
                let expiresAt = Date().addingTimeInterval(ticket.timeout)
                phase = .waitingForScan(ticket: ticket, expiresAt: expiresAt)
                let session = try await login.waitForScan(ticket)
                guard !Task.isCancelled else { return }
                phase = .idle
                store.completeMiLogin(session)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .failed(msg)
            }
        }
    }

    private func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        phase = .idle
    }

    private static func makeQRImage(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
