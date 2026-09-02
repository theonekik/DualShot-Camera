//
//  CameraViewModel.swift
//  DualShot Camera
//
//  Main-actor observable facade over the camera engine and the global state
//  machine. This is the single object the UI layer observes.
//
//  Formerly CameraSessionModel.swift — renamed to CameraViewModel; a typealias
//  at the bottom keeps every existing CameraSessionModel reference compiling.
//

import Foundation
import Observation
import Photos

/// Main-actor observable facade over the camera engine + global state machine.
///
/// ## State notification
/// - `state` (via the `@Observable` macro) mirrors every accepted
///   `CameraStateMachine` transition, kept in sync by a task that consumes the
///   machine's `AsyncStream`.
/// - `events` (an `AsyncStream` of `CameraEvent`) delivers app-facing events:
///   recording lifecycle, preset changes, errors.
///
/// The engine (nonisolated, background) never touches this type; it drives the
/// machine and its own event stream, and this model observes both on the main
/// actor.
@MainActor
@Observable
public final class CameraViewModel {

    // MARK: - Observable state

    /// Current pipeline state (mirrors `stateMachine.state`).
    public private(set) var state: CameraState = .idle
    /// Currently applied preset.
    public private(set) var preset: QualityPreset = .p1080_30
    /// Most recent error surfaced by the pipeline.
    public private(set) var lastError: CameraError?
    /// Most recent completed dual recording.
    public private(set) var latestRecording: DualRecordingResult?
    /// Latest dual preview pair (persistent pipeline-owned buffers — safe for
    /// the Metal views to re-sample on every draw).
    public private(set) var preview: DualPreviewFrame?
    /// Measured camera frame rate (updated once per second).
    public private(set) var fps: Int = 0

    // MARK: - Camera & Cinematic Mode

    /// Currently active physical camera.
    public private(set) var cameraPosition: CameraPosition = .back
    /// Whether Cinematic Mode (depth blur) is requested.
    public private(set) var isCinematicEnabled = false
    /// Whether the depth blur is actually rendering.
    public private(set) var isCinematicActive = false
    /// Current 9:16 portrait pipeline zoom scale (1.0x / 1.2x / 1.5x).
    public private(set) var verticalZoomScale: VerticalZoomScale = .oneX
    /// Non-blocking notice (e.g. Cinematic Mode unsupported); shown as a banner.
    public private(set) var warningMessage: String?
    /// Transient glassmorphic toast (e.g. "auto-adjusted to 1080p" for Cinematic
    /// Mode); auto-dismisses after a few seconds.
    public private(set) var toastMessage: String?

    /// True when the front camera is active (drives preview mirroring).
    public var isFrontCamera: Bool {
        cameraPosition == .front
    }

    // MARK: - Independent stream toggles

    /// Whether the 16:9 landscape stream is recorded (default true).
    /// When off, the landscape writer is bypassed entirely — the next
    /// recording initializes no landscape file and writes no landscape bytes.
    public private(set) var isLandscapeActive = true

    /// Whether the 9:16 portrait stream is recorded (default true).
    /// When off, the portrait writer is bypassed entirely — the next
    /// recording initializes no portrait file and writes no portrait bytes.
    public private(set) var isPortraitActive = true

    /// Current stream selection pushed down to the engine/writer.
    public var activeStreams: DualStreamSelection {
        DualStreamSelection(landscapeActive: isLandscapeActive, portraitActive: isPortraitActive)
    }

    // MARK: - Recording HUD

    /// Elapsed recording time (updated by the HUD ticker).
    public private(set) var elapsedTime: TimeInterval = 0
    /// Current size of the 16:9 file in MB.
    public private(set) var landscapeFileSizeMB: Double = 0
    /// Current size of the 9:16 file in MB.
    public private(set) var portraitFileSizeMB: Double = 0

    /// True while the session is previewing or recording (drives preview liveness).
    public var isLive: Bool {
        state.phase == .previewing || state.phase == .recording
    }

    public var isRecording: Bool {
        state.phase == .recording
    }

    // MARK: - Dependencies

    /// The global state machine this model mirrors.
    public let stateMachine: CameraStateMachine
    private let engine: any CameraEngineProtocol

    // MARK: - Event bus

    private let (eventStream, eventContinuation) = AsyncStream<CameraEvent>.makeStream(
        bufferingPolicy: .unbounded
    )
    /// App-facing event bus. Iterate on the main actor.
    public var events: any AsyncSequence<CameraEvent, Never> { eventStream }

    private var stateObservationTask: Task<Void, Never>?
    private var engineEventTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var hudTickerTask: Task<Void, Never>?
    private var toastDismissTask: Task<Void, Never>?
    private var activeRecording: DualRecordingSession?
    private var frameCount = 0
    private var fpsWindowStart = Date()

    // MARK: - Lifecycle

    /// - Parameters:
    ///   - engine: The engine implementation that drives the pipeline.
    ///   - stateMachine: Defaults to the app-wide `CameraStateMachine.shared`.
    public init(engine: any CameraEngineProtocol, stateMachine: CameraStateMachine = .shared) {
        self.engine = engine
        self.stateMachine = stateMachine
        self.state = stateMachine.state
        self.preset = engine.currentPreset

        stateObservationTask = Task { @MainActor [weak self, machine = stateMachine] in
            for await newState in machine.states {
                guard let self else { return }
                self.state = newState
                if case .error = newState.phase {
                    self.lastError = newState.associatedError
                }
            }
        }
        engineEventTask = Task { @MainActor [weak self, engineEvents = engine.events] in
            for await event in engineEvents {
                guard let self else { return }
                self.handle(event)
            }
        }
        previewTask = Task { @MainActor [weak self, frames = engine.previewFrames] in
            for await frame in frames {
                guard let self else { return }
                self.preview = frame
                self.frameCount += 1
                let now = Date()
                if now.timeIntervalSince(self.fpsWindowStart) >= 1.0 {
                    self.fps = self.frameCount
                    self.frameCount = 0
                    self.fpsWindowStart = now
                }
            }
        }
    }

    /// Runs on the main actor so it can cancel the observation tasks.
    isolated deinit {
        stateObservationTask?.cancel()
        engineEventTask?.cancel()
        previewTask?.cancel()
        hudTickerTask?.cancel()
        toastDismissTask?.cancel()
        eventContinuation.finish()
    }

    private func handle(_ event: CameraEvent) {
        switch event {
        case .presetApplied(let newPreset):
            preset = newPreset
        case .recordingStarted(let session):
            activeRecording = session
            elapsedTime = 0
            startHUDTicker()
        case .recordingFinished(let result):
            latestRecording = result
            // Capture the toggles at the moment the recording finished — they
            // determine which of the two files actually exist and must be
            // imported (inactive streams produced no file).
            let landscapeActive = isLandscapeActive
            let portraitActive = isPortraitActive
            stopHUDTicker()
            activeRecording = nil
            Task { [weak self] in
                await Self.saveToPhotoLibrary(
                    result,
                    landscapeActive: landscapeActive,
                    portraitActive: portraitActive
                )
                // The finished files are now imported (or discarded): purge
                // them immediately so temp recordings never accumulate.
                self?.cleanupTemporaryFiles(targets: [result.session.landscapeURL, result.session.portraitURL])
            }
        case .recordingCancelled:
            stopHUDTicker()
            activeRecording = nil
            // The writer already removed its partial files; the sweep below is
            // a safety net (it only runs while the pipeline is idle).
            cleanupTemporaryFiles()
        case .errorOccurred(let error):
            lastError = error
        case .cameraSwitched(let position):
            cameraPosition = position
        case .cinematicChanged(let active):
            isCinematicActive = active
            if active { warningMessage = nil }
        case .cinematicAdjusted(let message):
            // Cinematic activated on an auto-adjusted format — show the toast.
            showToast(message)
        case .cinematicPending(let message):
            // Portrait Effect is off in Control Center — the request stays
            // armed and the engine activates it automatically once enabled.
            warningMessage = message
        case .cinematicUnsupported(let message):
            warningMessage = message
            isCinematicActive = false
            isCinematicEnabled = false
        }
        eventContinuation.yield(event)
    }

    // MARK: - Recording HUD ticker

    private func startHUDTicker() {
        hudTickerTask?.cancel()
        hudTickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.refreshHUDStats()
            }
        }
    }

    private func stopHUDTicker() {
        hudTickerTask?.cancel()
        hudTickerTask = nil
    }

    private func refreshHUDStats() {
        guard let session = activeRecording else { return }
        elapsedTime = Date().timeIntervalSince(session.startedAt)
        landscapeFileSizeMB = Self.megabytes(at: session.landscapeURL)
        portraitFileSizeMB = Self.megabytes(at: session.portraitURL)
    }

    private static func megabytes(at url: URL) -> Double {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else { return 0 }
        return Double(size) / 1_000_000
    }

    // MARK: - Photos handoff

    /// Saves the finished recordings into the Photos library so the user can
    /// see them. Only streams that were actually recorded are imported — an
    /// inactive stream never produced a file, so it is skipped. Runs off the
    /// main actor; failures are logged, never thrown.
    private static func saveToPhotoLibrary(
        _ result: DualRecordingResult,
        landscapeActive: Bool,
        portraitActive: Bool
    ) async {
        var urls: [URL] = []
        if landscapeActive { urls.append(result.session.landscapeURL) }
        if portraitActive { urls.append(result.session.portraitURL) }
        urls = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            print("[DualShot] no recorded files to import")
            return
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            print("[DualShot] Photos save skipped (authorization \(status.rawValue))")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for url in urls {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            }
            print("[DualShot] saved \(urls.count) recording(s) to Photos: \(urls.map(\.lastPathComponent))")
        } catch {
            print("[DualShot] Photos save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Storage optimization (temp recording footprint)

    /// Purges processed and orphaned recording files.
    ///
    /// Two passes:
    /// 1. **Targeted** — targets are removed immediately. These are the exact
    ///    files of a recording that was just imported to Photos (or discarded),
    ///    so the temp footprint is freed the moment saving completes.
    /// 2. **Sweep** — every .mov/.mp4 under the app's DualShot scratch
    ///    directory and Documents/ is removed, plus emptied scratch folders.
    ///    The sweep is safe ONLY while no writer session can be armed (a
    ///    pre-warmed writer's live output file must never be purged), so it
    ///    runs while the pipeline is .idle — i.e. at app startup and after a
    ///    full shutdown — never during preview or recording.
    public func cleanupTemporaryFiles(targets: [URL] = []) {
        let fm = FileManager.default
        for url in targets where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
            print("[DualShot] purged \(url.lastPathComponent)")
        }

        // Full sweep: only while idle, when no writer session can be armed.
        guard state.phase == .idle else { return }
        var purged = 0
        let scratch = fm.temporaryDirectory.appendingPathComponent("DualShot", isDirectory: true)
        purged += Self.purgeMediaFiles(in: scratch)
        if let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            purged += Self.purgeMediaFiles(in: documents)
        }
        if purged > 0 {
            print("[DualShot] storage cleanup: purged \(purged) recording file(s)")
        }
    }

    /// Recursively removes .mov/.mp4 files under root and prunes directories
    /// that became empty. Only media files are ever touched, so unrelated user
    /// content is never at risk. Returns the number of files removed.
    private static func purgeMediaFiles(in root: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var removed = 0
        var directories: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { continue }
            if values.isDirectory == true {
                directories.append(url)
            } else if ["mov", "mp4"].contains(url.pathExtension.lowercased()) {
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        // Prune emptied scratch folders bottom-up, only when actually empty.
        for dir in directories.reversed() {
            let isEmpty = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).isEmpty) == true
            if isEmpty { try? fm.removeItem(at: dir) }
        }
        return removed
    }

    // MARK: - Stream toggles

    /// Turns the 16:9 landscape stream on/off for future recordings.
    ///
    /// Business rule: at least one stream must remain active — turning off the
    /// last active stream is rejected (with a toast) instead of silently
    /// producing an empty recording.
    public func setLandscapeActive(_ active: Bool) {
        guard !isRecording else { return }
        guard active || isPortraitActive else {
            showToast("Keep at least one stream active")
            return
        }
        guard isLandscapeActive != active else { return }
        isLandscapeActive = active
        applyActiveStreams()
    }

    /// Turns the 9:16 portrait stream on/off for future recordings.
    ///
    /// Business rule: at least one stream must remain active — turning off the
    /// last active stream is rejected (with a toast) instead of silently
    /// producing an empty recording.
    public func setPortraitActive(_ active: Bool) {
        guard !isRecording else { return }
        guard active || isLandscapeActive else {
            showToast("Keep at least one stream active")
            return
        }
        guard isPortraitActive != active else { return }
        isPortraitActive = active
        applyActiveStreams()
    }

    /// Pushes the current selection to the engine, which forwards it to the
    /// dual writer and re-arms any pre-warmed session so the next recording
    /// matches the toggles exactly.
    private func applyActiveStreams() {
        Task { await engine.setActiveStreams(activeStreams) }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        toastDismissTask?.cancel()
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    // MARK: - Passthrough actions (UI → engine)

    /// One-shot startup: request permissions, then configure + start preview.
    public func start() async throws {
        // Runs before any writer session exists (state is .idle), so the full
        // sweep is safe: it reclaims the temp footprint left by earlier runs.
        cleanupTemporaryFiles()
        try await requestAuthorization()
        try await configure(preset: preset)
    }

    /// Selects a new preset, gracefully stopping the preview first so the
    /// session can be reconfigured (format changes require a stopped session).
    public func selectPreset(_ newPreset: QualityPreset) async throws {
        guard newPreset != preset else { return }
        switch state.phase {
        case .previewing:
            await stopPreview()
            try await updatePreset(newPreset)
            try await startPreview()
        case .idle:
            try await updatePreset(newPreset)
        default:
            throw CameraError.invalidStateTransition(from: state.phase, to: .configuring)
        }
    }

    public func toggleRecording() async {
        if isRecording {
            _ = try? await stopRecording()
        } else {
            try? await startRecording()
        }
    }

    // MARK: - Camera & Cinematic actions

    /// Switches between the front and back cameras (live input swap).
    public func flipCamera() async {
        guard isLive else { return }
        let target: CameraPosition = cameraPosition == .back ? .front : .back
        do {
            try await engine.switchCamera(to: target)
            warningMessage = nil
        } catch {
            warningMessage = "Camera switch failed: \(Self.describe(error))"
        }
    }

    private static func describe(_ error: Error) -> String {
        if let cameraError = error as? CameraError {
            return "\(cameraError)"
        }
        return error.localizedDescription
    }

    /// Toggles Cinematic Mode (depth blur).
    public func toggleCinematic() async {
        await setCinematic(enabled: !isCinematicEnabled)
    }

    public func setCinematic(enabled: Bool) async {
        warningMessage = nil
        isCinematicEnabled = enabled
        await engine.setCinematic(enabled: enabled)
    }

    /// Cycles the 9:16 portrait zoom: 1.0x → 1.2x → 1.5x → 1.0x. Applies live
    /// to the preview and the recorded vertical asset; landscape is unaffected.
    public func cycleVerticalZoom() {
        verticalZoomScale = verticalZoomScale.next
        engine.setVerticalZoom(verticalZoomScale)
    }

    /// Dismisses the current warning banner.
    public func dismissWarning() {
        warningMessage = nil
    }

    public func shutdown() async {
        await engine.shutdown()
        // The engine forced the machine to .idle, so the full sweep is safe.
        cleanupTemporaryFiles()
    }

    /// Records an error surfaced by the UI layer (e.g. a failed startup).
    public func reportError(_ error: Error) {
        lastError = error as? CameraError ?? .unknown(reason: error.localizedDescription)
    }

    public func requestAuthorization() async throws {
        try await engine.requestAuthorization()
    }

    public func configure(preset: QualityPreset) async throws {
        try await engine.configure(preset: preset)
    }

    public func updatePreset(_ preset: QualityPreset) async throws {
        try await engine.updatePreset(preset)
    }

    public func startPreview() async throws {
        try await engine.startPreview()
    }

    public func stopPreview() async {
        await engine.stopPreview()
    }

    public func startRecording() async throws {
        try await engine.startRecording()
    }

    @discardableResult
    public func stopRecording() async throws -> DualRecordingResult {
        try await engine.stopRecording()
    }

    public func cancelRecording() async {
        await engine.cancelRecording()
    }
}

// MARK: - Backward compatibility

/// The app's entry point and every SwiftUI view reference CameraSessionModel
/// via @Environment(CameraSessionModel.self). This typealias keeps those call
/// sites compiling unchanged after the facade was renamed to CameraViewModel.
public typealias CameraSessionModel = CameraViewModel
