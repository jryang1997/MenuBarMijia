import AppKit
import AVFoundation
import AVKit
import MijiaCore
import Observation
import SwiftUI

// MARK: - Floating Live Camera Window Controller (#97)

/// Borderless, resizable floating `NSPanel` that stays visible across Spaces and full-screen apps
/// without stealing focus when clicked unless a text field inside it asks for key status.
final class CameraFloatingPanel: NSPanel {
    var allowsKeyStatus = false

    override var canBecomeKey: Bool { allowsKeyStatus }
    override var canBecomeMain: Bool { false }
}

@Observable
@MainActor
public final class CameraLivePanelController: NSObject, NSWindowDelegate {
    public static let shared = CameraLivePanelController()

    public static let compactSize = NSSize(width: 360, height: 244)
    public static let expandedSize = NSSize(width: 640, height: 420)
    private static let frameStorageKey = "camera_live_panel_frame_v1"

    public private(set) var activeDeviceId: String?
    public private(set) var streamSource: CameraStreamSource?
    public private(set) var isLoadingStream = false
    public private(set) var errorMessage: String?
    public private(set) var snapshotImage: NSImage?
    /// Native H.264/H.265 player for `.liveMP4` streams; nil for every other source.
    private(set) var videoPlayer: CameraLiveVideoPlayer?
    public private(set) var hasLiveVideoFrame = false
    /// Native Picture-in-Picture for the live video layer.
    @ObservationIgnored private var pictureInPicture: CameraPictureInPicture?
    public private(set) var isPictureInPicturePossible = false
    public private(set) var isPictureInPictureActive = false
    public var isPinnedOnTop = true {
        didSet { syncWindowLevel() }
    }
    public var isExpandedSize = true
    public var isShowingURLConfig = false
    public var customURLInput = ""

    /// Disabled in unit tests so opening the camera panel does not steal focus from the terminal.
    public var presentsActively = true

    private weak var store: HomeStore?
    private(set) var panelWindow: CameraFloatingPanel?
    private var resolveTask: Task<Void, Never>?
    private var snapshotLoopTask: Task<Void, Never>?
    private var mjpegSession: URLSession?
    private var closeReleaseTask: Task<Void, Never>?
    private static let hotKeepAliveDuration: Duration = .seconds(120)
    private let snapshotSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 6
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    override private init() {
        super.init()
    }

    public func install(with store: HomeStore) {
        self.store = store
        store.onOpenCameraLiveView = { [weak self] device in
            self?.present(device: device)
        }
    }

    public var isVisible: Bool {
        panelWindow?.isVisible == true
    }

    public var currentDevice: SmartDevice? {
        guard let id = activeDeviceId else { return nil }
        return store?.devices.first(where: { $0.id == id })
    }

    public func present(device: SmartDevice) {
        guard let store else { return }
        closeReleaseTask?.cancel()
        closeReleaseTask = nil
        if isPictureInPictureActive {
            pictureInPicture?.stop()
        }

        let previousDeviceId = activeDeviceId
        let canReuseHotStream = (
            previousDeviceId == device.id
            && errorMessage == nil
            && (streamSource != nil || isLoadingStream)
        )
        if let previousDeviceId, previousDeviceId != device.id {
            let oldId = previousDeviceId
            stopStreamTasks()
            Task { await store.stopCameraStream(for: oldId) }
        }

        activeDeviceId = device.id
        customURLInput = store.cameraCustomStreamURL(for: device.id) ?? ""
        isShowingURLConfig = false

        let panel = panelWindow ?? makePanel()
        panelWindow = panel
        panel.appearance = MenuBarPanelController.preferredAppearance()
        if !(panel.contentView is NSHostingView<CameraLivePanelView>) {
            let hosting = NSHostingView(rootView: CameraLivePanelView(controller: self, store: store))
            hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
            hosting.autoresizingMask = [.width, .height]
            hosting.wantsLayer = true
            hosting.layer?.cornerRadius = 14
            hosting.layer?.masksToBounds = true
            panel.contentView = hosting
        }
        syncWindowLevel()
        if !panel.isVisible {
            let initialSize = isExpandedSize ? Self.expandedSize : Self.compactSize
            panel.setFrame(initialFrame(for: initialSize), display: true)
        }
        panel.orderFrontRegardless()
        if !canReuseHotStream {
            reloadStream()
        }
    }

    public func closePanel() {
        setURLFieldActive(false)
        if let frame = panelWindow?.frame {
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameStorageKey)
        }
        panelWindow?.orderOut(nil)

        closeReleaseTask?.cancel()
        let keepAlive = Self.hotKeepAliveDuration
        closeReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: keepAlive)
            guard !Task.isCancelled, let self, !self.isVisible, !self.isPictureInPictureActive else { return }
            let oldId = self.activeDeviceId
            self.stopStreamTasks()
            if let oldId, let store = self.store {
                await store.stopCameraStream(for: oldId)
            }
        }
    }

    private func stopStreamTasks() {
        resolveTask?.cancel()
        resolveTask = nil
        snapshotLoopTask?.cancel()
        snapshotLoopTask = nil
        mjpegSession?.invalidateAndCancel()
        mjpegSession = nil
        videoPlayer?.stop()
        videoPlayer = nil
        tearDownPictureInPicture()
        hasLiveVideoFrame = false
        snapshotImage = nil
        streamSource = nil
        isLoadingStream = false
    }

    // MARK: - Picture in Picture

    public func togglePictureInPicture() {
        guard let pictureInPicture else { return }
        if isPictureInPictureActive {
            pictureInPicture.stop()
        } else {
            pictureInPicture.start()
        }
    }

    private func setUpPictureInPicture(for player: CameraLiveVideoPlayer) {
        tearDownPictureInPicture()
        let pip = CameraPictureInPicture(displayLayer: player.displayLayer)
        pip.onStateChange = { [weak self, weak pip] in
            guard let self, let pip, self.pictureInPicture === pip else { return }
            let wasActive = self.isPictureInPictureActive
            self.isPictureInPicturePossible = pip.isPossible
            self.isPictureInPictureActive = pip.isActive
            if pip.isActive, !wasActive {
                // The system PiP window replaces the floating panel; the stream stays live.
                self.setURLFieldActive(false)
                if let frame = self.panelWindow?.frame {
                    UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameStorageKey)
                }
                self.panelWindow?.orderOut(nil)
            }
        }
        pip.onRestore = { [weak self] in
            self?.panelWindow?.orderFrontRegardless()
        }
        pip.onClosed = { [weak self] in
            self?.closePanel()
        }
        pictureInPicture = pip
    }

    private func tearDownPictureInPicture() {
        pictureInPicture?.invalidate()
        pictureInPicture = nil
        isPictureInPicturePossible = false
        isPictureInPictureActive = false
    }

    public func toggleExpandedSize() {
        isExpandedSize.toggle()
        guard let panel = panelWindow else { return }
        let targetSize = isExpandedSize ? Self.expandedSize : Self.compactSize
        let current = panel.frame
        let newOrigin = NSPoint(
            x: current.maxX - targetSize.width,
            y: current.maxY - targetSize.height
        )
        let screenFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let clampedX = min(max(newOrigin.x, screenFrame.minX + 12), screenFrame.maxX - targetSize.width - 12)
        let clampedY = min(max(newOrigin.y, screenFrame.minY + 12), screenFrame.maxY - targetSize.height - 12)
        let nextFrame = NSRect(origin: NSPoint(x: clampedX, y: clampedY), size: targetSize)
        panel.setFrame(nextFrame, display: true, animate: presentsActively)
    }

    public func setURLFieldActive(_ active: Bool) {
        panelWindow?.allowsKeyStatus = active
        if active, presentsActively {
            panelWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    public func saveCustomStreamURL() {
        guard let store, let id = activeDeviceId else { return }
        store.setCameraCustomStreamURL(customURLInput, for: id)
        isShowingURLConfig = false
        setURLFieldActive(false)
        reloadStream()
    }

    public func clearCustomStreamURL() {
        guard let store, let id = activeDeviceId else { return }
        customURLInput = ""
        store.setCameraCustomStreamURL(nil, for: id)
        isShowingURLConfig = false
        setURLFieldActive(false)
        reloadStream()
    }

    public func reloadStream() {
        stopStreamTasks()
        errorMessage = nil

        guard let store, let device = currentDevice, case .camera(let spec) = device.kind else {
            return
        }
        guard spec.isOn else {
            let deviceId = device.id
            Task { await store.stopCameraStream(for: deviceId) }
            return
        }

        isLoadingStream = true
        let deviceId = device.id
        resolveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let resolved = try await store.resolveCameraStream(for: deviceId)
                guard !Task.isCancelled else { return }
                self.streamSource = resolved
                self.isLoadingStream = false
                switch resolved {
                case .snapshot(let url):
                    self.startSnapshotLoop(url: url)
                case .liveMP4(let url, let fallback):
                    self.startLiveVideo(url: url, mjpegFallback: fallback)
                case .mjpeg(let url):
                    self.startMJPEGStream(url: url)
                case .hls, .demo:
                    break
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoadingStream = false
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func startSnapshotLoop(url: URL) {
        snapshotLoopTask?.cancel()
        snapshotLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isVisible {
                if let img = await self.fetchSnapshotFrame(from: url) {
                    self.snapshotImage = img
                }
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }

    /// Plays the camera's own bitstream through VideoToolbox, reconnecting when go2rtc drops the
    /// connection. If no frame ever decodes (unsupported codec, broken parameter sets, no data
    /// for 15 s) it switches to the transcoded MJPEG fallback so the window still shows video.
    private func startLiveVideo(url: URL, mjpegFallback: URL?) {
        snapshotLoopTask?.cancel()
        videoPlayer?.stop()
        let player = CameraLiveVideoPlayer()
        player.onFirstFrame = { [weak self, weak player] in
            guard let self, let player, self.videoPlayer === player else { return }
            self.hasLiveVideoFrame = true
        }
        videoPlayer = player
        hasLiveVideoFrame = false
        setUpPictureInPicture(for: player)

        snapshotLoopTask = Task { @MainActor [weak self] in
            var failedAttempts = 0
            while !Task.isCancelled {
                let watchdog = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled, self?.hasLiveVideoFrame == false else { return }
                    player.stop()
                }
                let outcome = await player.play(url: url)
                watchdog.cancel()
                guard !Task.isCancelled, let self, self.videoPlayer === player else { return }

                if outcome.framesDecoded > 0 {
                    failedAttempts = 0
                    try? await Task.sleep(for: .milliseconds(400))
                    continue
                }
                failedAttempts += 1
                if failedAttempts >= 2, !self.hasLiveVideoFrame, let mjpegFallback {
                    self.videoPlayer = nil
                    self.tearDownPictureInPicture()
                    self.streamSource = .mjpeg(mjpegFallback)
                    self.startMJPEGStream(url: mjpegFallback)
                    return
                }
                if failedAttempts >= 4 {
                    self.errorMessage = L10n.tr(
                        "实时画面中断：\(outcome.failure ?? "无数据")",
                        "Live video stopped: \(outcome.failure ?? "no data")"
                    )
                    self.streamSource = nil
                    self.videoPlayer = nil
                    self.tearDownPictureInPicture()
                    return
                }
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }

    private func startMJPEGStream(url: URL) {
        snapshotLoopTask?.cancel()
        snapshotLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var attempts = 0
            while !Task.isCancelled, attempts < 4 {
                attempts += 1
                var receivedFrame = false
                await self.consumeMJPEGConnection(url: url) { [weak self] image in
                    receivedFrame = true
                    self?.snapshotImage = image
                }
                if Task.isCancelled { break }
                if receivedFrame {
                    attempts = 0
                }
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }

    private func consumeMJPEGConnection(
        url: URL,
        onFrame: @escaping @MainActor (NSImage) -> Void
    ) async {
        mjpegSession?.invalidateAndCancel()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 0
        cfg.waitsForConnectivity = false

        let resumeGuard = MJPEGContinuationGuard()
        let delegate = MJPEGStreamDelegate(
            onFrame: { image in
                Task { @MainActor in
                    onFrame(image)
                }
            },
            onComplete: { _ in
                resumeGuard.resumeOnce()
            }
        )
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        self.mjpegSession = session
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.dataTask(with: req)

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                resumeGuard.install(continuation)
                task.resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
            resumeGuard.resumeOnce()
        }
    }

    private func fetchSnapshotFrame(from url: URL) async -> NSImage? {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.append(URLQueryItem(name: "_t", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        comps?.queryItems = items
        let targetURL = comps?.url ?? url

        var req = URLRequest(url: targetURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let store, store.homeBackend == .homeAssistant,
           targetURL.query?.contains("token=") != true {
            let token = KeychainHelper.loadToken().trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        guard let (data, resp) = try? await snapshotSession.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let image = NSImage(data: data) else {
            return nil
        }
        return image
    }

    private func makePanel() -> CameraFloatingPanel {
        let panel = CameraFloatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.expandedSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 300, height: 204)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = nil
        return panel
    }

    private func syncWindowLevel() {
        let pinnedLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panelWindow?.level = isPinnedOnTop ? pinnedLevel : .floating
    }

    private func initialFrame(for size: NSSize) -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let saved = UserDefaults.standard.string(forKey: Self.frameStorageKey) {
            let rect = NSRectFromString(saved)
            if rect.width >= 300, rect.height >= 200 {
                let x = min(max(rect.minX, visible.minX + 12), visible.maxX - size.width - 12)
                let y = min(max(rect.minY, visible.minY + 12), visible.maxY - size.height - 12)
                let candidate = NSRect(origin: NSPoint(x: x, y: y), size: size)
                if let menuPanel = MenuBarPanelController.shared.panelWindow,
                   menuPanel.isVisible,
                   candidate.intersects(menuPanel.frame) {
                    let leftX = max(visible.minX + 12, menuPanel.frame.minX - size.width - 12)
                    return NSRect(origin: NSPoint(x: leftX, y: y), size: size)
                }
                return candidate
            }
        }
        if let menuPanel = MenuBarPanelController.shared.panelWindow, menuPanel.isVisible {
            let x = max(visible.minX + 12, menuPanel.frame.minX - size.width - 12)
            let y = min(max(menuPanel.frame.maxY - size.height, visible.minY + 12), visible.maxY - size.height - 12)
            return NSRect(origin: NSPoint(x: x, y: y), size: size)
        }
        let x = visible.maxX - size.width - 24
        let y = visible.maxY - size.height - 48
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

private final class MJPEGContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var didResume = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if didResume {
            lock.unlock()
            continuation.resume()
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resumeOnce() {
        lock.lock()
        didResume = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

private final class MJPEGStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onFrame: @Sendable (NSImage) -> Void
    private let onComplete: @Sendable (Error?) -> Void

    init(
        onFrame: @escaping @Sendable (NSImage) -> Void,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        self.onFrame = onFrame
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var latestImage: NSImage?
        lock.lock()
        buffer.append(data)
        let soi = Data([0xFF, 0xD8, 0xFF])
        let eoi = Data([0xFF, 0xD9])
        while let startRange = buffer.range(of: soi),
              let endRange = buffer.range(of: eoi, in: startRange.upperBound..<buffer.endIndex) {
            let frameData = buffer.subdata(in: startRange.lowerBound..<endRange.upperBound)
            buffer.removeSubrange(buffer.startIndex..<endRange.upperBound)
            if let image = NSImage(data: frameData) {
                latestImage = image
            }
        }
        if buffer.count > 4_000_000 {
            buffer.removeAll(keepingCapacity: true)
        }
        lock.unlock()
        if let latestImage {
            onFrame(latestImage)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onComplete(error)
    }
}

// MARK: - AVPlayerView Wrapper (HLS + Native macOS PiP)

struct CameraHLSPlayerView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = .resizeAspect
        let player = AVPlayer(url: url)
        player.isMuted = true
        view.player = player
        context.coordinator.currentURL = url
        player.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        guard context.coordinator.currentURL != url else { return }
        context.coordinator.currentURL = url
        let player = AVPlayer(url: url)
        player.isMuted = nsView.player?.isMuted ?? true
        nsView.player?.pause()
        nsView.player = player
        player.play()
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
        nsView.player = nil
    }

    final class Coordinator {
        var currentURL: URL?
    }
}

// MARK: - Floating Camera Panel SwiftUI Content

struct CameraLivePanelView: View {
    @Bindable var controller: CameraLivePanelController
    let store: HomeStore
    @State private var demoTick: Int = 0

    private var device: SmartDevice? {
        controller.currentDevice
    }

    private var cameraSpec: CameraSpec? {
        guard let dev = device, case .camera(let spec) = dev.kind else { return nil }
        return spec
    }

    var body: some View {
        let _ = store.effectiveLanguage
        VStack(spacing: 0) {
            topHUDBar

            if controller.isShowingURLConfig {
                customURLBar
            }

            ZStack {
                Color(red: 0.05, green: 0.07, blue: 0.11)
                // Below the content so buttons in empty/error states stay clickable; video and
                // still frames ignore hits and let drags fall through to it.
                WindowDragArea(onDoubleClick: { controller.toggleExpandedSize() })
                viewportContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if let spec = cameraSpec {
                bottomControlsBar(spec: spec)
            }
        }
        .background(Color(red: 0.08, green: 0.10, blue: 0.15).opacity(0.96))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
        .onChange(of: cameraSpec?.isOn) { _, _ in
            controller.reloadStream()
        }
    }

    private var topHUDBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusDotColor.opacity(0.75), radius: 4)

            Text(device?.name ?? L10n.tr("智能摄像机", "Smart Camera"))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if let room = device?.roomName, !room.isEmpty {
                Text(L10n.displayRoomName(room))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }

            Spacer(minLength: 4)

            hudIconButton(
                symbol: controller.isPinnedOnTop ? "pin.fill" : "pin.slash",
                isActive: controller.isPinnedOnTop,
                help: controller.isPinnedOnTop
                    ? L10n.tr("已置顶（全屏看电视时保持最前）", "Pinned on top (stays above full-screen video)")
                    : L10n.tr("点击置顶小窗", "Pin window on top")
            ) {
                controller.isPinnedOnTop.toggle()
            }

            if case .liveMP4 = controller.streamSource {
                hudIconButton(
                    symbol: controller.isPictureInPictureActive ? "pip.exit" : "pip.enter",
                    isActive: controller.isPictureInPictureActive,
                    help: L10n.tr("系统画中画（可放在任意位置、跨全屏应用）", "Picture in Picture (system floating window)")
                ) {
                    controller.togglePictureInPicture()
                }
                .disabled(!controller.isPictureInPicturePossible && !controller.isPictureInPictureActive)
                .opacity(controller.isPictureInPicturePossible || controller.isPictureInPictureActive ? 1 : 0.4)
            }

            hudIconButton(
                symbol: controller.isExpandedSize
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                isActive: false,
                help: controller.isExpandedSize
                    ? L10n.tr("切换为角落迷你小窗", "Switch to compact mini window")
                    : L10n.tr("放大实时画面窗口", "Expand live view window")
            ) {
                controller.toggleExpandedSize()
            }

            hudIconButton(
                symbol: "link",
                isActive: controller.isShowingURLConfig || !(store.cameraCustomStreamURL(for: device?.id ?? "") ?? "").isEmpty,
                help: L10n.tr("配置自定义 HLS / go2rtc / 抓拍流地址", "Configure custom HLS / go2rtc / snapshot stream URL")
            ) {
                controller.isShowingURLConfig.toggle()
                controller.setURLFieldActive(controller.isShowingURLConfig)
            }

            hudIconButton(
                symbol: "arrow.clockwise",
                isActive: false,
                help: L10n.tr("重新连接画面", "Reload stream")
            ) {
                controller.reloadStream()
            }

            hudIconButton(
                symbol: "xmark",
                isActive: false,
                help: L10n.tr("关闭摄像头小窗", "Close camera window")
            ) {
                controller.closePanel()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            ZStack {
                Color.black.opacity(0.42)
                WindowDragArea()
            }
        }
    }

    private var customURLBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "network")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(
                L10n.tr("输入 HLS (.m3u8) / go2rtc / 抓拍 URL，例如 http://127.0.0.1:1984/api/stream.m3u8?src=cam", "Enter HLS (.m3u8) / go2rtc / snapshot URL"),
                text: $controller.customURLInput
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.white)
            .onSubmit {
                controller.saveCustomStreamURL()
            }

            Button(L10n.tr("连接", "Connect")) {
                controller.saveCustomStreamURL()
            }
            .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .cyan))

            if !(store.cameraCustomStreamURL(for: device?.id ?? "") ?? "").isEmpty {
                Button(L10n.tr("清除", "Clear")) {
                    controller.clearCustomStreamURL()
                }
                .buttonStyle(PillActionButtonStyle(tintColor: .secondary))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.08))
    }

    @ViewBuilder
    private var viewportContent: some View {
        if let spec = cameraSpec, !spec.isOn {
            VStack(spacing: 10) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                Text(L10n.tr("摄像机处于物理休眠状态", "Camera is in sleep mode"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Button {
                    if let dev = device {
                        _ = store.togglePrimary(dev)
                    }
                } label: {
                    Label(L10n.tr("唤醒镜头并观看实时画面", "Wake Camera & Watch Live"), systemImage: "video.fill")
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .cyan))
            }
            .padding(20)
        } else if controller.isLoadingStream {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text(L10n.tr("正在连接摄像机实时流…", "Connecting to live camera stream…"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
        } else if let source = controller.streamSource {
            switch source {
            case .hls(let url):
                CameraHLSPlayerView(url: url)
            case .liveMP4:
                ZStack {
                    if let player = controller.videoPlayer {
                        CameraLiveVideoSurface(player: player)
                            .allowsHitTesting(false)
                    }
                    if !controller.hasLiveVideoFrame {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(L10n.tr("正在建立 P2P 加密通道并解码实时画面…", "Establishing P2P encrypted channel & decoding live video…"))
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .mjpeg:
                if let img = controller.snapshotImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(L10n.tr("正在建立 P2P 加密通道并解码实时画面…", "Establishing P2P encrypted channel & decoding live video…"))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            case .snapshot:
                if let img = controller.snapshotImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(L10n.tr("正在拉取实时抓拍帧…", "Fetching live snapshot frames…"))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            case .demo:
                demoLiveCanvas
            }
        } else if let err = controller.errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "video.badge.waveform")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)

                HStack(spacing: 8) {
                    Button {
                        controller.isShowingURLConfig = true
                        controller.setURLFieldActive(true)
                    } label: {
                        Label(L10n.tr("填写 go2rtc / HLS 流地址", "Set go2rtc / HLS Stream URL"), systemImage: "link.badge.plus")
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .cyan))

                    Button {
                        controller.reloadStream()
                    } label: {
                        Label(L10n.tr("重试", "Retry"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(PillActionButtonStyle(tintColor: .secondary))
                }
            }
            .padding(16)
        }
    }

    private var demoLiveCanvas: some View {
        let isNight = cameraSpec?.nightShot?.lowercased() == "on"
        return ZStack {
            LinearGradient(
                colors: isNight
                    ? [Color(red: 0.04, green: 0.14, blue: 0.10), Color(red: 0.02, green: 0.08, blue: 0.06)]
                    : [Color(red: 0.09, green: 0.16, blue: 0.28), Color(red: 0.05, green: 0.09, blue: 0.17)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Stylized room/crib silhouette & live scanline pulse
            VStack(spacing: 14) {
                HStack {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(isNight ? "LIVE · IR NIGHT 2K" : "LIVE · 2K HDR · 25fps")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.black.opacity(0.45)))

                    Spacer()

                    Text(Self.timestampString(tick: demoTick))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                }

                Spacer()

                VStack(spacing: 8) {
                    Image(systemName: isNight ? "moon.stars.fill" : "video.fill")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(isNight ? Color.green.opacity(0.85) : Color.cyan.opacity(0.85))

                    Text(
                        L10n.tr(
                            "\(device?.name ?? "客厅摄像机") · 实时看护小窗预览",
                            "\(device?.name ?? "Living Room Camera") · Live Floating Monitor"
                        )
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                    Text(
                        cameraSpec?.isMotionDetectionOn == true
                            ? L10n.tr("AI 移动与看护侦测中 · 画面正常", "AI Motion & Baby Watch Active · Clear")
                            : L10n.tr("实时画面流已就绪 · 支持跨桌面全屏置顶", "Live feed active · Pinned above full-screen apps")
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.70))
                }

                Spacer()
            }
            .padding(14)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                demoTick &+= 1
            }
        }
    }

    private func bottomControlsBar(spec: CameraSpec) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            AdaptiveGlassContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        if let dev = device {
                            _ = store.togglePrimary(dev)
                        }
                    } label: {
                        Label(
                            spec.isOn ? L10n.tr("休眠镜头", "Sleep") : L10n.tr("唤醒镜头", "Wake"),
                            systemImage: spec.isOn ? "moon.zzz.fill" : "power"
                        )
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: !spec.isOn, tintColor: .cyan))

                    if spec.motionDetectionEntityId != nil {
                        let motionOn = spec.isMotionDetectionOn ?? false
                        Button {
                            if let dev = device {
                                store.setCameraMotionDetection(dev.id, enabled: !motionOn)
                            }
                        } label: {
                            Label(
                                motionOn ? L10n.tr("移动侦测：开", "Motion: On") : L10n.tr("移动侦测：关", "Motion: Off"),
                                systemImage: "figure.walk.motion"
                            )
                        }
                        .buttonStyle(PillActionButtonStyle(isSelected: motionOn, tintColor: .cyan))
                    }

                    ForEach(spec.availableNightShots, id: \.self) { mode in
                        let selected = (spec.nightShot == mode)
                        Button(SmartDevice.localizeNightShot(mode)) {
                            if let dev = device {
                                store.setCameraNightShot(dev.id, mode: mode)
                            }
                        }
                        .buttonStyle(PillActionButtonStyle(isSelected: selected, tintColor: .cyan))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(Color.black.opacity(0.45))
    }

    private func hudIconButton(
        symbol: String,
        isActive: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? Color.cyan : Color.white.opacity(0.82))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(isActive ? Color.cyan.opacity(0.20) : Color.white.opacity(0.10))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var statusDotColor: Color {
        guard let spec = cameraSpec, spec.isOn else { return .gray }
        if controller.isLoadingStream { return .orange }
        if controller.streamSource != nil { return .green }
        return .orange
    }

    private static func timestampString(tick: Int) -> String {
        let _ = tick
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
