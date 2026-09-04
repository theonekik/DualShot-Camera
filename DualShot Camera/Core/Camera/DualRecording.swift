//
//  DualRecording.swift
//  DualShot Camera
//
//  Value types describing an in-flight and a finished dual recording.
//

import AVFoundation
import Foundation

/// Describes an in-flight dual recording: two output files being written in
/// parallel by the dual asset writer.
public nonisolated struct DualRecordingSession: Sendable, Equatable, CustomStringConvertible {
    public let id: UUID
    public let preset: QualityPreset
    /// Destination for the 16:9 file (.mp4 / .mov).
    public let landscapeURL: URL
    /// Destination for the 9:16 file (.mp4 / .mov).
    public let portraitURL: URL
    public let fileType: AVFileType
    public let startedAt: Date

    public init(
        id: UUID = UUID(),
        preset: QualityPreset,
        landscapeURL: URL,
        portraitURL: URL,
        fileType: AVFileType = .mp4,
        startedAt: Date = .now
    ) {
        self.id = id
        self.preset = preset
        self.landscapeURL = landscapeURL
        self.portraitURL = portraitURL
        self.fileType = fileType
        self.startedAt = startedAt
    }

    public var description: String {
        "DualRecordingSession(id: \(id), preset: \(preset), landscape: \(landscapeURL.lastPathComponent), portrait: \(portraitURL.lastPathComponent), fileType: \(fileType.rawValue))"
    }
}

/// Result of a finished dual recording.
public nonisolated struct DualRecordingResult: Sendable, Equatable, CustomStringConvertible {
    public let session: DualRecordingSession
    /// Wall-clock recording duration.
    public let duration: TimeInterval
    public let landscapeFileSizeBytes: Int64
    public let portraitFileSizeBytes: Int64

    public init(
        session: DualRecordingSession,
        duration: TimeInterval,
        landscapeFileSizeBytes: Int64,
        portraitFileSizeBytes: Int64
    ) {
        self.session = session
        self.duration = duration
        self.landscapeFileSizeBytes = landscapeFileSizeBytes
        self.portraitFileSizeBytes = portraitFileSizeBytes
    }

    /// Total bytes written across both files.
    public var totalBytes: Int64 {
        landscapeFileSizeBytes + portraitFileSizeBytes
    }

    public var description: String {
        "DualRecordingResult(duration: \(duration)s, landscape: \(landscapeFileSizeBytes) B, portrait: \(portraitFileSizeBytes) B, total: \(totalBytes) B)"
    }
}
