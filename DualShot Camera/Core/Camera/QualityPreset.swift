//
//  QualityPreset.swift
//  DualShot Camera
//
//  Capture + encode presets, tuned for the Apple A18 hardware HEVC encoder
//  (iPhone 16 family: A18 / A18 Pro). AVAssetWriter routes `.hevc` to the
//  dedicated hardware encoder block, so the presets below only need to
//  describe the bitrate envelope, GOP structure, and color pipeline.
//

import AVFoundation
import CoreGraphics
import Foundation
import VideoToolbox

/// Capture and encode preset for the dual pipeline.
public nonisolated enum QualityPreset: String, CaseIterable, Identifiable, Sendable, Equatable, CustomStringConvertible {
    /// 1920×1080 @ 30 fps.
    case p1080_30
    /// 1920×1080 @ 60 fps.
    case p1080_60
    /// 3840×2160 @ 30 fps.
    case p4k_30

    public var id: String { rawValue }
    public var description: String { rawValue }

    // MARK: - Capture configuration

    /// Native landscape capture resolution (the source for both render targets).
    public var dimensions: CGSize {
        switch self {
        case .p1080_30, .p1080_60: CGSize(width: 1920, height: 1080)
        case .p4k_30: CGSize(width: 3840, height: 2160)
        }
    }

    /// Target frame rate for `AVCaptureDevice.activeVideoMinFrameDuration`.
    public var frameRate: Int {
        switch self {
        case .p1080_30: 30
        case .p1080_60: 60
        case .p4k_30: 30
        }
    }

    /// Matching `AVCaptureSession.Preset` for session configuration.
    public var captureSessionPreset: AVCaptureSession.Preset {
        switch self {
        case .p1080_30, .p1080_60: .hd1920x1080
        case .p4k_30: .hd4K3840x2160
        }
    }

    // MARK: - HEVC / A18 encoding tuning

    /// Hardware HEVC encoder.
    public var codec: AVVideoCodecType { .hevc }

    /// HEVC Main profile, auto level. (The AVFoundation convenience constants
    /// were removed from recent SDKs; VideoToolbox defines the canonical ones.)
    public var profileLevel: String {
        kVTProfileLevel_HEVC_Main_AutoLevel as String
    }

    /// Target average bitrate in bits/second.
    ///
    /// Values are calibrated for the A18 encoder at ~8-bit perceptual quality:
    /// 1080p30 ≈ 12 Mbps, 1080p60 ≈ 20 Mbps, 4K30 ≈ 42 Mbps. 60 fps gets a
    /// near-doubled budget (motion entropy scales with frame count); 4K gets a
    /// supersampled budget because the 9:16 portrait crop re-encodes from the
    /// same sensor frame.
    ///
    /// These are compact-but-clean values: 1080p30 ≈ 9 Mbps, 1080p60 ≈ 14 Mbps,
    /// 4K30 ≈ 32 Mbps. HEVC on A18 keeps these visually excellent while the
    /// file sizes stay modest (~1.1 / 1.75 / 4 MB per second per track).
    public var averageBitrate: Int {
        switch self {
        case .p1080_30: 9_000_000
        case .p1080_60: 14_000_000
        case .p4k_30: 32_000_000
        }
    }

    /// VBR envelope (±20% around `averageBitrate`) the encoder may roam in.
    public var bitrateRange: ClosedRange<Int> {
        switch self {
        case .p1080_30: 7_200_000...10_800_000
        case .p1080_60: 11_200_000...16_800_000
        case .p4k_30: 25_600_000...38_400_000
        }
    }

    /// HEVC-friendly GOP length: a keyframe every 2 seconds keeps seeking
    /// snappy without exploding the intra-frame bitrate.
    public var keyFrameInterval: CMTime {
        CMTime(seconds: 2, preferredTimescale: 600)
    }

    /// Expected source frame rate, reported to the encoder.
    public var expectedSourceFrameRate: Int { frameRate }

    /// Estimated output size per minute (MiB), for UI and storage planning.
    public var estimatedMiBPerMinute: Double {
        Double(averageBitrate) * 60.0 / 8.0 / 1_000_000.0
    }

    /// `AVVideoSettings` compression dictionary for `AVAssetWriterInput`.
    ///
    /// Computed (not stored) so the `Sendable` enum carries no non-Sendable
    /// `[String: Any]` storage.
    ///
    /// HEVC note: `AVVideoAverageBitRateKey` and
    /// `kVTCompressionPropertyKey_AverageBitRate` are the SAME key string
    /// ("AverageBitRate") — include it once. The hard cap comes from
    /// `kVTCompressionPropertyKey_DataRateLimits` (the encoder will not
    /// overshoot, which keeps the files compact).
    public var compressionProperties: [String: Any] {
        [
            AVVideoAverageBitRateKey: averageBitrate,
            kVTCompressionPropertyKey_DataRateLimits as String: [
                NSNumber(value: Double(averageBitrate) / 8.0), // bytes/sec hard cap
                NSNumber(value: 1.0),                         // 1-second window
            ],
            AVVideoProfileLevelKey: profileLevel,
            AVVideoMaxKeyFrameIntervalKey: Int(keyFrameInterval.seconds.rounded()),
            AVVideoExpectedSourceFrameRateKey: expectedSourceFrameRate,
            AVVideoAllowFrameReorderingKey: false, // low-latency capture path
        ]
    }

    /// Standard BT.709 color description for HEVC capture.
    public var colorProperties: [String: Any] {
        [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
    }
}
