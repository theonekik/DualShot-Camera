//
//  CameraSessionEngine.swift
//  DualShot Camera
//
//  Concrete CameraEngineProtocol implementation: owns the AVCaptureSession
//  (primary high-resolution back camera, 4K-capable master stream), reconfigures
//  frame rate + dimensions per QualityPreset, and wires the Metal dual-crop
//  pipeline into the dual asset writer.
//

import AVFoundation
import CoreMedia
import Foundation
import os
import Synchronization

/// AVFoundation session engine.
///
/// ## Threading
/// `nonisolated` by design: AVFoundation delivers frames on arbitrary queues.
/// Mutable state is confined either to `sessionQueue` (session configuration,
/// running, recording lifecycle) or to the pipeline's serial render queue
/// (frame processing), and the remaining cross-thread flags are Mutex-guarded.
///
/// ## Pipeline wiring
/// ```
/// AVCaptureVideoDataOutput (serial queue)
///   └─► MetalDualCropPipeline (delegate)
///         └─► onRender ─► engine.handleRender
///               ├─► dualFrameStream (AsyncStream, preview; skipped while recording)
///               └─► DualAssetWriterEngine.append (actor, PTS-rebased)
/// AVCaptureAudioDataOutput (serial queue)
///   └─► engine.captureOutput ─► DualAssetWriterEngine.appendAudio
/// ```
public nonisolated final class CameraSessionEngine: NSObject, CameraEngineProtocol, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    public static let logger = Logger(subsystem: "com.dualshot.camera", category: "CameraSessionEngine")

    // MARK: - Composition (CameraEngineProtocol)

    public let stateMachine: CameraStateMachine
    public let assetWriter: any DualAssetWriterProtocol
    private let pipeline: MetalDualCropPipeline

    private let presetLock: Mutex<QualityPreset>
    public var currentPreset: QualityPreset {
        presetLock.withLock { $0 }
    }

    private let positionLock = Mutex<CameraPosition>(.back)
    public var cameraPosition: CameraPosition {
        positionLock.withLock { $0 }
    }

    private let cinematicLock = Mutex<Bool>(false)
    public var isCinematicEnabled: Bool {
        cinematicLock.withLock { $0 }
    }

    private let verticalZoomLock = Mutex<VerticalZoomScale>(.oneX)
    public var verticalZoomScale: VerticalZoomScale {
        verticalZoomLock.withLock { $0 }
    }

    // Preview stream: bufferingNewest(1) — the UI needs the latest frame only.
    public let dualFrameStream: AsyncStream<DualRenderOutput>
    public let previewFrames: AsyncStream<DualPreviewFrame>
    public let events: AsyncStream<CameraEvent>
    private let dualFrameContinuation: AsyncStream<DualRenderOutput>.Continuation
    private let previewContinuation: AsyncStream<DualPreviewFrame>.Continuation
    private let eventContinuation: AsyncStream<CameraEvent>.Continuation

    // MARK: - AVFoundation

    private let session = AVCaptureSession()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.dualshot.session", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.dualshot.audio", qos: .userInitiated)

    /// Current video input / device (confined to `sessionQueue`).
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var currentVideoDevice: AVCaptureDevice?

    /// KVO observation of the current device's live Portrait Effect state
    /// (Control Center can toggle it while the app is active). Confined to
    /// `sessionQueue`; re-established whenever the active device changes.
    private var portraitEffectObservation: NSKeyValueObservation?

    /// Whether a Cinematic request is armed but waiting on the Control Center
    /// Portrait Effect toggle (which the app cannot set programmatically).
    private let cinematicPendingLock = Mutex<Bool>(false)
    /// The task polling for the Control Center toggle while a request is pending.
    private let cinematicWatcherLock = Mutex<Task<Void, Never>?>(nil)

    private struct EngineFlags {
        var isConfigured = false
        var isRunning = false
        var isRecording = false
    }
    private let flagsLock = Mutex(EngineFlags())

    /// A writer session pre-started in the background so the record tap is
    /// instant (AVAssetWriter/HEVC startup can take several seconds).
    private let preparedSessionLock = Mutex<DualRecordingSession?>(nil)

    /// The in-flight warm-up task, so a record tap can await it instead of
    /// racing an on-demand start against it on the writer's queue.
    private let warmUpTaskLock = Mutex<Task<Void, Never>?>(nil)

    /// The stream selection for the next recording (defaults to both).
    private let streamSelectionLock = Mutex<DualStreamSelection>(.both)

    /// Starts a fresh writer session in the background (the cost lands during
    /// preview, not on the record tap). Serialized: a record tap awaits the
    /// in-flight warm-up rather than starting a second session concurrently
    /// (which would collide on the writer and leave a dead session behind).
    private func warmUpWriter() async {
        let task = Task { await self.performWarmUp() }
        warmUpTaskLock.withLock { $0 = task }
        await task.value
        warmUpTaskLock.withLock { $0 = nil }
    }

    private func performWarmUp() async {
        guard flagsLock.withLock({ $0.isRunning }) else { return }
        let preset = currentPreset
        let targets = pipeline.targets
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DualShot", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            let session = try await assetWriter.startSession(
                preset: preset,
                directory: directory,
                fileType: .mov,
                targets: targets,
                includeAudio: true
            )
            preparedSessionLock.withLock { $0 = session }
            Self.logger.info("writer session pre-warmed")
        } catch {
            Self.logger.error("writer pre-warm failed: \(Self.describe(error))")
        }
    }

    /// Returns the pre-warmed session, waiting for an in-flight warm-up if one
    /// is running, or `nil` when none is available.
    private func takePreparedSession() async -> DualRecordingSession? {
        if let session = preparedSessionLock.withLock({ $0 }) {
            preparedSessionLock.withLock { $0 = nil }
            return session
        }
        if let task = warmUpTaskLock.withLock({ $0 }) {
            await task.value
            if let session = preparedSessionLock.withLock({ $0 }) {
                preparedSessionLock.withLock { $0 = nil }
                return session
            }
        }
        return nil
    }

    /// Discards a stale pre-warmed session (targets changed via preset/camera
    /// changes) and re-warms. Never touches an in-flight recording.
    private func invalidatePreparedWriter() async {
        guard preparedSessionLock.withLock({ $0 }) != nil else { return }
        preparedSessionLock.withLock { $0 = nil }
        await assetWriter.cancelWriting()
        await warmUpWriter()
    }

    /// Applies the active-stream selection for recordings: forwards it to the
    /// dual writer (which builds writers/files only for active streams at the
    /// next startSession) and re-arms any pre-warmed session so the next
    /// recording matches the toggles. Ignored while a recording is in flight.
    public func setActiveStreams(_ selection: DualStreamSelection) async {
        let changed = streamSelectionLock.withLock { previous -> Bool in
            guard previous != selection else { return false }
            previous = selection
            return true
        }
        guard changed, !flagsLock.withLock({ $0.isRecording }) else { return }
        await assetWriter.setActiveStreams(selection)
        await invalidatePreparedWriter()
    }

    // MARK: - Init

    public init(
        preset: QualityPreset = .p1080_30,
        stateMachine: CameraStateMachine = .shared,
        assetWriter: (any DualAssetWriterProtocol)? = nil,
        pipeline: MetalDualCropPipeline? = nil
    ) throws {
        self.stateMachine = stateMachine
        self.presetLock = Mutex(preset)
        let (dualStream, dualContinuation) = AsyncStream<DualRenderOutput>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.dualFrameStream = dualStream
        self.dualFrameContinuation = dualContinuation
        let (previewStream, previewContinuation) = AsyncStream<DualPreviewFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.previewFrames = previewStream
        self.previewContinuation = previewContinuation
        let (eventStream, eventContinuation) = AsyncStream<CameraEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = eventStream
        self.eventContinuation = eventContinuation
        let renderPipeline = try pipeline ?? MetalDualCropPipeline(preset: preset)
        self.pipeline = renderPipeline
        self.assetWriter = assetWriter ?? DualAssetWriterEngine()
        super.init()
        renderPipeline.onRender = { [weak self] output in
            self?.handleRender(output)
        }
        renderPipeline.onPreview = { [weak self] frame in
            self?.previewContinuation.yield(frame)
        }
    }

    // MARK: - Frame output

    /// Runs on the pipeline's serial render queue.
    private func handleRender(_ output: DualRenderOutput) {
        // `dualFrameStream` is intentionally NOT fed with pool-backed buffers:
        // an unconsumed `.bufferingNewest(1)` stream would retain one frame
        // pair forever, starving the bounded pools and causing visible preview
        // stutter. Live preview flows through `previewFrames` (persistent,
        // non-pooled buffers), so the screen stays live regardless.
        if flagsLock.withLock({ $0.isRecording }) {
            // Recording: every pool buffer belongs to the writer (bounded
            // pools → bounded memory). Append failures are logged (never
            // silently swallowed) so a dying writer is visible in the console.
            Task {
                do {
                    try await self.assetWriter.append(output)
                } catch {
                    Self.logger.error("video append failed: \(Self.describe(error))")
                }
            }
        }
    }

    // MARK: - CameraEngineProtocol: session configuration

    public func requestAuthorization() async throws {
        let videoGranted = await AVCaptureDevice.requestAccess(for: .video)
        guard videoGranted else { throw CameraError.permissionDenied }
        if !(await AVCaptureDevice.requestAccess(for: .audio)) {
            Self.logger.warning("Microphone permission denied — recording will be video-only")
        }
    }

    public func configure(preset: QualityPreset) async throws {
        // Format changes require a stopped session — stop first if live.
        if flagsLock.withLock({ $0.isRunning }) || stateMachine.phase == .previewing {
            await onSessionQueueVoid { [self] in
                if self.session.isRunning { self.session.stopRunning() }
                self.flagsLock.withLock { $0.isRunning = false }
            }
        }
        try stateMachine.transition(to: .configuring)
        do {
            let sourceSize = try await onSessionQueue { [self] in
                try self.configureSessionOnQueue(preset: preset)
            }
            try pipeline.configure(preset: preset, sourceSize: sourceSize)
            pipeline.updateOrientation(
                rotationDegrees: Self.rotationAngle(for: positionLock.withLock { $0 }),
                mirrored: Self.shouldMirror(for: positionLock.withLock { $0 })
            )
            presetLock.withLock { $0 = preset }
            flagsLock.withLock { $0.isConfigured = true }
            try await startSessionRunning()
            try stateMachine.transition(to: .previewing)
            eventContinuation.yield(.presetApplied(preset))
            Self.logger.info("configured \(preset) (source \(sourceSize.width)x\(sourceSize.height), ~\(self.pipeline.estimatedMemoryBytes() / 1_048_576) MiB pipeline budget)")
        } catch {
            stateMachine.forceTransition(to: .error(.configurationFailed(reason: Self.describe(error))))
            throw error
        }
    }

    public func updatePreset(_ preset: QualityPreset) async throws {
        guard stateMachine.phase == .idle else {
            throw CameraError.configurationFailed(reason: "updatePreset requires a stopped session (state .idle)")
        }
        guard flagsLock.withLock({ $0.isConfigured }) else {
            // Nothing configured yet — the preset is applied by configure(preset:).
            presetLock.withLock { $0 = preset }
            return
        }
        do {
            let sourceSize = try await onSessionQueue { [self] in
                try self.configureSessionOnQueue(preset: preset)
            }
            try pipeline.configure(preset: preset, sourceSize: sourceSize)
            pipeline.updateOrientation(
                rotationDegrees: Self.rotationAngle(for: positionLock.withLock { $0 }),
                mirrored: Self.shouldMirror(for: positionLock.withLock { $0 })
            )
            presetLock.withLock { $0 = preset }
            eventContinuation.yield(.presetApplied(preset))
            Self.logger.info("updated preset to \(preset)")
            Task { await self.invalidatePreparedWriter() }
        } catch {
            eventContinuation.yield(.errorOccurred(.configurationFailed(reason: Self.describe(error))))
            throw error
        }
    }

    // MARK: - CameraEngineProtocol: camera switching

    public func switchCamera(to position: CameraPosition) async throws {
        guard stateMachine.phase == .previewing || stateMachine.phase == .recording else {
            throw CameraError.invalidStateTransition(from: stateMachine.phase, to: .configuring)
        }
        guard positionLock.withLock({ $0 }) != position else {
            return // already on the requested camera
        }
        let deliveredSize = try await onSessionQueue { [self] in
            try self.swapVideoInputOnQueue(to: position)
        }
        // Apply the video-data-output connection settings AFTER the
        // configuration transaction: `commitConfiguration` rebuilds the
        // connection for the new input, so rotation/mirroring set inside the
        // transaction would be reset (or land on the old input's connection).
        await onSessionQueueVoid { [self] in
            self.applyConnectionOrientationOnQueue(position: position)
        }
        positionLock.withLock { $0 = position }
        eventContinuation.yield(.cameraSwitched(position))
        trace("switched camera to \(position.rawValue)")

        // Re-target the pipeline for the new camera's delivered (upright)
        // frame size. During recording the pools must stay fixed (the writer
        // is sized to them), so only the pipeline's geometry/rotation config
        // is refreshed — the render adapts to whatever dims arrive.
        if flagsLock.withLock({ $0.isRecording }) {
            pipeline.updateOrientation(rotationDegrees: Self.rotationAngle(for: position), mirrored: Self.shouldMirror(for: position))
        } else {
            try pipeline.configure(preset: presetLock.withLock { $0 }, sourceSize: deliveredSize)
            pipeline.updateOrientation(rotationDegrees: Self.rotationAngle(for: position), mirrored: Self.shouldMirror(for: position))
            // The pre-warmed writer session's targets are now stale.
            Task { await self.invalidatePreparedWriter() }
        }

        // If Cinematic Mode was requested, re-apply it on the new device — its
        // format may not be depth-capable, so auto-adjust when it isn't.
        if cinematicLock.withLock({ $0 }) {
            do {
                let outcome = try await onSessionQueue { [self] in
                    try self.applyCinematicOnQueue(enabled: true)
                }
                try reapplyPipelineAfterFormatChange(outcome: outcome)
                eventContinuation.yield(.cinematicChanged(outcome.active))
                if let toast = outcome.toastMessage {
                    eventContinuation.yield(.cinematicAdjusted(toast))
                } else if outcome.pending {
                    // Already waiting on the Control Center toggle — keep as-is.
                } else if let failure = outcome.failureMessage {
                    cinematicLock.withLock { $0 = false }
                    eventContinuation.yield(.cinematicUnsupported(failure))
                }
            } catch {
                eventContinuation.yield(.cinematicUnsupported("Cinematic Mode could not be re-applied: \(Self.describe(error))"))
            }
        }
    }

    /// Swaps the session's video input for the target camera inside a single
    /// configuration transaction — the session keeps running, so the render
    /// pipeline and an in-flight recording are never interrupted. Returns the
    /// delivered (upright) source frame size for pipeline re-targeting.
    ///
    /// Order matters: the old input is removed FIRST because
    /// `canSetSessionPreset` / `canAddInput` are evaluated against the
    /// session's current inputs — a 4K back camera present in the session can
    /// make a 1080p-only front camera unaddable.
    private func swapVideoInputOnQueue(to position: CameraPosition) throws -> CGSize {
        guard let currentInput = videoDeviceInput else {
            throw CameraError.configurationFailed(reason: "no active video input to swap")
        }
        let preset = presetLock.withLock { $0 }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 1. Remove the current video input first.
        session.removeInput(currentInput)

        // 2. Resolve the best (device, format) for the target position,
        //    preferring TrueDepth for the front with a wide-camera fallback.
        guard let (device, format) = Self.bestDeviceAndFormat(for: position, preset: preset) else {
            Self.restoreVideoInput(session: session, from: currentInput)
            throw CameraError.configurationFailed(reason: "no camera/format available for \(position)")
        }
        let formatDims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)

        // 3. Downgrade the session preset when the new camera can't deliver
        //    the current preset's resolution (e.g. no 4K on the front).
        Self.downgradePresetIfNeeded(session: session, preset: preset, formatDims: formatDims, device: device)

        // 4. Apply the format + natural auto-capture settings to the device.
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(preset.frameRate))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            Self.applyAutoCaptureSettings(to: device)
            // Standard sRGB output: matches the preview renderer and CI
            // pipeline, giving the feed natural gamma/brightness.
            if format.supportedColorSpaces.contains(.sRGB) {
                device.activeColorSpace = .sRGB
            }
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
            Self.restoreVideoInput(session: session, from: currentInput)
            throw CameraError.configurationFailed(reason: "cannot lock camera for switch: \(error.localizedDescription)")
        }

        // 5. Build + add the new input; roll back to the previous camera on
        //    failure so the session is never left without video.
        guard let newInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(newInput) else {
            Self.restoreVideoInput(session: session, from: currentInput)
            throw CameraError.configurationFailed(reason: "cannot add video input for \(device.localizedName)")
        }
        session.addInput(newInput)
        videoDeviceInput = newInput
        currentVideoDevice = device
        observePortraitEffect(on: device)

        trace("video input swapped -> \(device.localizedName) @ \(formatDims.width)x\(formatDims.height)")

        // The pipeline consumes the upright (rotated) buffers, so report the
        // swapped frame size.
        return Self.deliveredSourceSize(
            formatSize: CGSize(width: CGFloat(formatDims.width), height: CGFloat(formatDims.height)),
            position: position
        )
    }

    /// Candidate devices for a position, best-first (front prefers the
    /// depth-capable TrueDepth camera).
    private static func bestDeviceAndFormat(for position: CameraPosition, preset: QualityPreset) -> (device: AVCaptureDevice, format: AVCaptureDevice.Format)? {
        for device in candidateDevices(for: position) {
            if let format = bestFormat(for: device, preset: preset) {
                return (device, format)
            }
        }
        return nil
    }

    private static func candidateDevices(for position: CameraPosition) -> [AVCaptureDevice] {
        switch position {
        case .back:
            return [AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)].compactMap { $0 }
        case .front:
            var devices: [AVCaptureDevice] = []
            if let trueDepth = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) {
                devices.append(trueDepth)
            }
            if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
               !devices.contains(where: { $0.uniqueID == wide.uniqueID }) {
                devices.append(wide)
            }
            return devices
        }
    }

    /// Lowers the session preset when the new camera can't deliver the current
    /// preset's resolution. Called after the old input is removed so
    /// `canSetSessionPreset` reflects only the remaining session inputs.
    private static func downgradePresetIfNeeded(session: AVCaptureSession, preset: QualityPreset, formatDims: CMVideoDimensions, device: AVCaptureDevice) {
        let current = preset.captureSessionPreset
        let target: AVCaptureSession.Preset
        switch current {
        case .hd4K3840x2160:
            target = (formatDims.width >= 3840 && formatDims.height >= 2160) ? .hd4K3840x2160 : .hd1920x1080
        case .hd1920x1080:
            target = (formatDims.width >= 1920 && formatDims.height >= 1080) ? .hd1920x1080 : .high
        default:
            target = current
        }
        if target != current, session.canSetSessionPreset(target) {
            session.sessionPreset = target
            Self.logger.info("session preset set to \(target.rawValue, privacy: .public) for \(device.localizedName, privacy: .public)")
        }
    }

    /// Re-adds the previous camera's input after a failed swap (inside the
    /// active configuration transaction, so the commit restores the session).
    private static func restoreVideoInput(session: AVCaptureSession, from previousInput: AVCaptureDeviceInput) {
        if let restored = try? AVCaptureDeviceInput(device: previousInput.device),
           session.canAddInput(restored) {
            session.addInput(restored)
        } else {
            Self.logger.error("camera switch failed and the previous input could not be restored")
        }
    }

    /// Rotation (degrees, clockwise) that makes a camera's delivered frames
    /// upright when the phone is held portrait.
    ///
    /// Device-verified: both cameras are upright at 90°. The front camera is
    /// additionally mirrored (`shouldMirror`), and the mirror + 90° rotation
    /// combination produces the natural upright selfie view. (An earlier
    /// 270° assumption for the front showed the image 180° off on hardware.)
    private static func rotationAngle(for position: CameraPosition) -> CGFloat {
        switch position {
        case .back: 90
        case .front: 90
        }
    }

    /// Whether the connection must mirror the frames (front self-tapes).
    private static func shouldMirror(for position: CameraPosition) -> Bool {
        position == .front
    }

    /// The frame size the data output delivers after the connection rotation.
    private static func deliveredSourceSize(formatSize: CGSize, position: CameraPosition) -> CGSize {
        let angle = rotationAngle(for: position)
        if Int(angle) % 180 != 0 {
            return CGSize(width: formatSize.height, height: formatSize.width)
        }
        return formatSize
    }

    /// Configures the video data output connection: upright rotation for the
    /// current position and horizontal mirroring for the front camera. Runs on
    /// `sessionQueue` (call inside a configuration transaction when possible).
    private func applyConnectionOrientationOnQueue(position: CameraPosition) {
        guard let connection = videoDataOutput.connection(with: .video) else {
            trace("no video connection to orient")
            return
        }
        connection.automaticallyAdjustsVideoMirroring = false
        let angle = Self.rotationAngle(for: position)
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = Self.shouldMirror(for: position)
        }
        trace("video connection: rotation \(Int(angle))°, mirrored \(connection.isVideoMirrored)")
    }

    /// Configures natural auto-capture behavior — continuous auto-exposure,
    /// auto-white-balance, and auto-focus at the frame center, plus the
    /// low-light boost — so the feed looks bright and balanced like the system
    /// camera. Re-applied whenever the device, format, or preset changes
    /// (front and rear alike). The caller must hold the device configuration
    /// lock; unsupported modes are skipped per device (e.g. the front
    /// TrueDepth camera has fixed focus).
    private static func applyAutoCaptureSettings(to device: AVCaptureDevice) {
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
            device.setExposureTargetBias(0) { _ in } // neutral exposure compensation
        }
        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = true
        }
    }

    private static func videoDevice(for position: CameraPosition) throws -> AVCaptureDevice {
        switch position {
        case .back:
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                throw CameraError.configurationFailed(reason: "back camera unavailable")
            }
            return device
        case .front:
            // Prefer the TrueDepth front camera (depth-capable for Cinematic Mode).
            if let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) {
                return device
            }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
                throw CameraError.configurationFailed(reason: "front camera unavailable")
            }
            return device
        }
    }

    // MARK: - CameraEngineProtocol: Cinematic Mode

    /// Result of applying a Cinematic request on `sessionQueue`.
    private struct CinematicOutcome {
        /// Whether the depth blur is rendering (or will render) after the request.
        var active = false
        /// Whether a portrait-effect-capable format is active.
        var supported = false
        /// Whether the capture format was switched to gain depth support.
        var didAdjustFormat = false
        /// Whether the request is armed but waiting on the Control Center toggle.
        var pending = false
        /// New delivered source size when the format changed (nil otherwise).
        var sourceSize: CGSize?
        /// User-facing toast text when `didAdjustFormat` is true.
        var toastMessage: String?
        /// Why the request could not be honored (Control Center off, no
        /// depth-capable format). Emitted as `.cinematicPending` (CC off) or
        /// `.cinematicUnsupported` (no depth format / error).
        var failureMessage: String?
    }

    /// Requests Cinematic Mode (Portrait Effect depth blur).
    ///
    /// Portrait Effect cannot be switched programmatically:
    /// `AVCaptureDevice.isPortraitEffectEnabled` is a READ-ONLY class property
    /// reflecting the Control Center toggle (the app opts in once via
    /// `NSCameraPortraitEffectEnabled` in Info.plist). What the app CAN do is
    /// guarantee the capture side: when the effect is enabled in Control Center
    /// and the active format is depth-capable, the blur renders.
    ///
    /// - Enabling: when Control Center has Portrait Effect off, the request is
    ///   ARMED (`.cinematicPending` — the UI guides the user to the Control
    ///   Center Video Effects tile) and a watcher completes the activation —
    ///   format auto-adjust to a depth-capable 1080p@30 when needed,
    ///   `.cinematicAdjusted` toast, `.cinematicChanged(true)` — the moment the
    ///   user enables the effect. When the active format already lacks
    ///   `isPortraitEffectSupported` (e.g. 4K or 60 fps), the engine
    ///   live-switches to a depth-capable format inside a configuration
    ///   transaction, so the running session is never interrupted.
    /// - Disabling: cancels any pending wait and restores the user's selected
    ///   `QualityPreset` format live. (The system toggle itself still follows
    ///   Control Center; on a non-depth-capable restored format the effect
    ///   deactivates on its own.)
    public func setCinematic(enabled: Bool) async {
        if !enabled {
            // Any pending wait on the Control Center toggle ends here.
            cinematicPendingLock.withLock { $0 = false }
            stopCinematicWatcher()
        }
        cinematicLock.withLock { $0 = enabled }
        do {
            let outcome = try await onSessionQueue { [self] in
                try self.applyCinematicOnQueue(enabled: enabled)
            }
            // A live format change — re-target the pipeline (and re-arm the
            // writer, whose pixel-buffer adaptors are sized to its targets).
            try reapplyPipelineAfterFormatChange(outcome: outcome)
            eventContinuation.yield(.cinematicChanged(outcome.active))
            if enabled {
                if let toast = outcome.toastMessage {
                    eventContinuation.yield(.cinematicAdjusted(toast))
                } else if outcome.pending {
                    // Portrait Effect is off in Control Center — the request
                    // stays armed and activates automatically once enabled.
                    eventContinuation.yield(.cinematicPending(
                        outcome.failureMessage ?? "Portrait Effect is off — enable it in Control Center to activate Cinematic."
                    ))
                } else if let failure = outcome.failureMessage {
                    cinematicLock.withLock { $0 = false }
                    eventContinuation.yield(.cinematicUnsupported(failure))
                }
            }
        } catch {
            cinematicLock.withLock { $0 = false }
            cinematicPendingLock.withLock { $0 = false }
            stopCinematicWatcher()
            eventContinuation.yield(.cinematicUnsupported("Cinematic Mode could not be activated: \(Self.describe(error))"))
            Self.logger.error("cinematic toggle failed: \(Self.describe(error))")
        }
    }

    /// Applies a Cinematic request on `sessionQueue`. See `setCinematic`.
    private func applyCinematicOnQueue(enabled: Bool) throws -> CinematicOutcome {
        guard let device = currentVideoDevice else {
            throw CameraError.configurationFailed(reason: "no active video device for Cinematic Mode")
        }
        if enabled {
            // The Control Center toggle is the master switch — the app cannot
            // set it. Keep the request armed (pending) and complete the
            // activation — format auto-adjust + events — the moment the user
            // enables Portrait Effect in Control Center (the watcher does it).
            guard AVCaptureDevice.isPortraitEffectEnabled else {
                cinematicPendingLock.withLock { $0 = true }
                startCinematicWatcher()
                return CinematicOutcome(
                    active: false,
                    supported: false,
                    pending: true,
                    failureMessage: "Portrait Effect is off. Keep this preview open, open Control Center, tap the Video Effects tile (person icon) at the top, and enable Portrait Effect — Cinematic will activate automatically."
                )
            }
            if device.activeFormat.isPortraitEffectSupported {
                // Already on a depth-capable format — nothing to adjust.
                return CinematicOutcome(active: true, supported: true)
            }
            // The active format cannot render the effect (4K, 60 fps, …):
            // discover a depth-capable format (typically 1080p@30) and switch
            // to it live.
            guard let format = Self.bestPortraitEffectFormat(for: device) else {
                return CinematicOutcome(
                    active: false,
                    supported: false,
                    failureMessage: "Cinematic Mode is not supported on this device."
                )
            }
            let sourceSize = try applyFormatOnQueue(
                format: format,
                frameRate: 30,
                sessionPreset: .hd1920x1080,
                device: device
            )
            applyConnectionOrientationOnQueue(position: positionLock.withLock { $0 })
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return CinematicOutcome(
                active: true,
                supported: true,
                didAdjustFormat: true,
                sourceSize: sourceSize,
                toastMessage: Self.portraitEffectToast(dimensions: dims)
            )
        } else {
            // Restore the user's selected preset format. (The system toggle
            // itself follows Control Center and cannot be changed here; on a
            // non-depth-capable restored format the effect deactivates on its
            // own — the desired outcome. `active` below reflects the truth.)
            let preset = presetLock.withLock { $0 }
            guard let format = Self.bestFormat(for: device, preset: preset) else {
                return CinematicOutcome(active: false, supported: false)
            }
            let sourceSize = try applyFormatOnQueue(
                format: format,
                frameRate: preset.frameRate,
                sessionPreset: preset.captureSessionPreset,
                device: device
            )
            applyConnectionOrientationOnQueue(position: positionLock.withLock { $0 })
            return CinematicOutcome(
                active: device.isPortraitEffectActive,
                supported: true,
                sourceSize: sourceSize
            )
        }
    }

    /// Re-targets the render pipeline (and re-arms the pre-warmed writer) after
    /// a live format change. During recording the pool targets must stay fixed
    /// — the writer's adaptors are sized to them — so only the pipeline's
    /// orientation/geometry is refreshed and the render adapts to the new
    /// delivered dimensions.
    private func reapplyPipelineAfterFormatChange(outcome: CinematicOutcome) throws {
        guard let sourceSize = outcome.sourceSize else { return }
        let position = positionLock.withLock { $0 }
        if flagsLock.withLock({ $0.isRecording }) {
            pipeline.updateOrientation(
                rotationDegrees: Self.rotationAngle(for: position),
                mirrored: Self.shouldMirror(for: position)
            )
        } else {
            try pipeline.configure(preset: presetLock.withLock { $0 }, sourceSize: sourceSize)
            pipeline.updateOrientation(
                rotationDegrees: Self.rotationAngle(for: position),
                mirrored: Self.shouldMirror(for: position)
            )
            // The pre-warmed writer's pixel-buffer adaptors are sized to the
            // old targets — cancel and re-arm with the new geometry.
            Task { await self.invalidatePreparedWriter() }
        }
    }

    /// Live-switches the active device format inside a configuration
    /// transaction (the session keeps running — never stopped, so the preview
    /// and any in-flight recording are uninterrupted). Shared by the Cinematic
    /// auto-adjust and preset-restore paths. The caller re-applies connection
    /// orientation after this returns (post-commit, matching the camera-switch
    /// pattern). Returns the delivered (upright) source size.
    private func applyFormatOnQueue(
        format: AVCaptureDevice.Format,
        frameRate: Int,
        sessionPreset: AVCaptureSession.Preset,
        device: AVCaptureDevice
    ) throws -> CGSize {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(sessionPreset) {
            session.sessionPreset = sessionPreset
            trace("session preset set to \(sessionPreset.rawValue) (Cinematic format switch)")
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            Self.applyAutoCaptureSettings(to: device)
            if format.supportedColorSpaces.contains(.sRGB) {
                device.activeColorSpace = .sRGB
            }
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
            throw CameraError.configurationFailed(reason: "cannot lock camera for Cinematic format switch: \(error.localizedDescription)")
        }

        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        trace("Cinematic format \(dims.width)x\(dims.height)@\(frameRate)fps (portrait effect \(format.isPortraitEffectSupported))")

        let formatSize = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        return Self.deliveredSourceSize(formatSize: formatSize, position: positionLock.withLock { $0 })
    }

    /// Picks a portrait-effect-capable format for the device, preferring
    /// 1080p@30 — the canonical depth capture mode
    /// (`videoFrameRateRangeForPortraitEffect` is typically 1–30 fps) — then
    /// the smallest-capable format. `nil` when the device has no depth-capable
    /// format at all.
    private static func bestPortraitEffectFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let supporting = device.formats.filter { $0.isPortraitEffectSupported }
        guard !supporting.isEmpty else { return nil }
        let targetWidth = 1920
        let targetHeight = 1080
        let targetFPS = 30.0
        let fpsCapable = supporting.filter { format in
            let depth30 = format.videoFrameRateRangeForPortraitEffect.map {
                $0.minFrameRate <= targetFPS && $0.maxFrameRate >= targetFPS
            } ?? false
            let captures30 = format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= targetFPS && range.maxFrameRate >= targetFPS
            }
            return depth30 && captures30
        }
        let pool = fpsCapable.isEmpty ? supporting : fpsCapable
        return pool.min { lhs, rhs in
            let lhsDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lhsExact = lhsDims.width == targetWidth && lhsDims.height == targetHeight
            let rhsExact = rhsDims.width == targetWidth && rhsDims.height == targetHeight
            if lhsExact != rhsExact { return lhsExact }
            let lhsArea = Int(lhsDims.width) * Int(lhsDims.height)
            let rhsArea = Int(rhsDims.width) * Int(rhsDims.height)
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            return (lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                < (rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }
    }

    /// Toast text for a successful auto-adjust (1920×1080 → "1080p").
    private static func portraitEffectToast(dimensions: CMVideoDimensions) -> String {
        "Cinematic Blur active (Auto-adjusted to \(Int(dimensions.height))p for Depth Support)"
    }

    /// Tracks the system's live Portrait Effect state for the current device —
    /// Control Center can toggle it while the app is active, and the effect
    /// takes a moment to activate after a format switch. Keeps the UI's
    /// Cinematic indicator honest via `.cinematicChanged`. Re-established
    /// whenever the active device changes; confined to `sessionQueue`.
    private func observePortraitEffect(on device: AVCaptureDevice) {
        portraitEffectObservation?.invalidate()
        portraitEffectObservation = device.observe(\.isPortraitEffectActive, options: [.new]) { [weak self] device, change in
            guard let self else { return }
            let active = change.newValue ?? device.isPortraitEffectActive
            self.sessionQueue.async { [self] in
                guard self.cinematicLock.withLock({ $0 }) else { return }
                self.eventContinuation.yield(.cinematicChanged(active))
                Self.logger.info("Portrait Effect active changed: \(active)")
            }
        }
    }

    /// Starts polling for the Control Center Portrait Effect toggle while a
    /// Cinematic request is pending (the app cannot set the toggle itself).
    /// Completes the activation — format auto-adjust + events — as soon as the
    /// user enables the effect. Cheap: one class-property read every 500 ms.
    private func startCinematicWatcher() {
        stopCinematicWatcher()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                guard self.cinematicPendingLock.withLock({ $0 }) else { return }
                guard AVCaptureDevice.isPortraitEffectEnabled else { continue }
                // Control Center enabled Portrait Effect — complete the activation.
                self.cinematicPendingLock.withLock { $0 = false }
                self.cinematicWatcherLock.withLock { $0 = nil }
                self.trace("Portrait Effect enabled in Control Center — activating Cinematic")
                do {
                    let outcome = try await self.onSessionQueue { [self] in
                        try self.applyCinematicOnQueue(enabled: true)
                    }
                    try self.reapplyPipelineAfterFormatChange(outcome: outcome)
                    self.eventContinuation.yield(.cinematicChanged(outcome.active))
                    if let toast = outcome.toastMessage {
                        self.eventContinuation.yield(.cinematicAdjusted(toast))
                    }
                } catch {
                    self.eventContinuation.yield(.cinematicUnsupported("Cinematic Mode could not be activated: \(Self.describe(error))"))
                }
            }
        }
        cinematicWatcherLock.withLock { $0 = task }
    }

    private func stopCinematicWatcher() {
        if let task = cinematicWatcherLock.withLock({ $0 }) {
            cinematicWatcherLock.withLock { $0 = nil }
            task.cancel()
        }
    }

    // MARK: - CameraEngineProtocol: vertical (9:16) zoom

    /// Sets the 9:16 portrait target zoom scale (1.0x / 1.2x / 1.5x). Live next
    /// frame on the preview card and baked into the recorded vertical asset;
    /// the 16:9 landscape pipeline is never affected. Sticky across
    /// preset/camera changes. Synchronous — the pipeline applies it on its own
    /// queue.
    public func setVerticalZoom(_ scale: VerticalZoomScale) {
        verticalZoomLock.withLock { $0 = scale }
        pipeline.setVerticalZoom(scale.scale)
        Self.logger.info("vertical portrait zoom \(scale.label)")
    }

    // MARK: - CameraEngineProtocol: preview lifecycle

    public func startPreview() async throws {
        switch stateMachine.phase {
        case .previewing:
            return
        case .idle:
            guard flagsLock.withLock({ $0.isConfigured }) else {
                throw CameraError.configurationFailed(reason: "session not configured — call configure(preset:) first")
            }
            try stateMachine.transition(to: .configuring)
            do {
                try await startSessionRunning()
                try stateMachine.transition(to: .previewing)
            } catch {
                stateMachine.forceTransition(to: .idle)
                throw error
            }
        default:
            throw CameraError.invalidStateTransition(from: stateMachine.phase, to: .previewing)
        }
        // Pre-warm the writer session in the background (non-blocking) so the
        // first record tap doesn't pay the multi-second AVAssetWriter/encoder
        // startup. The preview starts immediately.
        Task { await self.warmUpWriter() }
    }

    public func stopPreview() async {
        if stateMachine.phase == .previewing {
            _ = try? stateMachine.transition(to: .idle)
        }
        await onSessionQueueVoid { [self] in
            if self.session.isRunning { self.session.stopRunning() }
            self.flagsLock.withLock { $0.isRunning = false }
        }
    }

    // MARK: - CameraEngineProtocol: recording lifecycle

    public func startRecording() async throws {
        guard stateMachine.phase == .previewing else {
            throw CameraError.invalidStateTransition(from: stateMachine.phase, to: .recording)
        }
        try stateMachine.transition(to: .recording)
        do {
            // Use the pre-warmed writer session when available (instant start);
            // otherwise open one on demand.
            let recording: DualRecordingSession
            if let prepared = await takePreparedSession() {
                recording = prepared
                Self.logger.info("used pre-warmed writer session (instant start)")
            } else {
                let preset = currentPreset
                let targets = pipeline.targets
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("DualShot", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                recording = try await assetWriter.startSession(
                    preset: preset,
                    directory: directory,
                    fileType: .mov,
                    targets: targets,
                    includeAudio: true
                )
            }
            flagsLock.withLock { $0.isRecording = true }
            pipeline.setRecording(true) // render the recording pool targets
            eventContinuation.yield(.recordingStarted(recording))
            Self.logger.info("recording started: \(recording)")
        } catch {
            // Failed to open the writers — return to preview (forced recovery).
            stateMachine.forceTransition(to: .previewing)
            eventContinuation.yield(.errorOccurred(.writerFailed(reason: Self.describe(error))))
            throw error
        }
    }

    public func stopRecording() async throws -> DualRecordingResult {
        guard stateMachine.phase == .recording else {
            throw CameraError.invalidStateTransition(from: stateMachine.phase, to: .processing)
        }
        try stateMachine.transition(to: .processing)
        flagsLock.withLock { $0.isRecording = false } // stop forwarding frames
        pipeline.setRecording(false) // resume preview-only rendering

        do {
            let result = try await assetWriter.finishWriting()
            _ = try? stateMachine.transition(to: .previewing) // processing → previewing
            eventContinuation.yield(.recordingFinished(result))
            Self.logger.info("recording finished: \(result)")
            Task { await self.warmUpWriter() } // non-blocking re-arm for the next recording
            return result
        } catch {
            stateMachine.forceTransition(to: .error(.writerFailed(reason: Self.describe(error))))
            eventContinuation.yield(.errorOccurred(.writerFailed(reason: Self.describe(error))))
            throw error
        }
    }

    public func cancelRecording() async {
        guard stateMachine.phase == .recording else { return }
        _ = try? stateMachine.transition(to: .processing)
        flagsLock.withLock { $0.isRecording = false }
        pipeline.setRecording(false)
        await assetWriter.cancelWriting()
        _ = try? stateMachine.transition(to: .previewing)
        eventContinuation.yield(.recordingCancelled)
        Self.logger.info("recording cancelled")
        Task { await self.warmUpWriter() }
    }

    // MARK: - CameraEngineProtocol: frame pipeline

    public func enqueueFrame(_ sampleBuffer: CMSampleBuffer) {
        pipeline.process(sampleBuffer)
    }

    // MARK: - CameraEngineProtocol: teardown

    public func shutdown() async {
        flagsLock.withLock { $0.isRecording = false }
        cinematicPendingLock.withLock { $0 = false }
        stopCinematicWatcher()
        if stateMachine.phase == .recording {
            await assetWriter.cancelWriting()
        }
        await onSessionQueueVoid { [self] in
            if self.session.isRunning { self.session.stopRunning() }
            self.portraitEffectObservation?.invalidate()
            self.portraitEffectObservation = nil
            self.videoDataOutput.setSampleBufferDelegate(nil, queue: nil)
            self.audioDataOutput.setSampleBufferDelegate(nil, queue: nil)
        }
        pipeline.shutdown()
        stateMachine.forceTransition(to: .idle)
        dualFrameContinuation.finish()
        previewContinuation.finish()
        eventContinuation.finish()
        Self.logger.info("CameraSessionEngine shut down")
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard flagsLock.withLock({ $0.isRecording }) else { return }
        Task { try? await self.assetWriter.appendAudio(sampleBuffer) }
    }

    // MARK: - Session configuration (sessionQueue only)

    /// Builds/reconfigures the session for `preset` on `sessionQueue` and
    /// returns the active format's source frame size.
    private func configureSessionOnQueue(preset: QualityPreset) throws -> CGSize {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Disable the session's wide-color auto-configuration so the explicit
        // sRGB activeColorSpace below is honored (wide gamut P3/HLG buffers
        // render dark/washed through the standard sRGB pipeline).
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        if session.canSetSessionPreset(preset.captureSessionPreset) {
            session.sessionPreset = preset.captureSessionPreset
            trace("session preset set to \(preset.captureSessionPreset)")
        } else {
            trace("session preset \(preset.captureSessionPreset) not supported — using activeFormat only")
        }

        // Camera matching the current position (back wide / front TrueDepth).
        let position = positionLock.withLock { $0 }
        let device = try Self.videoDevice(for: position)
        trace("\(position.rawValue) camera: \(device.localizedName)")

        guard let format = Self.bestFormat(for: device, preset: preset) else {
            throw CameraError.configurationFailed(reason: "no device format supports \(preset)")
        }
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        trace("selected format \(dims.width)x\(dims.height)@\(format.videoSupportedFrameRateRanges.map { "\(Int($0.minFrameRate))-\(Int($0.maxFrameRate))" }.joined(separator: "/"))fps")

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(preset.frameRate))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            Self.applyAutoCaptureSettings(to: device)
            // Standard sRGB output (see the same block in swapVideoInputOnQueue).
            if format.supportedColorSpaces.contains(.sRGB) {
                device.activeColorSpace = .sRGB
            }
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
            throw CameraError.configurationFailed(reason: "cannot lock camera for format change: \(error.localizedDescription)")
        }

        // Inputs (added once; reconfigure only touches the device format).
        if session.inputs.isEmpty {
            let videoInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(videoInput) else {
                throw CameraError.configurationFailed(reason: "cannot add video input")
            }
            session.addInput(videoInput)
            videoDeviceInput = videoInput
            currentVideoDevice = device
            observePortraitEffect(on: device)
            trace("video input added")

            if let microphone = AVCaptureDevice.default(for: .audio) {
                // Explicit audio-session setup: a camera app must claim the
                // audio session before mic capture starts on device.
                let audioSession = AVAudioSession.sharedInstance()
                try? audioSession.setCategory(.record, mode: .videoRecording, options: [])
                try? audioSession.setActive(true)
                if let audioInput = try? AVCaptureDeviceInput(device: microphone),
                   session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                    trace("audio input added")
                } else {
                    trace("audio input unavailable — video-only")
                }
            } else {
                trace("no microphone — video-only")
            }
        } else if let currentInput = videoDeviceInput, currentInput.device != device {
            // A preset change after a camera switch: align the video input to
            // the current position before touching the format.
            session.removeInput(currentInput)
            let videoInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(videoInput) else {
                throw CameraError.configurationFailed(reason: "cannot add video input")
            }
            session.addInput(videoInput)
            videoDeviceInput = videoInput
            currentVideoDevice = device
            observePortraitEffect(on: device)
            trace("video input realigned to \(device.localizedName)")
        }

        // Outputs (added once).
        if !session.outputs.contains(videoDataOutput) {
            // Deliver the camera's NATIVE video-range 420v buffers: Core Image
            // decodes YUV assuming video range, so feeding it full-range 420f
            // data made every frame render ~50% darker than the scene.
            videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ]
            videoDataOutput.alwaysDiscardsLateVideoFrames = true // zero-latency: never queue frames
            videoDataOutput.setSampleBufferDelegate(pipeline, queue: pipeline.processingQueue)
            guard session.canAddOutput(videoDataOutput) else {
                throw CameraError.configurationFailed(reason: "cannot add video data output")
            }
            session.addOutput(videoDataOutput)
            trace("video data output added")
        }

        // Upright orientation + front-camera mirroring on the video connection
        // (delivered buffers arrive already rotated, so the pipeline and the
        // recorded files are upright).
        applyConnectionOrientationOnQueue(position: position)

        if !session.outputs.contains(audioDataOutput) {
            audioDataOutput.setSampleBufferDelegate(self, queue: audioQueue)
            guard session.canAddOutput(audioDataOutput) else {
                throw CameraError.configurationFailed(reason: "cannot add audio data output")
            }
            session.addOutput(audioDataOutput)
            trace("audio data output added")
        }

        // The pipeline consumes the upright (rotated) buffers.
        let formatSize = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        return Self.deliveredSourceSize(formatSize: formatSize, position: position)
    }

    /// Console + unified-log diagnostics (invaluable for device-only issues).
    private func trace(_ message: String) {
        Self.logger.info("\(message, privacy: .public)")
        print("[DualShot] \(message)")
    }

    private func startSessionRunning() async throws {
        let started = try await onSessionQueue { [self] in
            if self.session.isRunning { return true }
            self.session.startRunning()
            return self.session.isRunning
        }
        guard started else {
            throw CameraError.configurationFailed(reason: "AVCaptureSession failed to start")
        }
        flagsLock.withLock { $0.isRunning = true }
    }

    /// Picks the device format closest to the preset: exact dimension match
    /// first, then smallest area, then highest frame rate — all must support
    /// the preset's frame rate. When no format reaches the preset's dimensions
    /// (e.g. the front camera has no 4K), falls back to the largest
    /// fps-capable format so the switch still succeeds.
    private static func bestFormat(for device: AVCaptureDevice, preset: QualityPreset) -> AVCaptureDevice.Format? {
        let targetWidth = Int(preset.dimensions.width)
        let targetHeight = Int(preset.dimensions.height)
        let targetFPS = Double(preset.frameRate)

        let fpsCapable = device.formats.filter { format in
            format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= targetFPS && range.maxFrameRate >= targetFPS
            }
        }
        guard !fpsCapable.isEmpty else { return nil }

        let sized = fpsCapable.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width >= targetWidth && dimensions.height >= targetHeight
        }
        let pool = sized.isEmpty ? fpsCapable : sized

        return pool.min { lhs, rhs in
            let lhsDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lhsExact = lhsDims.width == targetWidth && lhsDims.height == targetHeight
            let rhsExact = rhsDims.width == targetWidth && rhsDims.height == targetHeight
            if lhsExact != rhsExact { return lhsExact }
            let lhsArea = Int(lhsDims.width) * Int(lhsDims.height)
            let rhsArea = Int(rhsDims.width) * Int(rhsDims.height)
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            return lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                > rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }
    }

    // MARK: - Session queue helpers

    private func onSessionQueue<T: Sendable>(_ op: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    continuation.resume(returning: try op())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func onSessionQueueVoid(_ op: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                op()
                continuation.resume()
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let cameraError = error as? CameraError {
            return "\(cameraError)"
        }
        return error.localizedDescription
    }
}
