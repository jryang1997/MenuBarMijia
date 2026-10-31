import AppKit
import AVFoundation
import AVKit
import CoreMedia
import MijiaCore
import os
import SwiftUI

// MARK: - Native fMP4 Live Video Player (#97)

/// Plays go2rtc's progressive fragmented MP4 (`/api/stream.mp4`) with hardware decoding.
///
/// Network chunks are demuxed on a private serial queue and every coded frame is enqueued
/// into an `AVSampleBufferDisplayLayer` marked display-immediately, so the picture follows
/// the camera in real time without FFmpeg transcoding, JPEG decoding or SwiftUI re-renders.
final class CameraLiveVideoPlayer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Outcome: Sendable {
        var framesDecoded: Int
        var failure: String?
    }

    let displayLayer: AVSampleBufferDisplayLayer
    /// The layer's renderer, captured on the main actor; enqueue/flush are thread-safe.
    private let renderer: AVSampleBufferVideoRenderer

    /// Called on the main actor when the first frame of a connection reaches the renderer.
    var onFirstFrame: (@MainActor @Sendable () -> Void)?

    private final class PlayToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "CameraLiveVideo")
    private let queue = DispatchQueue(label: "com.jryang1997.MenuBarMijia.camera-fmp4", qos: .userInteractive)
    private let delegateQueue: OperationQueue

    // Everything below is only touched on `queue`.
    private var activeToken: PlayToken?
    private var session: URLSession?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var demuxer = FragmentedMP4Demuxer()
    private var track: FMP4VideoTrack?
    private var formatDescription: CMVideoFormatDescription?
    private var activeParameterSets: [Data] = []
    private var waitingForKeyframe = true
    private var framesDecoded = 0
    private var failure: String?
    private var statsWindowStart = Date()
    private var statsWindowFrames = 0

    @MainActor
    override init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        displayLayer = layer
        renderer = layer.sampleBufferRenderer
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        super.init()
        delegateQueue.underlyingQueue = queue
    }

    /// Streams one HTTP connection until it ends, fails, or the calling task is cancelled.
    func play(url: URL) async -> Outcome {
        let token = PlayToken()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
                queue.async { self.begin(url: url, token: token, continuation: cont) }
            }
        } onCancel: {
            token.cancel()
            self.queue.async {
                if self.activeToken === token { self.finish(failure: nil) }
            }
        }
    }

    func stop() {
        queue.async { self.finish(failure: nil) }
    }

    // MARK: - Connection lifecycle (queue)

    private func begin(url: URL, token: PlayToken, continuation cont: CheckedContinuation<Outcome, Never>) {
        finish(failure: nil)
        guard !token.isCancelled else {
            cont.resume(returning: Outcome(framesDecoded: 0, failure: nil))
            return
        }
        activeToken = token
        continuation = cont
        demuxer = FragmentedMP4Demuxer()
        track = nil
        waitingForKeyframe = true
        framesDecoded = 0
        failure = nil
        statsWindowStart = Date()
        statsWindowFrames = 0
        renderer.flush()

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 0
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        session.dataTask(with: URLRequest(url: url)).resume()
    }

    private func finish(failure reason: String?) {
        if let reason, failure == nil { failure = reason }
        session?.invalidateAndCancel()
        session = nil
        activeToken = nil
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: Outcome(framesDecoded: framesDecoded, failure: failure))
        }
    }

    // MARK: - URLSessionDataDelegate (queue)

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = "HTTP \(http.statusCode)"
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard session === self.session else { return }
        let events: [FMP4DemuxEvent]
        do {
            events = try demuxer.append(data)
        } catch {
            finish(failure: "fMP4 demux error: \(error)")
            return
        }
        for event in events {
            switch event {
            case .videoTrack(let newTrack):
                if track == nil {
                    track = newTrack
                    logger.info("camera fMP4 track \(newTrack.codec.rawValue, privacy: .public) \(newTrack.width)x\(newTrack.height) timescale \(newTrack.timescale)")
                }
            case .sample(let sample):
                guard let track, sample.trackID == track.trackID else { continue }
                enqueue(sample, track: track)
                if self.session == nil { return } // a fatal enqueue error closed the connection
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === self.session else { return }
        let reason: String? = {
            guard let error else { return failure ?? "stream ended" }
            if (error as NSError).code == NSURLErrorCancelled { return failure }
            return error.localizedDescription
        }()
        finish(failure: reason)
    }

    // MARK: - Decoding (queue)

    private func enqueue(_ sample: FMP4Sample, track: FMP4VideoTrack) {
        guard let units = Self.nalUnits(of: sample.data, lengthSize: track.nalLengthSize) else { return }
        let isKeyframe = sample.isKeyframe || VideoNALUnits.containsKeyframe(units, codec: track.codec)

        if let inBand = VideoNALUnits.parameterSets(in: units, codec: track.codec), inBand != activeParameterSets {
            installFormat(parameterSets: inBand, codec: track.codec)
        } else if formatDescription == nil, isKeyframe {
            installFormat(parameterSets: track.parameterSets, codec: track.codec)
        }

        if waitingForKeyframe {
            guard isKeyframe, formatDescription != nil else { return }
            waitingForKeyframe = false
        }
        guard let formatDescription else { return }

        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            logger.error("camera renderer failed: \(String(describing: self.renderer.error), privacy: .public); waiting for next keyframe")
            renderer.flush()
            waitingForKeyframe = true
            guard isKeyframe else { return }
            waitingForKeyframe = false
        }

        // Parameter sets travel in the format description; the frame keeps only slice/SEI units.
        let payloadUnits = units.filter { !Self.isParameterSet($0, codec: track.codec) }
        guard !payloadUnits.isEmpty,
              let sampleBuffer = Self.makeSampleBuffer(
                  units: payloadUnits,
                  format: formatDescription,
                  sample: sample,
                  timescale: track.timescale,
                  isKeyframe: isKeyframe
              ) else { return }

        renderer.enqueue(sampleBuffer)
        framesDecoded += 1
        statsWindowFrames += 1
        if framesDecoded == 1, let onFirstFrame {
            Task { @MainActor in onFirstFrame() }
        }
        let elapsed = Date().timeIntervalSince(statsWindowStart)
        if elapsed >= 5 {
            let fps = Double(statsWindowFrames) / elapsed
            logger.info("camera fMP4 \(String(format: "%.1f", fps), privacy: .public) fps over \(String(format: "%.1f", elapsed), privacy: .public)s (total \(self.framesDecoded))")
            statsWindowStart = Date()
            statsWindowFrames = 0
        }
    }

    private func installFormat(parameterSets: [Data], codec: FMP4VideoCodec) {
        guard let format = Self.makeFormatDescription(parameterSets: parameterSets, codec: codec) else {
            logger.error("camera format description rejected for \(codec.rawValue, privacy: .public)")
            return
        }
        let changed = formatDescription != nil
        formatDescription = format
        activeParameterSets = parameterSets
        if changed {
            // A resolution or profile switch must start again from a keyframe.
            renderer.flush()
            waitingForKeyframe = true
        }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        logger.info("camera format \(codec.rawValue, privacy: .public) \(dims.width)x\(dims.height)")
    }

    // MARK: - CoreMedia helpers

    private static func nalUnits(of data: Data, lengthSize: Int) -> [Data]? {
        if let units = VideoNALUnits.split(data, lengthSize: lengthSize) {
            return units
        }
        if let converted = VideoNALUnits.annexBToLengthPrefixed(data) {
            return VideoNALUnits.split(converted, lengthSize: 4)
        }
        return nil
    }

    static func isParameterSet(_ unit: Data, codec: FMP4VideoCodec) -> Bool {
        let type = VideoNALUnits.nalType(unit, codec: codec)
        switch codec {
        case .h264: return type == 7 || type == 8
        case .hevc: return (32...34).contains(type)
        }
    }

    static func makeFormatDescription(parameterSets: [Data], codec: FMP4VideoCodec) -> CMVideoFormatDescription? {
        guard !parameterSets.isEmpty else { return nil }
        let copies: [UnsafeMutablePointer<UInt8>] = parameterSets.map { set in
            let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: ptr, count: set.count)
            return ptr
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = parameterSets.map(\.count)

        var format: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &format
            )
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &format
            )
        }
        return status == noErr ? format : nil
    }

    static func makeSampleBuffer(
        units: [Data],
        format: CMVideoFormatDescription,
        sample: FMP4Sample,
        timescale: UInt32,
        isKeyframe: Bool
    ) -> CMSampleBuffer? {
        var payload = Data(capacity: units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            let len = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: len) { payload.append(contentsOf: $0) }
            payload.append(unit)
        }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let copyStatus = payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        let scale = CMTimeScale(clamping: timescale == 0 ? 90_000 : timescale)
        let dts = CMTime(value: CMTimeValue(clamping: sample.decodeTime), timescale: scale)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(sample.duration), timescale: scale),
            presentationTimeStamp: CMTimeAdd(dts, CMTime(value: CMTimeValue(sample.compositionOffset), timescale: scale)),
            decodeTimeStamp: dts
        )
        var sampleSize = payload.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            if !isKeyframe {
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }
        return sampleBuffer
    }
}

// MARK: - SwiftUI surface

/// Hosts the player's display layer; the layer outlives SwiftUI view re-creation.
struct CameraLiveVideoSurface: NSViewRepresentable {
    let player: CameraLiveVideoPlayer

    func makeNSView(context: Context) -> CameraLiveVideoHostView {
        let view = CameraLiveVideoHostView()
        view.attach(player.displayLayer)
        return view
    }

    func updateNSView(_ nsView: CameraLiveVideoHostView, context: Context) {
        nsView.attach(player.displayLayer)
    }

    static func dismantleNSView(_ nsView: CameraLiveVideoHostView, coordinator: ()) {
        nsView.detach()
    }
}

final class CameraLiveVideoHostView: NSView {
    private weak var videoLayer: CALayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(_ newLayer: CALayer) {
        guard videoLayer !== newLayer else { return }
        videoLayer?.removeFromSuperlayer()
        newLayer.removeFromSuperlayer()
        layer?.addSublayer(newLayer)
        videoLayer = newLayer
        needsLayout = true
    }

    func detach() {
        videoLayer?.removeFromSuperlayer()
        videoLayer = nil
    }

    /// Clicks fall through to the window drag area underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // While in Picture in Picture, AVKit hosts the video container layer inside PIPPanel and
        // derives its sublayerTransform from displayLayer.bounds; do not overwrite it with the
        // hidden floating window's bounds.
        let isInPiP = videoLayer?.sublayers?.contains {
            String(describing: type(of: $0)).contains("PictureInPicture")
        } ?? false
        guard !isInPiP else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer?.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Native Picture in Picture

/// Moves the live display layer into the system Picture-in-Picture window (#97).
///
/// The camera is a live source, so the playback delegate reports an endless time range that
/// is never paused; the system then hides scrubbing and shows only restore / close.
@MainActor
final class CameraPictureInPicture: NSObject {
    private let displayLayer: AVSampleBufferDisplayLayer
    private(set) var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private weak var observedPiPContentView: NSView?
    private var pipFrameObserver: NSObjectProtocol?
    private var pipSyncTask: Task<Void, Never>?

    private(set) var isPossible = false
    private(set) var isActive = false

    /// Fires whenever `isPossible` or `isActive` changes.
    var onStateChange: (() -> Void)?
    /// The user pressed the PiP "back to app" button; show the floating window again.
    var onRestore: (() -> Void)?
    /// PiP ended without a restore request (the user closed it).
    var onClosed: (() -> Void)?
    private var restoreRequested = false

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init()
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.requiresLinearPlayback = true
        controller = pip
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] pip, _ in
            let possible = pip.isPictureInPicturePossible
            Task { @MainActor in
                guard let self, self.isPossible != possible else { return }
                self.isPossible = possible
                self.onStateChange?()
            }
        }
    }

    func start() {
        guard let controller, controller.isPictureInPicturePossible, !controller.isPictureInPictureActive else { return }
        restoreRequested = false
        controller.startPictureInPicture()
    }

    /// Programmatic stop means "bring the floating window back", never "close the camera".
    func stop() {
        guard controller?.isPictureInPictureActive == true else { return }
        restoreRequested = true
        controller?.stopPictureInPicture()
    }

    func invalidate() {
        pipSyncTask?.cancel()
        pipSyncTask = nil
        stopObservingPiPWindow()
        possibleObservation?.invalidate()
        possibleObservation = nil
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        controller?.delegate = nil
        controller = nil
    }

    private func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        onStateChange?()
    }

    /// macOS `AVPictureInPictureSampleBufferDisplayLayerView` moves `displayLayer`'s internal
    /// `AVSampleBufferDisplayLayerVideoContainerLayer` into the `PIPPanel` `CAContext` with a
    /// 1600x900 frame while keeping the pre-PiP `sublayerTransform` from `displayLayer.bounds`,
    /// which clips the video to a top-right corner. Syncing `displayLayer.bounds` to `PIPPanel`'s
    /// content view forces `AVSampleBufferDisplayLayer` to recompute `sublayerTransform` for the
    /// exact PiP window size.
    fileprivate func syncPictureInPictureLayerBounds() {
        guard isActive,
              let pipWindow = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("PIP") }),
              let contentView = pipWindow.contentView,
              contentView.bounds.width > 1,
              contentView.bounds.height > 1 else { return }

        if observedPiPContentView !== contentView {
            stopObservingPiPWindow()
            observedPiPContentView = contentView
            contentView.postsFrameChangedNotifications = true
            pipFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncPictureInPictureLayerBounds()
                }
            }
        }

        let targetBounds = CGRect(origin: .zero, size: contentView.bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: max(targetBounds.width - 1, 1),
            height: max(targetBounds.height - 1, 1)
        )
        displayLayer.layoutIfNeeded()
        displayLayer.bounds = targetBounds
        displayLayer.layoutIfNeeded()
        CATransaction.commit()
    }

    fileprivate func restoreHostLayerBounds() {
        pipSyncTask?.cancel()
        pipSyncTask = nil
        stopObservingPiPWindow()
        guard let superlayer = displayLayer.superlayer,
              superlayer.bounds.width > 1,
              superlayer.bounds.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: max(superlayer.bounds.width - 1, 1),
            height: max(superlayer.bounds.height - 1, 1)
        )
        displayLayer.layoutIfNeeded()
        displayLayer.frame = superlayer.bounds
        displayLayer.layoutIfNeeded()
        CATransaction.commit()
    }

    private func stopObservingPiPWindow() {
        if let pipFrameObserver {
            NotificationCenter.default.removeObserver(pipFrameObserver)
            self.pipFrameObserver = nil
        }
        observedPiPContentView = nil
    }
}

extension CameraPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            setActive(true)
            syncPictureInPictureLayerBounds()
            pipSyncTask?.cancel()
            pipSyncTask = Task { @MainActor [weak self] in
                for delayMs in [60, 220, 500] {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                    guard !Task.isCancelled, let self, self.isActive else { return }
                    self.syncPictureInPictureLayerBounds()
                }
            }
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        MainActor.assumeIsolated {
            setActive(false)
            restoreHostLayerBounds()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            restoreRequested = true
            onRestore?()
        }
        completionHandler(true)
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            setActive(false)
            restoreHostLayerBounds()
            if restoreRequested { onRestore?() } else { onClosed?() }
            restoreRequested = false
        }
    }
}

extension CameraPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        Task { @MainActor [weak self] in
            self?.syncPictureInPictureLayerBounds()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

// MARK: - Window dragging

/// Lets a borderless panel be dragged from SwiftUI regions. `NSHostingView` swallows mouse-down,
/// so `isMovableByWindowBackground` alone never moves the camera window.
struct WindowDragArea: NSViewRepresentable {
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> WindowDragView {
        let view = WindowDragView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: WindowDragView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}

final class WindowDragView: NSView {
    var onDoubleClick: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onDoubleClick {
            onDoubleClick()
            return
        }
        window?.performDrag(with: event)
    }
}
