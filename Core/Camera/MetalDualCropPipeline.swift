//
//  MetalDualCropPipeline.swift
//  DualShot Camera
//
//  Dual-crop pipeline. Incoming 420f camera frames are wrapped zero-copy as
//  Core Image images and rendered — cropped twice (16:9 landscape + 9:16
//  portrait) — into pool-backed 420f buffers for recording and persistent
//  display-resolution buffers for the live preview.
//
//  Rendering is done by a Metal-backed CIContext: Core Image is the canonical,
//  battle-tested iOS mechanism for rendering camera frames into IOSurface
//  CVPixelBuffers — it owns the IOSurface write path, format conversion, and
//  synchronization, which eliminates the device-specific GPU write issues of a
//  hand-rolled compute path.
//

import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Metal
import os
import Synchronization

/// GPU dual-crop pipeline (Core Image + Metal).
///
/// ## Zero-copy
/// `CIImage(cvPixelBuffer:)` wraps the camera buffer without a pixel copy; CI
/// renders the crops directly into the IOSurface-backed output buffers on the
/// GPU via the Metal device.
///
/// ## Memory
/// Output buffers come from bounded `CVPixelBufferPool`s with an allocation
/// threshold — when a pool is exhausted the frame is dropped (real-time
/// backpressure) instead of growing memory. See `estimatedMemoryBytes()`.
///
/// ## Threading
/// All mutable state is confined to `processingQueue` (serial). The pipeline
/// is the `AVCaptureVideoDataOutputSampleBufferDelegate` and also accepts
/// manual `process(_:)` calls; both serialize on the same queue. `onRender`
/// and `onPreview` fire on `processingQueue` — set them once before use.
public nonisolated final class MetalDualCropPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    public static let logger = Logger(subsystem: "com.dualshot.camera", category: "MetalDualCropPipeline")

    /// How many output buffers each target pool may hold (allocation cap).
    /// Four gives the hardware encoder one-to-two in-flight buffers per track
    /// plus the current render, so 60 fps recording never starves the pool.
    public static let poolDepth = 4

    /// Display-resolution preview targets. Persistent (never pooled) so the UI
    /// can re-read the latest crops on every draw without holding allocations.
    public static let previewLandscapeSize = CGSize(width: 960, height: 540)
    public static let previewPortraitSize = CGSize(width: 540, height: 960)

    // MARK: - Public surface

    /// Serial queue every pipeline operation runs on (also the delegate queue).
    public let processingQueue: DispatchQueue

    /// Current output geometry. Thread-safe.
    public var targets: DualRenderTargets {
        configLock.withLock { $0.targets }
    }

    /// Delivered on `processingQueue` with each processed frame pair.
    /// Set once before the session starts; not guarded after that.
    public var onRender: ((DualRenderOutput) -> Void)?

    /// Delivered on `processingQueue` after each render with the persistent
    /// preview buffers (safe to read from any thread). Set once before use.
    public var onPreview: ((DualPreviewFrame) -> Void)?

    // MARK: - Resources (confined to processingQueue)

    private let ciContext: CIContext
    private var landscapePool: CVPixelBufferPool?
    private var portraitPool: CVPixelBufferPool?
    private var previewLandscapeBuffer: CVPixelBuffer?
    private var previewPortraitBuffer: CVPixelBuffer?

    private struct PipelineConfig {
        var preset: QualityPreset = .p1080_30
        var sourceSize: CGSize = .zero
        var targets: DualRenderTargets = .zero
        /// 9:16 portrait target zoom (1.0 = full frame). Applies ONLY to the
        /// portrait crop; the 16:9 landscape target stays full-width.
        var verticalZoomScale: CGFloat = 1.0
        /// Upright rotation applied by the capture connection (0/90/270) —
        /// recorded for diagnostics; the delivered frames are already upright.
        var rotationDegrees: CGFloat = 0
        /// Whether the delivered frames are mirrored (front camera).
        var mirrored = false
    }

    private let configLock = Mutex(PipelineConfig())
    private var renderedFrames = 0
    private var droppedFrames = 0
    private var processedFrames = 0
    private var didLogDeliveredFormat = false
    private var loggedDropCount = 0
    /// Confined to `processingQueue`; see `setRecording(_:)`.
    private var renderRecordingTargets = false

    // MARK: - Init

    public init(device: MTLDevice? = nil, preset: QualityPreset = .p1080_30) throws {
        processingQueue = DispatchQueue(label: "com.dualshot.render", qos: .userInteractive)

        guard let metalDevice = device ?? MTLCreateSystemDefaultDevice() else {
            throw CameraError.renderFailed(reason: "Metal device unavailable")
        }
        // Deterministic color management: an explicit sRGB working/output space
        // keeps the rendered YUV brightness and gamma stable (the default
        // "auto" spaces can push frames darker through the YUV round trip).
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        ciContext = CIContext(mtlDevice: metalDevice, options: [
            .cacheIntermediates: false,
            .workingColorSpace: sRGB,
            .outputColorSpace: sRGB,
        ])

        super.init()
    }

    // MARK: - Configuration

    /// (Re)configures the pipeline for a preset + sensor source size, rebuilding
    /// the output pools whenever the geometry changes. Call from the session
    /// queue (never from `processingQueue` — that would deadlock on the sync).
    public func configure(preset: QualityPreset, sourceSize: CGSize) throws {
        dispatchPrecondition(condition: .notOnQueue(processingQueue))
        try processingQueue.sync {
            let oldTargets = configLock.withLock { $0.targets }
            let targets = DualRenderTargets.computing(sourceSize: sourceSize)
            configLock.withLock { config in
                config.preset = preset
                config.sourceSize = sourceSize
                config.targets = targets
            }
            if targets != oldTargets || landscapePool == nil || portraitPool == nil {
                guard let land = Self.makePool(size: targets.landscapeSize),
                      let port = Self.makePool(size: targets.portraitSize) else {
                    throw CameraError.renderFailed(reason: "failed to create output pools for \(targets)")
                }
                landscapePool = land
                portraitPool = port
            }
            if previewLandscapeBuffer == nil || previewPortraitBuffer == nil {
                previewLandscapeBuffer = Self.makePersistentBuffer(size: Self.previewLandscapeSize)
                previewPortraitBuffer = Self.makePersistentBuffer(size: Self.previewPortraitSize)
            }
            renderedFrames = 0
            droppedFrames = 0
        }
    }

    /// Frees GPU resources. Idempotent.
    public func shutdown() {
        processingQueue.sync {
            onRender = nil
            onPreview = nil
            landscapePool = nil
            portraitPool = nil
            previewLandscapeBuffer = nil
            previewPortraitBuffer = nil
            configLock.withLock { $0.targets = .zero }
        }
    }

    /// Refreshes the orientation-only configuration (used on camera switches
    /// while recording, when the pool targets must stay fixed). The crop
    /// geometry always derives from the actual delivered frame size.
    public func updateOrientation(rotationDegrees: CGFloat, mirrored: Bool) {
        processingQueue.sync {
            configLock.withLock { config in
                config.rotationDegrees = rotationDegrees
                config.mirrored = mirrored
            }
        }
    }

    /// Toggles rendering of the recording pool targets. While previewing, the
    /// pools are unnecessary GPU work (they contended with the encoder and the
    /// preview presents, causing motion lag), so they are rendered only while
    /// recording. Dispatched asynchronously — never blocks the caller.
    public func setRecording(_ active: Bool) {
        processingQueue.async { [self] in
            self.renderRecordingTargets = active
        }
    }

    /// Sets the 9:16 portrait target zoom (`1.0` = full frame). The zoomed crop
    /// applies to BOTH the live preview portrait card and the recorded vertical
    /// pool buffer — the 16:9 landscape target is never affected. Safe to call
    /// at any time (preview or recording); the change is live next frame.
    public func setVerticalZoom(_ scale: CGFloat) {
        let clamped = min(max(scale, 1.0), 4.0)
        processingQueue.async { [self] in
            configLock.withLock { config in
                config.verticalZoomScale = clamped
            }
        }
    }

    /// Bounded estimate of the pipeline's working set (master frame + pool
    /// buffers), all in 420f bi-planar bytes (1.5 B/px).
    public func estimatedMemoryBytes() -> Int {
        let config = configLock.withLock { $0 }
        let master = Int(config.sourceSize.width * config.sourceSize.height * 1.5)
        let landscape = Int(config.targets.landscapeSize.width * config.targets.landscapeSize.height * 1.5) * Self.poolDepth
        let portrait = Int(config.targets.portraitSize.width * config.targets.portraitSize.height * 1.5) * Self.poolDepth
        return master + landscape + portrait
    }

    // MARK: - Frame entry points

    /// Manual entry (e.g. `CameraSessionEngine.enqueueFrame`). Serialized on
    /// `processingQueue`; safe to call from any thread.
    public func process(_ sampleBuffer: CMSampleBuffer) {
        let box = SampleBox(sampleBuffer)
        processingQueue.async { [weak self, box] in
            self?.processOnQueue(box.value)
        }
    }

    /// `AVCaptureVideoDataOutputSampleBufferDelegate` — already on
    /// `processingQueue`, so no hop.
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        processOnQueue(sampleBuffer)
    }

    private func processOnQueue(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !didLogDeliveredFormat {
            didLogDeliveredFormat = true
            let type = CVPixelBufferGetPixelFormatType(imageBuffer)
            Self.logger.info("first delivered frame: \(type) (\(Self.formatName(type))) \(CVPixelBufferGetWidth(imageBuffer))x\(CVPixelBufferGetHeight(imageBuffer))")
            print("[DualShot] first delivered frame: \(Self.formatName(type)) \(CVPixelBufferGetWidth(imageBuffer))x\(CVPixelBufferGetHeight(imageBuffer))")
        }
        if processedFrames % 120 == 0 {
            print("[DualShot] source camera Y avg=\(String(format: "%.1f", Self.yAverage(imageBuffer))) (dark<40, normal scene 60-200)")
        }
        processedFrames += 1
        render(source: imageBuffer, presentationTime: presentationTime)
    }

    private static func formatName(_ type: OSType) -> String {
        switch type {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: "420f full-range"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: "420v video-range"
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: "x420 10-bit"
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: "x420 10-bit video-range"
        default: "\(type)"
        }
    }

    // MARK: - Render (Core Image)

    private func render(source: CVPixelBuffer, presentationTime: CMTime) {
        // autoreleasepool: CI images, textures, and ObjC autoreleased
        // intermediates are drained every frame instead of accumulating, so
        // the render loop's memory is released immediately (smooth motion at
        // 30/60 fps). Pool buffers are ARC-managed and unaffected.
        autoreleasepool {
            renderInner(source: source, presentationTime: presentationTime)
        }
    }

    private func renderInner(source: CVPixelBuffer, presentationTime: CMTime) {
        guard let landscapePool, let portraitPool else { return }
        let config = configLock.withLock { $0 }
        let targets = config.targets
        guard targets.landscapeSize.width > 0 else { return }

        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        guard sourceWidth > 0, sourceHeight > 0 else { return }

        // Center-crop geometry (even-aligned; centered rects are invariant to
        // CI's bottom-left coordinate origin). The delivered frames are already
        // upright — the capture connection applies the 90° rotation.
        let sourceSize = CGSize(width: sourceWidth, height: sourceHeight)
        let landscapeRect = DualRenderTargets.centeredCrop(aspect: 16.0 / 9.0, in: sourceSize)
        // The 9:16 portrait crop is zoomed when the vertical zoom is enabled —
        // the same zoomed rect feeds the live preview AND the recording pool.
        let portraitRect = Self.zoomedRect(
            DualRenderTargets.centeredCrop(aspect: 9.0 / 16.0, in: sourceSize),
            scale: config.verticalZoomScale
        )

        let ciImage = CIImage(cvPixelBuffer: source) // zero-copy wrap

        var poolLandscapeBuffer: CVPixelBuffer?
        var poolPortraitBuffer: CVPixelBuffer?

        // Recording targets are rendered ONLY while recording: during preview
        // they are unnecessary GPU work that contended with the encoder and
        // the preview presents (visible as motion lag). The preview path uses
        // the small persistent buffers below.
        if renderRecordingTargets {
            guard let landscapeBuffer = Self.makeBuffer(from: landscapePool),
                  let portraitBuffer = Self.makeBuffer(from: portraitPool) else {
                drop("pool exhausted")
                return
            }
            let landscapeOutput = Self.scaledCrop(of: ciImage, rect: landscapeRect, to: targets.landscapeSize)
            let portraitOutput = Self.scaledCrop(of: ciImage, rect: portraitRect, to: targets.portraitSize)
            render(landscapeOutput, into: landscapeBuffer)
            render(portraitOutput, into: portraitBuffer)
            poolLandscapeBuffer = landscapeBuffer
            poolPortraitBuffer = portraitBuffer
        }

        // Persistent preview targets (display resolution) — always.
        if let previewLandscapeBuffer, let previewPortraitBuffer {
            let previewLandscape = Self.scaledCrop(of: ciImage, rect: landscapeRect, to: Self.previewLandscapeSize)
            let previewPortrait = Self.scaledCrop(of: ciImage, rect: portraitRect, to: Self.previewPortraitSize)
            render(previewLandscape, into: previewLandscapeBuffer)
            render(previewPortrait, into: previewPortraitBuffer)
        }

        renderedFrames += 1
        if renderedFrames.isMultiple(of: 120) {
            let landscapeAvg = poolLandscapeBuffer.map { Self.yAverage($0) } ?? -1
            let portraitAvg = poolPortraitBuffer.map { Self.yAverage($0) } ?? -1
            let previewAvg = previewLandscapeBuffer.map { Self.yAverage($0) } ?? -1
            print("[DualShot] rendered \(self.renderedFrames) frames (\(self.droppedFrames) dropped) — pool landscape Y avg=\(String(format: "%.1f", landscapeAvg)) pool portrait Y avg=\(String(format: "%.1f", portraitAvg)) preview landscape Y avg=\(String(format: "%.1f", previewAvg)) (dark<40, normal scene 60-200)")
            Self.logger.info("rendered \(self.renderedFrames) dual frames (\(self.droppedFrames) dropped)")
        }

        if renderRecordingTargets, let poolLandscapeBuffer, let poolPortraitBuffer {
            onRender?(DualRenderOutput(
                landscapeBuffer: poolLandscapeBuffer,
                portraitBuffer: poolPortraitBuffer,
                presentationTime: presentationTime
            ))
        }

        if let previewLandscapeBuffer, let previewPortraitBuffer {
            onPreview?(DualPreviewFrame(
                landscapeBuffer: previewLandscapeBuffer,
                portraitBuffer: previewPortraitBuffer,
                presentationTime: presentationTime
            ))
        }
    }

    /// Crops `rect` from `image`, translates it to the origin, and scales it
    /// to `targetSize`. Identity when the rect already matches the target.
    ///
    /// The translation is REQUIRED: CI's `render(_:to:bounds:)` needs the
    /// image extent to intersect the destination buffer's extent, which starts
    /// at (0,0). A centered crop (e.g. the 9:16 strip at x=657) has a non-zero
    /// origin, so without translating it back to (0,0) the render fails with
    /// "image extent and destination extent do not intersect" and the buffer
    /// stays empty (which displays as solid green).
    private static func scaledCrop(of image: CIImage, rect: CGRect, to targetSize: CGSize) -> CIImage {
        let cropped = image
            .cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        guard targetSize.width > 0, targetSize.height > 0,
              rect.width != targetSize.width || rect.height != targetSize.height else {
            return cropped
        }
        return cropped.transformed(by: CGAffineTransform(
            scaleX: targetSize.width / rect.width,
            y: targetSize.height / rect.height
        ))
    }

    /// Shrinks `rect` around its center by `1/scale` (aspect preserved) so that
    /// scaling it back to the fixed target size yields a `scale`-times zoom.
    /// Dimensions and origin are even-rounded so 4:2:0 chroma stays
    /// sample-aligned. Identity at `scale <= 1.0`. Centered rects are invariant
    /// to CI's bottom-left coordinate origin, like `centeredCrop`.
    private static func zoomedRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 1.0, rect.width > 0, rect.height > 0 else { return rect }
        var width = rect.width / scale
        var height = rect.height / scale
        width = CGFloat(Int(width) & ~1)
        height = CGFloat(Int(height) & ~1)
        let x = CGFloat(Int(rect.midX - width / 2) & ~1)
        let y = CGFloat(Int(rect.midY - height / 2) & ~1)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Renders a CI image into an IOSurface-backed 420f buffer (synchronous
    /// for the buffer content — Core Image owns the GPU write + sync).
    private func render(_ image: CIImage, into buffer: CVPixelBuffer) {
        ciContext.render(image, to: buffer, bounds: image.extent, colorSpace: nil)
    }

    // MARK: - Buffer helpers

    private static func makePool(size: CGSize) -> CVPixelBufferPool? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: poolDepth,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
            return nil
        }
        return pool
    }

    /// A single persistent IOSurface-backed buffer (not pooled) reused every
    /// frame for the preview targets.
    private static func makePersistentBuffer(size: CGSize) -> CVPixelBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes as CFDictionary, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    /// Allocates a pool buffer, failing (instead of growing the pool) once the
    /// allocation threshold is exceeded — this is what bounds GPU memory.
    private static func makeBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        let auxAttributes: [String: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey as String: poolDepth,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, auxAttributes as CFDictionary, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    // MARK: - Geometry

    /// Largest centered rect of `aspect` within `source` (shared with
    /// `DualRenderTargets.computing`).
    private static func centerCrop(aspect: CGFloat, source: CGSize) -> CGRect {
        DualRenderTargets.centeredCrop(aspect: aspect, in: source)
    }

    /// Samples every 32nd luma texel of a buffer's Y plane.
    private static func yAverage(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, [.readOnly])
        defer { CVPixelBufferUnlockBaseAddress(buffer, [.readOnly]) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return -1 }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var sum: UInt64 = 0
        var count: UInt64 = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                sum += UInt64(ptr[y * rowBytes + x])
                count += 1
                x += 32
            }
            y += 32
        }
        return count > 0 ? Double(sum) / Double(count) : -1
    }

    /// Counts a dropped frame, logging the reason for the first few so the
    /// console shows exactly why the preview/render is stalling.
    private func drop(_ reason: String) {
        droppedFrames += 1
        if loggedDropCount < 5 {
            loggedDropCount += 1
            Self.logger.warning("frame dropped: \(reason, privacy: .public)")
            print("[DualShot] frame dropped: \(reason)")
        }
    }
}

/// Documents the deliberate crossing of a non-Sendable `CMSampleBuffer` onto
/// the pipeline's serial queue for manual `process(_:)` injection. CMSampleBuffer
/// is immutable + refcounted, and the receiving queue is serial, so the value
/// is never accessed concurrently.
private nonisolated struct SampleBox: @unchecked Sendable {
    let value: CMSampleBuffer
    init(_ value: CMSampleBuffer) { self.value = value }
}
