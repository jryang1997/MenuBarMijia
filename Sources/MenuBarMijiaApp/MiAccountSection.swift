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

    @State private var phase: ScanPhase = .idle
    @State private var loginTask: Task<Void, Never>?

    public init(store: HomeStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
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
                        .controlSize(.small)
                    Text("正在获取小米登录二维码…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") {
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
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.9))
                    }

                    HStack {
                        Button("取消") {
                            cancelLogin()
                        }
                        .buttonStyle(PillActionButtonStyle())

                        Spacer()

                        Button("重试获取二维码") {
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                Text("已登录米家账号：\(maskedUserId)")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
            }

            if case .disconnected(let reason) = store.connectionStatus, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 6) {
                Button("同步设备") {
                    store.refreshNow()
                    store.showToast("正在同步米家云端设备…")
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))

                Button("重新扫码") {
                    startQRLogin()
                }
                .buttonStyle(PillActionButtonStyle())

                Spacer()

                Button("退出登录") {
                    store.logoutMiAccount()
                }
                .buttonStyle(PillActionButtonStyle())
            }
        }
    }

    private var loggedOutView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("无需额外部署 Home Assistant，扫码即可通过米家云端直连同步设备与房间。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("扫码登录米家账号") {
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
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Text("使用手机「米家」App 或小米账号扫码确认登录")
                .font(.system(size: 11.5, weight: .medium))
                .multilineTextAlignment(.center)

            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                let remaining = max(0, Int(expiresAt.timeIntervalSince(context.date).rounded()))
                Text("二维码有效剩余 \(remaining)s")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Button("取消") {
                    cancelLogin()
                }
                .buttonStyle(PillActionButtonStyle())

                Button("刷新二维码") {
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
        loginTask = Task {
            let login = MiAccountLogin()
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
