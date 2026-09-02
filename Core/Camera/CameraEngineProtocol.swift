//
//  CameraEngineProtocol.swift
//  DualShot Camera
//
//  The engine contract: owns the AVCaptureSession configuration lifecycle and
//  the frame-processing pipeline that produces DualRenderOutput pairs.
//

import AVFoundation
import Foundation

/// Manages the camera session configuration and the dual frame-processing
/// pipeline.
///
/// ## Threading
/// The engine is `nonisolated` and `Sendable`: AVFoundation delivers frames on
/// arbitrary queues, so the engine must not be bound to the main actor. The
/// implementation is expected to funnel all work through a single serial
/// pipeline so `DualRenderOutput` (non-Sendable) never crosses an actor
/// boundary.
///
/// ## State
/// The engine drives `stateMachine` through the documented transition table
/// (see `CameraState.validTransitions`) and reports progress via `events`.
public nonisolated protocol CameraEngineProtocol: AnyObject, Sendable {

    // MARK: - Composition

    /// The state machine this engine drives.
    var stateMachine: CameraStateMachine { get }

    /// Currently applied preset.
    var currentPreset: QualityPreset { get }

    /// The dual writer the engine feeds while recording.
    var assetWriter: any DualAssetWriterProtocol { get }

    /// Currently active physical camera.
    var cameraPosition: CameraPosition { get }

    /// Whether Cinematic Mode (depth blur) is requested.
    var isCinematicEnabled: Bool { get }

    /// Whether the 9:16 portrait target is zoomed (1.2x or 1.5x). The 16:9
    /// landscape target is always full-frame.
    var verticalZoomScale: VerticalZoomScale { get }

    /// Selects which output streams recordings write. Forwarded to the dual
    /// writer; any pre-warmed session is discarded and re-armed so the next
    /// recording matches the current toggle state.
    func setActiveStreams(_ selection: DualStreamSelection) async

    /// Stream of processed dual frame pairs (16:9 + 9:16). Unicast: the
    /// recording path subscribes; observers poll `state` for everything else.
    var dualFrameStream: AsyncStream<DualRenderOutput> { get }

    /// Stream of **persistent** dual-crop preview frames (display resolution,
    /// pipeline-owned, safe to read at any time — not pool-backed). Unicast:
    /// the UI owns the single subscription. Flows during preview AND recording.
    var previewFrames: AsyncStream<DualPreviewFrame> { get }

    /// High-level domain events (recording lifecycle, errors, preset changes).
    var events: AsyncStream<CameraEvent> { get }

    // MARK: - Session configuration

    /// Requests camera + microphone authorization.
    ///
    /// - Throws: `CameraError.permissionDenied` when either is denied.
    func requestAuthorization() async throws

    /// Builds the session for `preset`. Transitions `.configuring` while
    /// running and `.previewing` on success, `.error` on failure.
    func configure(preset: QualityPreset) async throws

    /// Reconfigures with a new preset while stopped (state `.idle`).
    func updatePreset(_ preset: QualityPreset) async throws

    // MARK: - Camera switching

    /// Switches between the back wide camera and the front TrueDepth camera
    /// with a live input swap (the session never stops, so the render
    /// pipeline and any active recording keep running). Allowed while
    /// previewing or recording.
    func switchCamera(to position: CameraPosition) async throws

    // MARK: - Cinematic Mode

    /// Requests Cinematic Mode (Portrait Effect depth blur). The app opts in
    /// via Info.plist (`NSCameraPortraitEffectEnabled`); the effect itself
    /// follows the system Control Center toggle
    /// (`AVCaptureDevice.isPortraitEffectEnabled` is read-only — it cannot be
    /// switched programmatically). This method guarantees the capture side:
    /// when enabling and the active format lacks `isPortraitEffectSupported`
    /// (e.g. 4K or 60 fps), the engine live-switches to a depth-capable format
    /// (typically 1080p@30) and reports it via `.cinematicAdjusted`; disabling
    /// restores the selected `QualityPreset`. Applied state is reported through
    /// `events` (`.cinematicChanged` / `.cinematicAdjusted` / `.cinematicUnsupported`).
    func setCinematic(enabled: Bool) async

    /// Sets the 9:16 portrait target zoom scale (1.0x / 1.2x / 1.5x) — live
    /// preview and the recorded vertical asset. The 16:9 landscape pipeline is
    /// unaffected.
    func setVerticalZoom(_ scale: VerticalZoomScale)

    // MARK: - Preview lifecycle

    /// Starts the live preview pipeline. Requires a prior `configure`.
    func startPreview() async throws

    /// Stops the preview, returning to `.idle` unless recording.
    func stopPreview() async

    // MARK: - Recording lifecycle

    /// Begins a dual recording. Transitions `.recording` and emits
    /// `CameraEvent.recordingStarted`.
    func startRecording() async throws

    /// Stops the recording: transitions `.processing`, finalizes both writers,
    /// returns the combined `DualRecordingResult`, and emits
    /// `CameraEvent.recordingFinished`.
    func stopRecording() async throws -> DualRecordingResult

    /// Aborts the recording, discarding partial output. Emits
    /// `CameraEvent.recordingCancelled`.
    func cancelRecording() async

    // MARK: - Frame pipeline

    /// Entry point from `AVCaptureVideoDataOutputSampleBufferDelegate`
    /// (called on its serial queue). Must return immediately; the engine
    /// enqueues the frame onto its render pipeline.
    func enqueueFrame(_ sampleBuffer: CMSampleBuffer)

    // MARK: - Teardown

    /// Tears down the session and pipelines.
    func shutdown() async
}
