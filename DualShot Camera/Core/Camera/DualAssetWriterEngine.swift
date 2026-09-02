//
//  DualAssetWriterEngine.swift
//  DualShot Camera
//
//  Concrete DualAssetWriterProtocol implementation: up to two AVAssetWriters
//  running in parallel — landscape 16:9 and portrait 9:16 — fed from the dual
//  render pipeline with PTS-rebased, frame-synchronized video and shared audio.
//
//  Independent stream bypass: every recording session writes ONLY the streams
//  selected via setActiveStreams(_:). An inactive stream gets NO AVAssetWriter,
//  NO output file, and NO appended frames — its URL on DualRecordingSession
//  simply never exists on disk (file size 0), so no bytes are ever written for
//  it and no cleanup is needed for a stream the user turned off.
//

import AVFoundation
import CoreMedia
import Foundation
import os

/// Which of the two output streams the next recording writes.
///
/// The dual writer creates a writer, its output FILE, and its encoder inputs
/// ONLY for active streams. An inactive stream is bypassed end-to-end: no file
/// is initialized, no frames are appended, and no bytes land on disk.
public nonisolated struct DualStreamSelection: Sendable, Equatable, CustomStringConvertible {
    /// Whether the 16:9 landscape stream is written.
    public var landscapeActive: Bool
    /// Whether the 9:16 portrait stream is written.
    public var portraitActive: Bool

    public init(landscapeActive: Bool, portraitActive: Bool) {
        self.landscapeActive = landscapeActive
        self.portraitActive = portraitActive
    }

    /// Both streams write (default).
    public static let both = DualStreamSelection(landscapeActive: true, portraitActive: true)

    /// Number of active streams. The app enforces that this is never 0.
    public var activeCount: Int {
        (landscapeActive ? 1 : 0) + (portraitActive ? 1 : 0)
    }

    public var description: String {
        "DualStreamSelection(landscape: \(landscapeActive ? "on" : "off"), portrait: \(portraitActive ? "on" : "off"))"
    }
}

/// Encodes and writes up to TWO independent .mov files (HEVC) simultaneously.
///
/// ## Timeline alignment
/// All writers start their sessions at .zero. The first video frame's
/// presentation timestamp is captured as the rebase offset; every video
/// append is rebased by that offset and every audio sample is rebased the same
/// way (samples before the first video frame are dropped). Because all writers
/// apply the identical rebasing and consume the identical buffers and audio
/// samples, the active files stay frame-synchronized.
///
/// ## Threading & memory
/// nonisolated on purpose: media buffers are non-Sendable, so instead of an
/// actor boundary every method funnels onto a single serial writeQueue
/// (confinement, not isolation). Video appends arrive from the engine's serial
/// render queue, audio appends from the audio queue; the write queue
/// serializes them. Appends are non-blocking (expectsMediaDataInRealTime):
/// when the hardware encoder is behind, isReadyForMoreMediaData turns false
/// and the frame is dropped rather than buffered — the pipeline's bounded
/// pools then bound the working set.
///
/// ## Stream bypass
/// setActiveStreams(_:) selects the output streams for the next session
/// (captured at session start). Inactive streams are never touched: no writer
/// is created, no file is initialized, no frames or audio are appended, and
/// finishWriting reports 0 bytes for them.
public nonisolated final class DualAssetWriterEngine: DualAssetWriterProtocol, @unchecked Sendable {

    public static let logger = Logger(subsystem: "com.dualshot.camera", category: "DualAssetWriterEngine")

    // MARK: - State (confined to writeQueue)

    private let writeQueue = DispatchQueue(label: "com.dualshot.write", qos: .userInitiated)

    private var landscapeWriter: AVAssetWriter?
    private var portraitWriter: AVAssetWriter?
    private var landscapeVideoInput: AVAssetWriterInput?
    private var portraitVideoInput: AVAssetWriterInput?
    private var landscapeAudioInput: AVAssetWriterInput?
    private var portraitAudioInput: AVAssetWriterInput?
    private var landscapeAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var portraitAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    /// Which output streams the NEXT startSession writes. Captured when the
    /// session opens; persists across sessions (it is a user preference, not
    /// per-session state, so it survives reset()).
    private var activeStreamSelection = DualStreamSelection.both

    private var activeSession: DualRecordingSession?
    private var sessionStartDate: Date?
    private var isFinishing = false
    private var firstVideoPTS = CMTime.invalid
    private var lastVideoTime = CMTime.zero
    private var droppedLandscapeFrames = 0
    private var droppedPortraitFrames = 0

    public init() {}

    public var isActive: Bool {
        get async {
            (try? await runOnQueue { [self] in
                self.activeSession != nil
            }) ?? false
        }
    }

    // MARK: - DualAssetWriterProtocol

    /// Applies the stream selection for the NEXT recording. Has no effect on
    /// an already-open session (selection is captured at session start).
    public func setActiveStreams(_ selection: DualStreamSelection) async {
        _ = try? await runOnQueue { [self] in
            guard self.activeStreamSelection != selection else { return }
            self.activeStreamSelection = selection
            Self.logger.info("active streams updated: \(selection)")
        }
    }

    public func startSession(
        preset: QualityPreset,
        directory: URL,
        fileType: AVFileType,
        targets: DualRenderTargets,
        includeAudio: Bool
    ) async throws -> DualRecordingSession {
        try await runOnQueue { [self] in
            try self.startSessionOnQueue(
                preset: preset,
                directory: directory,
                fileType: fileType,
                targets: targets,
                includeAudio: includeAudio
            )
        }
    }

    public func append(_ output: DualRenderOutput) async throws {
        // Media buffers are non-Sendable; they cross the serial write queue in
        // a box that asserts the confinement contract (single producer queue,
        // serial consumer queue — never concurrent access).
        let box = SendableBox(output)
        try await runOnQueue { [self, box] in
            try self.appendOnQueue(box.value)
        }
    }

    public func appendAudio(_ sampleBuffer: CMSampleBuffer) async throws {
        let box = SendableBox(sampleBuffer)
        try await runOnQueue { [self, box] in
            self.appendAudioOnQueue(box.value)
        }
    }

    public func finishWriting() async throws -> DualRecordingResult {
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async { [self] in
                do {
                    continuation.resume(returning: try self.finishOnQueue())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func cancelWriting() async {
        try? await runOnQueue { [self] in
            self.cancelOnQueue()
        }
    }

    // MARK: - Queue-confined implementations

    private func startSessionOnQueue(
        preset: QualityPreset,
        directory: URL,
        fileType: AVFileType,
        targets: DualRenderTargets,
        includeAudio: Bool
    ) throws -> DualRecordingSession {
        guard activeSession == nil else {
            throw CameraError.writerFailed(reason: "a recording session is already active")
        }
        let selection = activeStreamSelection
        guard selection.activeCount > 0 else {
            throw CameraError.writerFailed(reason: "at least one output stream must be active")
        }
        guard targets.landscapeSize.width > 0, targets.portraitSize.width > 0 else {
            throw CameraError.writerFailed(reason: "invalid render targets: \(targets)")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = Self.fileExtension(for: fileType)
        let landscapeURL = directory.appendingPathComponent("landscape_output").appendingPathExtension(ext)
        let portraitURL = directory.appendingPathComponent("portrait_output").appendingPathExtension(ext)

        let audioSettings = Self.audioSettings()

        // Stream bypass: build a writer (and its output FILE + encoder inputs)
        // ONLY for active streams. An inactive stream is never touched — no
        // file is initialized on disk and no bytes are ever written for it.
        var createdWriters: [AVAssetWriter] = []
        var landscapeWriter: AVAssetWriter?
        var landscapeVideoInput: AVAssetWriterInput?
        var landscapeAudioInput: AVAssetWriterInput?
        var landscapeAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        if selection.landscapeActive {
            let (writer, video, audio, adaptor) = try makeWriter(
                url: landscapeURL,
                fileType: fileType,
                videoSettings: Self.videoSettings(preset: preset, size: targets.landscapeSize),
                audioSettings: audioSettings,
                includeAudio: includeAudio,
                targetSize: targets.landscapeSize
            )
            landscapeWriter = writer
            landscapeVideoInput = video
            landscapeAudioInput = audio
            landscapeAdaptor = adaptor
            createdWriters.append(writer)
        }
        var portraitWriter: AVAssetWriter?
        var portraitVideoInput: AVAssetWriterInput?
        var portraitAudioInput: AVAssetWriterInput?
        var portraitAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        if selection.portraitActive {
            let (writer, video, audio, adaptor) = try makeWriter(
                url: portraitURL,
                fileType: fileType,
                videoSettings: Self.videoSettings(preset: preset, size: targets.portraitSize),
                audioSettings: audioSettings,
                includeAudio: includeAudio,
                targetSize: targets.portraitSize
            )
            portraitWriter = writer
            portraitVideoInput = video
            portraitAudioInput = audio
            portraitAdaptor = adaptor
            createdWriters.append(writer)
        }

        let startedAt = Date()
        // Start all active hardware encoders CONCURRENTLY: the writers are
        // independent, and a sequential cold start of two HEVC sessions is
        // what took ~8 s on the first pre-warm (each encoder's format/encoder
        // negotiation blocks). Parallelizing roughly halves it; once warm,
        // subsequent starts are milliseconds either way.
        let startGroup = DispatchGroup()
        let startQueue = DispatchQueue(label: "com.dualshot.writer-start", attributes: .concurrent)
        for writer in createdWriters {
            startGroup.enter()
            let box = SendableBox(writer)
            startQueue.async {
                box.value.startWriting()
                box.value.startSession(atSourceTime: .zero)
                startGroup.leave()
            }
        }
        startGroup.wait()
        Self.logger.info("writers started in \(Date().timeIntervalSince(startedAt) * 1000, format: .fixed(precision: 1)) ms (\(createdWriters.count) stream(s), \(selection))")

        // A writer that failed to start (e.g. the hardware encoder was still
        // releasing from the previous recording) would silently eat every
        // append — detect it now so the caller (pre-warm or record tap) knows.
        guard createdWriters.allSatisfy({ $0.status == .writing }) else {
            let reason = createdWriters.compactMap(\.error).map(\.localizedDescription).first
                ?? "writer failed to start (statuses \(createdWriters.map(\.status.rawValue)))"
            for writer in createdWriters { writer.cancelWriting() }
            throw CameraError.writerFailed(reason: reason)
        }

        self.landscapeWriter = landscapeWriter
        self.portraitWriter = portraitWriter
        self.landscapeVideoInput = landscapeVideoInput
        self.portraitVideoInput = portraitVideoInput
        self.landscapeAudioInput = landscapeAudioInput
        self.portraitAudioInput = portraitAudioInput
        self.landscapeAdaptor = landscapeAdaptor
        self.portraitAdaptor = portraitAdaptor

        let session = DualRecordingSession(
            preset: preset,
            landscapeURL: landscapeURL,
            portraitURL: portraitURL,
            fileType: fileType,
            startedAt: .now
        )
        activeSession = session
        sessionStartDate = session.startedAt
        isFinishing = false
        firstVideoPTS = .invalid
        lastVideoTime = .zero
        droppedLandscapeFrames = 0
        droppedPortraitFrames = 0

        Self.logger.info("dual recording session started: \(session) (\(selection))")
        return session
    }

    private func appendOnQueue(_ output: DualRenderOutput) throws {
        guard activeSession != nil, !isFinishing,
              landscapeWriter?.status == .writing || portraitWriter?.status == .writing else {
            let status = landscapeWriter?.status.rawValue ?? portraitWriter?.status.rawValue ?? -1
            Self.logger.error("video append rejected (writer status \(status))")
            throw CameraError.writerFailed(reason: "no active recording session (writer status \(status))")
        }

        if !firstVideoPTS.isValid {
            firstVideoPTS = output.presentationTime
        }
        var time = CMTimeSubtract(output.presentationTime, firstVideoPTS)
        // Reject pre-roll frames before the anchor.
        guard CMTimeCompare(time, .zero) >= 0 else { return }
        // The capture clock can reset after a reconfiguration (e.g. a camera
        // switch or color-space change), making rebased times non-monotonic —
        // AVAssetWriter would reject the whole recording. Re-anchor instead.
        if CMTimeCompare(time, lastVideoTime) < 0 {
            Self.logger.warning("capture clock reset detected — re-anchoring recording timeline")
            firstVideoPTS = output.presentationTime
            time = .zero
        }

        // Per-stream bypass: an inactive stream has NO input/adaptor/writer at
        // all (nothing was created at session start), so the nil checks below
        // skip it entirely — no encoder call, no append, no file bytes.
        if let landscapeInput = landscapeVideoInput {
            appendVideoFrame(
                to: landscapeInput,
                adaptor: landscapeAdaptor,
                writer: landscapeWriter,
                buffer: output.landscapeBuffer,
                time: time,
                dropped: &droppedLandscapeFrames
            )
        }
        if let portraitInput = portraitVideoInput {
            appendVideoFrame(
                to: portraitInput,
                adaptor: portraitAdaptor,
                writer: portraitWriter,
                buffer: output.portraitBuffer,
                time: time,
                dropped: &droppedPortraitFrames
            )
        }
        lastVideoTime = time
    }

    /// Appends one frame to a single writer, with the shared real-time
    /// backpressure policy: a brief grace window after the session starts (the
    /// HEVC encoder's first-GOP init can lag readiness for a moment), then
    /// drop frames while the encoder is behind instead of letting the queue
    /// grow.
    private func appendVideoFrame(
        to input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor?,
        writer: AVAssetWriter?,
        buffer: CVPixelBuffer,
        time: CMTime,
        dropped: inout Int
    ) {
        if !input.isReadyForMoreMediaData {
            // Grace period: the HEVC encoder's first-GOP init can lag
            // readiness for a moment after the recording starts; retry briefly
            // so the opening frames aren't dropped (which showed as a 1–2 s
            // "stuck" at the start of the first recording). After the grace,
            // drops resume for genuine backpressure.
            if Date() < (sessionStartDate ?? .now).addingTimeInterval(1.5) {
                var becameReady = false
                for _ in 0..<300 {
                    Thread.sleep(forTimeInterval: 0.005)
                    if input.isReadyForMoreMediaData {
                        becameReady = true
                        break
                    }
                }
                guard becameReady else { return }
            } else {
                dropped += 1
                // Snapshot before logging: Logger's message is an escaping
                // autoclosure and must not capture the inout parameter.
                let droppedCount = dropped
                if droppedCount == 1 || droppedCount.isMultiple(of: 60) {
                    Self.logger.warning("video encoder behind — dropped \(droppedCount) frames")
                }
                return
            }
        }
        guard let adaptor else { return }
        if !adaptor.append(buffer, withPresentationTime: time) {
            dropped += 1
            if let error = writer?.error {
                Self.logger.error("pixel buffer append failed: \(error.localizedDescription)")
            }
        }
    }

    private func appendAudioOnQueue(_ sampleBuffer: CMSampleBuffer) {
        guard activeSession != nil, !isFinishing, firstVideoPTS.isValid else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let time = CMTimeSubtract(pts, firstVideoPTS)
        // Drop pre-roll audio that precedes the first video frame so all
        // writers' timelines start identically.
        guard CMTimeCompare(time, .zero) >= 0 else { return }

        guard let rebased = sampleBuffer.rebased(to: time) else { return }
        // Append only to streams that exist — inactive streams have no audio
        // input, so their (non-existent) files never receive audio either.
        if let landscapeAudio = landscapeAudioInput, landscapeAudio.isReadyForMoreMediaData {
            _ = landscapeAudio.append(rebased)
        }
        if let portraitAudio = portraitAudioInput, portraitAudio.isReadyForMoreMediaData {
            _ = portraitAudio.append(rebased)
        }
    }

    private func finishOnQueue() throws -> DualRecordingResult {
        guard let session = activeSession else {
            throw CameraError.writerFailed(reason: "no active recording session")
        }
        isFinishing = true

        // A recording with zero appended video frames (e.g. stopped in the
        // instant after a camera switch) would silently finalize empty files —
        // detect and cancel it instead so the UI reports a real failure.
        guard firstVideoPTS.isValid else {
            landscapeWriter?.cancelWriting()
            portraitWriter?.cancelWriting()
            Self.removeFilesIfPresent([session.landscapeURL, session.portraitURL])
            reset()
            throw CameraError.writerFailed(reason: "recording stopped before any video frame was written")
        }

        // Finalize the ACTIVE writers and wait for all completion handlers,
        // with a hard timeout so the write queue can never wedge permanently.
        let finishers = [landscapeWriter, portraitWriter].compactMap { $0 }
        let group = DispatchGroup()
        for writer in finishers {
            group.enter()
            writer.finishWriting { group.leave() }
        }
        let waitResult = group.wait(timeout: .now() + 15)

        guard waitResult == .success else {
            // Finalization stalled (e.g. the GPU/encoder was saturated): cancel
            // all writers and remove the partial files instead of leaving
            // orphaned writers behind.
            for writer in finishers { writer.cancelWriting() }
            Self.removeFilesIfPresent([session.landscapeURL, session.portraitURL])
            reset()
            throw CameraError.writerFailed(reason: "timed out waiting for writers to finalize")
        }

        guard finishers.allSatisfy({ $0.status == .completed }) else {
            let reason = finishers.compactMap(\.error).map(\.localizedDescription).first
                ?? "unknown writer finalization error"
            for writer in finishers { writer.cancelWriting() }
            reset()
            throw CameraError.writerFailed(reason: reason)
        }

        let result = DualRecordingResult(
            session: session,
            duration: CMTimeGetSeconds(lastVideoTime),
            // Inactive streams never produced a file: fileSize returns 0.
            landscapeFileSizeBytes: Self.fileSize(at: session.landscapeURL),
            portraitFileSizeBytes: Self.fileSize(at: session.portraitURL)
        )
        reset()
        Self.logger.info("finished dual recording: \(result)")
        return result
    }

    private func cancelOnQueue() {
        guard activeSession != nil else { return }
        isFinishing = true
        landscapeWriter?.cancelWriting()
        portraitWriter?.cancelWriting()

        let urls = [activeSession?.landscapeURL, activeSession?.portraitURL].compactMap { $0 }
        reset()
        Self.removeFilesIfPresent(urls)
        Self.logger.info("cancelled dual recording; partial files removed")
    }

    // MARK: - Writer construction

    private func makeWriter(
        url: URL,
        fileType: AVFileType,
        videoSettings: [String: Any],
        audioSettings: [String: Any],
        includeAudio: Bool,
        targetSize: CGSize
    ) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInput?, AVAssetWriterInputPixelBufferAdaptor) {
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        // Explicit pixel-buffer attributes pre-configure the HEVC encoder at
        // startWriting, so the FIRST append doesn't block for 1–2 s while the
        // encoder negotiates its format from the first buffer (the opening
        // "stuck" of the first recording).
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: Int(targetSize.width),
                kCVPixelBufferHeightKey as String: Int(targetSize.height),
            ]
        )

        guard writer.canAdd(videoInput) else {
            throw CameraError.writerFailed(reason: "cannot add video input to \(url.lastPathComponent)")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if includeAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw CameraError.writerFailed(reason: "cannot add audio input to \(url.lastPathComponent)")
            }
            writer.add(input)
            audioInput = input
        }
        return (writer, videoInput, audioInput, adaptor)
    }

    // MARK: - Settings

    private static func videoSettings(preset: QualityPreset, size: CGSize) -> [String: Any] {
        [
            AVVideoCodecKey: preset.codec, // .hevc — hardware encoder on A18
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: preset.compressionProperties,
            AVVideoColorPropertiesKey: preset.colorProperties,
        ]
    }

    private static func audioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
    }

    private static func fileExtension(for type: AVFileType) -> String {
        switch type {
        case .mov: "mov"
        case .mp4: "mp4"
        default: "mov"
        }
    }

    // MARK: - Helpers

    private func reset() {
        activeSession = nil
        sessionStartDate = nil
        isFinishing = false
        firstVideoPTS = .invalid
        lastVideoTime = .zero
        droppedLandscapeFrames = 0
        droppedPortraitFrames = 0
        landscapeWriter = nil
        portraitWriter = nil
        landscapeVideoInput = nil
        portraitVideoInput = nil
        landscapeAudioInput = nil
        portraitAudioInput = nil
        landscapeAdaptor = nil
        portraitAdaptor = nil
        // NOTE: activeStreamSelection intentionally survives reset() — it is a
        // user preference, not per-session state.
    }

    /// Removes files that exist (no-ops for streams that were never written).
    private static func removeFilesIfPresent(_ urls: [URL]) {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Serializes a synchronous, queue-confined operation.
    private func runOnQueue<T: Sendable>(_ op: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async {
                do {
                    continuation.resume(returning: try op())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - PTS rebasing

/// Documents the deliberate crossing of a non-Sendable media value onto the
/// writer's serial queue: the value is produced on a single serial context and
/// consumed serially on the write queue, so it is never accessed concurrently.
/// (Standard pattern for CF media types, which are immutable + refcounted.)
private nonisolated struct SendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private nonisolated extension CMSampleBuffer {
    /// Returns a copy of the receiver with a new presentation timestamp
    /// (decode timestamp cleared so it tracks presentation, as for AAC).
    func rebased(to presentationTime: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(self),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var output: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: self,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &output
        )
        return output
    }
}