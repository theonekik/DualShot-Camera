//
//  DualRenderOutput.swift
//  DualShot Camera
//
//  The unit of work flowing from the render pipeline to the dual writer:
//  one moment in time, cropped twice — once 16:9, once 9:16.
//

import AVFoundation
import CoreVideo
import Foundation

/// One processed frame pair: the same presentation time rendered into a
/// 16:9 landscape buffer and a 9:16 portrait buffer.
///
/// ## Concurrency contract
/// `CVPixelBuffer` is not `Sendable`, so a `DualRenderOutput` must never
/// cross an actor boundary. It is produced and consumed inside the engine's
/// single serialized render pipeline (a dedicated serial queue) and handed to
/// `DualAssetWriterProtocol.append` on that same serial context. `CVPixelBuffer`
/// is memory-managed by Swift, so no manual retain/release is required.
public nonisolated struct DualRenderOutput {

    /// Frame cropped to the 16:9 target.
    public let landscapeBuffer: CVPixelBuffer

    /// Frame cropped to the 9:16 target.
    public let portraitBuffer: CVPixelBuffer

    /// Presentation timestamp shared by both buffers.
    public let presentationTime: CMTime

    public init(
        landscapeBuffer: CVPixelBuffer,
        portraitBuffer: CVPixelBuffer,
        presentationTime: CMTime
    ) {
        self.landscapeBuffer = landscapeBuffer
        self.portraitBuffer = portraitBuffer
        self.presentationTime = presentationTime
    }
}

// MARK: - Render targets

public nonisolated extension DualRenderOutput {
    /// The two render targets the pipeline must produce.
    enum Target: Sendable, Hashable {
        case landscape16x9
        case portrait9x16

        public var pixelSize: CGSize {
            switch self {
            case .landscape16x9: CGSize(width: 1920, height: 1080)
            case .portrait9x16: CGSize(width: 1080, height: 1920)
            }
        }
    }
}

// MARK: - Output geometry

/// Exact output geometry of the dual render pipeline, shared by the pipeline
/// (which allocates the matching pools) and the dual writer (which configures
/// both encoders to these sizes).
public nonisolated struct DualRenderTargets: Sendable, Equatable {
    /// 16:9 landscape output size (pixels).
    public let landscapeSize: CGSize
    /// 9:16 portrait output size (pixels).
    public let portraitSize: CGSize

    public init(landscapeSize: CGSize, portraitSize: CGSize) {
        self.landscapeSize = landscapeSize
        self.portraitSize = portraitSize
    }

    /// Empty targets, used before the pipeline is configured.
    public static let zero = DualRenderTargets(landscapeSize: .zero, portraitSize: .zero)

    /// Computes the two targets for the (already upright) source frame size:
    /// - **landscape**: the largest centered 16:9 crop of the source, at native
    ///   resolution (zero-latency — no scaling);
    /// - **portrait**: the largest centered 9:16 crop of the source, native.
    /// Both sizes are even-rounded so 4:2:0 chroma stays sample-aligned. The
    /// geometry is aspect-based, so it is correct whether the delivered frames
    /// are sensor-landscape or upright (rotated by the capture connection).
    public static func computing(sourceSize: CGSize) -> DualRenderTargets {
        guard sourceSize.width >= 2, sourceSize.height >= 2 else { return .zero }
        let landscape = centeredCrop(aspect: 16.0 / 9.0, in: sourceSize)
        let portrait = centeredCrop(aspect: 9.0 / 16.0, in: sourceSize)
        return DualRenderTargets(landscapeSize: landscape.size, portraitSize: portrait.size)
    }

    /// Largest centered rect of `aspect` that fits `source`, rounded to even
    /// pixel coordinates/dimensions so 4:2:0 chroma planes stay aligned.
    /// (Centered → identical in CI's bottom-left coordinate space.)
    public static func centeredCrop(aspect: CGFloat, in source: CGSize) -> CGRect {
        let sourceAspect = source.width / source.height
        var width = source.width
        var height = source.height
        if sourceAspect > aspect {
            height = source.height
            width = source.height * aspect
        } else {
            width = source.width
            height = source.width / aspect
        }
        width = CGFloat(Int(width) & ~1)
        height = CGFloat(Int(height) & ~1)
        let x = CGFloat(Int((source.width - width) / 2) & ~1)
        let y = CGFloat(Int((source.height - height) / 2) & ~1)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Preview frames

/// A preview frame pair: the two **persistent, pipeline-owned** display buffers
/// holding the latest dual crops. Unlike `DualRenderOutput` (pool-backed, must
/// not be retained), these buffers are reused every frame and are safe to read
/// from any thread at any time — the UI's Metal views re-wrap and re-sample
/// them on every draw.
///
/// The type is `@unchecked Sendable` because it deliberately crosses from the
/// pipeline's serial render queue to the main actor: the buffers are immutable
/// IOSurface memory with a single writer, and concurrent reads are only ever
/// preview-quality (a rare mid-write read may tear for one frame).
public nonisolated struct DualPreviewFrame: @unchecked Sendable {
    /// Latest 16:9 landscape crop (display resolution).
    public let landscapeBuffer: CVPixelBuffer
    /// Latest 9:16 portrait crop (display resolution).
    public let portraitBuffer: CVPixelBuffer
    public let presentationTime: CMTime

    public init(landscapeBuffer: CVPixelBuffer, portraitBuffer: CVPixelBuffer, presentationTime: CMTime) {
        self.landscapeBuffer = landscapeBuffer
        self.portraitBuffer = portraitBuffer
        self.presentationTime = presentationTime
    }
}
