//
//  DualPreviewMetalView.swift
//  DualShot Camera
//
//  MTKView bridge for the live dual preview. Each card hosts one of these
//  views; on every display refresh (up to 60 fps) it re-wraps the latest
//  persistent 420f preview buffer from the pipeline (zero-copy, via
//  CVMetalTextureCache) and renders an aspect-fitted YUV→RGB quad.
//

import CoreVideo
import Metal
import MetalKit
import SwiftUI
import UIKit

/// Which crop a preview view displays.
enum PreviewKind {
    case landscape
    case portrait
}

/// SwiftUI bridge — `UIViewControllerRepresentable` around an `MTKView`.
///
/// The `bufferProvider` closure is invoked on the main thread from the Metal
/// draw loop and returns the latest crop buffer (read straight off the
/// `@Observable` view model). `isLive` pauses the render loop when the session
/// is not producing frames. Front-camera mirroring is applied by the capture
/// connection, so the delivered buffers (and both previews) are already
/// natural — no flipping here.
struct DualPreviewMetalView: UIViewControllerRepresentable {

    let kind: PreviewKind
    let isLive: Bool
    /// Draw rate matched to the camera frame rate (30/60) — drawing faster
    /// than the source only adds present pressure on the GPU.
    let preferredFPS: Int
    let bufferProvider: () -> CVPixelBuffer?

    init(kind: PreviewKind, isLive: Bool, preferredFPS: Int = 30, bufferProvider: @escaping () -> CVPixelBuffer?) {
        self.kind = kind
        self.isLive = isLive
        self.preferredFPS = preferredFPS
        self.bufferProvider = bufferProvider
    }

    func makeCoordinator() -> Void {}

    func makeUIViewController(context: Context) -> MTKPreviewViewController {
        let controller = MTKPreviewViewController()
        controller.renderer.frameProvider = bufferProvider
        controller.metalView.isPaused = !isLive
        controller.metalView.preferredFramesPerSecond = preferredFPS
        return controller
    }

    func updateUIViewController(_ uiViewController: MTKPreviewViewController, context: Context) {
        uiViewController.renderer.frameProvider = bufferProvider
        uiViewController.metalView.isPaused = !isLive
        uiViewController.metalView.preferredFramesPerSecond = preferredFPS
    }
}

/// Hosts the `MTKView` and its renderer.
final class MTKPreviewViewController: UIViewController {

    let metalView: MTKView
    let renderer: DualPreviewMetalRenderer

    init() {
        let device = MTLCreateSystemDefaultDevice()!
        metalView = MTKView(frame: .zero, device: device)
        renderer = DualPreviewMetalRenderer(device: device)
        super.init(nibName: nil, bundle: nil)

        metalView.delegate = renderer
        metalView.device = device
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColor(red: 0.01, green: 0.015, blue: 0.02, alpha: 1)
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = 60
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.layer.cornerRadius = 24
        metalView.layer.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = metalView
    }
}

// MARK: - Renderer

/// A quad renderer that converts a 420f bi-planar buffer (Y + UV planes) to
/// RGB and presents it aspect-fitted. Runs on the main thread (MTKView draw).
///
/// Fail-soft by design: if the pipeline state cannot be built (Metal library
/// or render pipeline failure), the view presents a clear drawable instead of
/// crashing — the card simply shows its dark backdrop.
final class DualPreviewMetalRenderer: NSObject, MTKViewDelegate {

    /// Shader uniforms: `float2 scale` (quad scale for aspect fit). Padded to
    /// 16 bytes — MSL constant structs have a 16-byte stride, and Metal
    /// validates the buffer length against that stride.
    private struct PreviewUniforms {
        var scale = SIMD2<Float>(1, 1)
        var padding0: Float = 0
        var padding1: Float = 0
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLRenderPipelineState?
    private let vertexBuffer: MTLBuffer?
    private var textureCache: CVMetalTextureCache?
    private var flushCounter = 0
    private var uniforms = PreviewUniforms()

    /// Latest crop buffer, provided by the view model on the main thread.
    var frameProvider: (() -> CVPixelBuffer?)?

    init(device: MTLDevice) {
        self.device = device
        commandQueue = device.makeCommandQueue()

        // Fail-soft pipeline construction.
        var state: MTLRenderPipelineState?
        var vertices: [Float]?
        if let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
           let vertexFunction = library.makeFunction(name: "previewVertex"),
           let fragmentFunction = library.makeFunction(name: "previewFragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            state = try? device.makeRenderPipelineState(descriptor: descriptor)
            // Fullscreen quad: two triangles, interleaved (position, texCoord).
            vertices = [
                -1, -1, 0, 1,
                 1, -1, 1, 1,
                 1,  1, 1, 0,
                -1, -1, 0, 1,
                 1,  1, 1, 0,
                -1,  1, 0, 0,
            ]
        }
        pipelineState = state
        vertexBuffer = vertices.map { device.makeBuffer(bytes: $0, length: $0.count * MemoryLayout<Float>.size, options: []) } ?? nil

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache

        super.init()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandQueue,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        // Fail-soft: with no pipeline we still present a cleared frame so the
        // draw loop stays healthy.
        if let pipelineState, let vertexBuffer {
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

            if let buffer = frameProvider?(),
               CVPixelBufferGetWidth(buffer) > 0,
               let luma = makeTexture(from: buffer, plane: 0, pixelFormat: .r8Unorm),
               let chroma = makeTexture(from: buffer, plane: 1, pixelFormat: .rg8Unorm) {
                let sourceSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
                let viewSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
                uniforms.scale = Self.aspectFitScale(source: sourceSize, view: viewSize)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<PreviewUniforms>.size, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PreviewUniforms>.size, index: 1)
                encoder.setFragmentTexture(luma, index: 0)
                encoder.setFragmentTexture(chroma, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        flushCounter += 1
        if flushCounter.isMultiple(of: 30), let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    // MARK: - Helpers

    /// Aspect-fit quad scale so content is never stretched (letterboxed).
    private static func aspectFitScale(source: CGSize, view: CGSize) -> SIMD2<Float> {
        guard source.width > 0, source.height > 0, view.width > 0, view.height > 0 else {
            return SIMD2<Float>(1, 1)
        }
        let sourceAspect = source.width / source.height
        let viewAspect = view.width / view.height
        let scaleX = min(1, viewAspect / sourceAspect)
        let scaleY = min(1, sourceAspect / viewAspect)
        return SIMD2<Float>(Float(scaleX), Float(scaleY))
    }

    private func makeTexture(from buffer: CVPixelBuffer, plane: Int, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        var textureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, pixelFormat, width, height, plane, &textureRef)
        guard status == kCVReturnSuccess, let textureRef, let texture = CVMetalTextureGetTexture(textureRef) else { return nil }
        return texture
    }

    // MARK: - Shader

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PreviewUniforms {
        float2 scale;
        float  padding0;
        float  padding1;
    };

    struct PreviewVertex {
        float2 pos;
        float2 uv;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex VertexOut previewVertex(uint vid [[vertex_id]],
                                   const device PreviewVertex* verts [[buffer(0)]],
                                   constant PreviewUniforms& uniforms [[buffer(1)]]) {
        VertexOut out;
        out.position = float4(verts[vid].pos * uniforms.scale, 0.0, 1.0);
        out.texCoord = verts[vid].uv;
        return out;
    }

    fragment half4 previewFragment(VertexOut in [[stage_in]],
                                   texture2d<float, access::sample> yTex [[texture(0)]],
                                   texture2d<float, access::sample> uvTex [[texture(1)]]) {
        constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
        float y = yTex.sample(s, in.texCoord).r;
        float2 uv = uvTex.sample(s, in.texCoord).rg - float2(0.5, 0.5);
        // BT.709 full-range YCbCr → RGB.
        float r = y + 1.5748 * uv.y;
        float g = y - 0.1873 * uv.x - 0.4681 * uv.y;
        float b = y + 1.8556 * uv.x;
        return half4(half3(r, g, b), 1.0);
    }
    """
}
