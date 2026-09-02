//
//  DualAssetWriterProtocol.swift
//  DualShot Camera
//
//  The dual-writer contract: simultaneously encode and write TWO independent
//  video files (16:9 and 9:16) from the dual render pipeline.
//

import AVFoundation
import Foundation

/// Encodes and writes two independent video files (16:9 and 9:16) from the
/// dual render pipeline, as concurrently as the hardware encoder allows.
///
/// ## Expected concrete implementation
/// Two `AVAssetWriter`s (one per output), each with an HEVC
/// `AVAssetWriterInput` plus `AVAssetWriterInputPixelBufferAdaptor`, fed from
/// the engine's serialized render pipeline. Both writers `start` together and
/// both `finish` together so the pair stays frame-synchronized. Audio samples
/// (if enabled) are appended to both inputs.
///
/// ## Threading
/// The writer is consumed from the engine's serial render context — the same
/// context that produces `DualRenderOutput`, so the non-Sendable pixel buffers
/// never cross a concurrency boundary. The implementation may additionally
/// serialize its own bookkeeping with a lock or actor.
public nonisolated protocol DualAssetWriterProtocol: Sendable {
    /// Whether a recording session is currently open.
    var isActive: Bool { get async }

    /// Selects which output streams the next startSession writes. A stream
    /// that is turned off gets NO writer, NO output file, and NO bytes — its
    /// URL in DualRecordingSession simply never exists on disk. Must be
    /// called before startSession; has no effect on an already-open session.
    func setActiveStreams(_ selection: DualStreamSelection) async

    /// Begins a session: creates the output files for the ACTIVE streams and
    /// starts their writers.
    ///
    /// - Parameters:
    ///   - preset: The active `QualityPreset` (bitrate, frame rate, codec).
    ///   - directory: Directory that will receive `landscape_output.<ext>`
    ///     and `portrait_output.<ext>`.
    ///   - fileType: Container format (`.mp4` or `.mov`).
    ///   - targets: Exact output geometry for both encoders (landscape 16:9,
    ///     portrait 9:16) — the buffers handed to `append(_:)` must match.
    ///   - includeAudio: Whether to add AAC audio tracks (`false` when the
    ///     microphone is unavailable or denied).
    func startSession(
        preset: QualityPreset,
        directory: URL,
        fileType: AVFileType,
        targets: DualRenderTargets,
        includeAudio: Bool
    ) async throws -> DualRecordingSession

    /// Appends one frame pair to both writers.
    ///
    /// `DualRenderOutput` is non-Sendable by design; the engine hands it to the
    /// writer only from its serial render context, and the writer serializes on
    /// its own write queue — no isolation boundary is crossed.
    ///
    /// - Throws: `CameraError.writerFailed` if no session is open or a writer
    ///   rejected the buffer (e.g. exhausted `isReadyForMoreMediaData`).
    func append(_ output: DualRenderOutput) async throws

    /// Appends a shared audio sample to both writers (when audio is enabled).
    func appendAudio(_ sampleBuffer: CMSampleBuffer) async throws

    /// Finishes both writers and returns the combined result.
    ///
    /// - Throws: `CameraError.writerFailed` if either finalize fails.
    func finishWriting() async throws -> DualRecordingResult

    /// Aborts both writers and discards the current session.
    func cancelWriting() async
}
