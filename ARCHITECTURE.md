# DualShot Camera — Architecture

Foundational architecture for an iOS 18+ SwiftUI app that records **two videos
simultaneously** — one 16:9 landscape, one 9:16 portrait — from a single
camera sensor. Target hardware: iPhone 16 family (A18 / A18 Pro HEVC encoder).

This document describes the layer boundaries, threading model, and data flow.
No UI is included in this step.

---

## 1. Layer map

| Layer | Types | Responsibility |
|---|---|---|
| **State** | `CameraState`, `CameraPhase`, `CameraError`, `CameraStateMachine` | Global, thread-safe state model + transition validation |
| **Encoding** | `QualityPreset`, `DualRenderOutput` | Preset math (bitrate/GOP/color, A18-tuned) and the dual-frame unit of work |
| **Services** | `CameraEngineProtocol`, `DualAssetWriterProtocol`, `DualRecordingSession`, `DualRecordingResult`, `CameraEvent` | Contracts for session config, frame processing, and dual encoding/writing |
| **App facade** | `CameraSessionModel` | `@MainActor @Observable` bridge the UI observes |
| **UI (future)** | — | SwiftUI views observe `CameraSessionModel` only |

## 2. Threading model

```
AVCaptureVideoDataOutput delegate (serial queue)
        │  enqueueFrame(_ sampleBuffer:)         ← sync, returns immediately
        ▼
┌─────────────────────────────────────────────────────────────┐
│  Engine — nonisolated, Sendable                              │
│  Single serialized render pipeline (serial queue)            │
│  render → DualRenderOutput (16:9 + 9:16 CVPixelBuffers)      │
│  ──► dualFrameStream (AsyncStream)                           │
│  ──► assetWriter.append(_:)            same serial context   │
└─────────────────────────────────────────────────────────────┘
        │  transitions                 │  events (AsyncStream)
        ▼                              ▼
┌─────────────────────┐   ┌────────────────────────────────────┐
│ CameraStateMachine  │   │ CameraSessionModel  (@MainActor)   │
│ Mutex-guarded state │   │ @Observable state + events stream  │
│ states: AsyncStream │──►│ Task { for await … } syncs state   │
└─────────────────────┘   └────────────────────────────────────┘
```

Key rules:

- **`CameraStateMachine` is the single source of truth.** It is `nonisolated`,
  `Sendable`, and guarded by `Synchronization.Mutex` — readable and
  transitionable from any thread. `CameraStateMachine.shared` is the global
  instance.
- **`DualRenderOutput` never crosses an actor boundary.** `CVPixelBuffer` is
  non-`Sendable`; it is produced and consumed inside the engine's one serial
  render context (documented on the type).
- **UI stays on the main actor.** Only `CameraSessionModel` is observed by
  SwiftUI; it subscribes to the machine's `AsyncStream` and the engine's event
  stream and republishes as `@Observable` state.

## 3. State machine

`CameraState` — `idle, configuring, previewing, recording, processing, error`:

```
idle ──► configuring ──► previewing ──► recording ──► processing ──► previewing|idle
 ▲          │  │             │  ▲            │              │
 │          │  ▼             ▼  │            ▼              ▼
 │          │ error ◄───────────┴────────── error ───────── error
 │          ▼
 └────── idle (abort)
error ──► idle | configuring (recover)
```

Transition validation lives in `CameraState.validTransitions` /
`CameraState.allowsTransition(to:)`; the machine rejects anything else with
`CameraError.invalidStateTransition`. Notifications: every accepted transition
is yielded to `states` (unicast `AsyncStream`; the model owns the single
subscription — poll `state` elsewhere).

## 4. Dual pipeline data flow

1. `QualityPreset` defines capture (resolution/fps) and HEVC encoding
   (average bitrate, ±20% VBR range, 2 s keyframe interval, BT.709, Main/Auto
   profile). Bitrates are calibrated for the A18 encoder: 1080p30 ≈ 12 Mbps,
   1080p60 ≈ 20 Mbps, 4K30 ≈ 42 Mbps.
2. `CameraEngineProtocol` configures the session, exposes the live preview,
   and feeds frames into the render pipeline.
3. The render pipeline produces `DualRenderOutput` (landscape 16:9 +
   portrait 9:16 `CVPixelBuffer`s with a shared `presentationTime`).
4. `DualAssetWriterProtocol` runs **two** `AVAssetWriter`s (one per output),
   each HEVC + pixel-buffer adaptor, started/finished together; audio samples
   are appended to both. `DualRecordingSession` / `DualRecordingResult` carry
   the two URLs and sizes.
5. `CameraSessionModel` (@Observable) mirrors state and forwards
   `CameraEvent`s (preset applied, recording started/finished/cancelled,
   error).

## 5. File map

```
DualShot Camera/
├── Core/
│   └── Camera/
│       ├── CameraState.swift               # CameraPhase, CameraState, CameraError, transition table
│       ├── CameraStateMachine.swift        # thread-safe global machine (+ .shared)
│       ├── QualityPreset.swift             # p1080_30 / p1080_60 / p4k_30 + A18 HEVC tuning
│       ├── DualRenderOutput.swift          # 16:9 + 9:16 CVPixelBuffer pair, targets, preview frames
│       ├── CameraEvent.swift               # app-facing domain events
│       ├── DualRecording.swift             # DualRecordingSession, DualRecordingResult
│       ├── CameraEngineProtocol.swift      # session config + frame pipeline contract
│       ├── DualAssetWriterProtocol.swift   # dual encode/write contract
│       ├── CameraSessionEngine.swift       # concrete engine (AVCaptureSession + wiring)
│       ├── MetalDualCropPipeline.swift     # GPU dual-crop + persistent preview targets
│       ├── DualAssetWriterEngine.swift     # two AVAssetWriters, PTS-rebased
│       └── CameraSessionModel.swift        # @MainActor @Observable facade + HUD stats
└── UI/
    ├── CameraScreen.swift                  # single-screen layout (cards + controls)
    ├── DualPreviewCard.swift               # glassmorphic card chrome + ratio badge
    ├── DualPreviewMetalView.swift          # MTKView bridge (UIViewControllerRepresentable)
    ├── QualitySelectorPill.swift           # animated preset picker
    ├── RecordButton.swift                  # glowing record control
    ├── RecordingHUD.swift                  # elapsed / sizes / FPS
    └── Haptics.swift                       # UIImpactFeedbackGenerator wrappers
```

## 6. Concurrency notes (Swift 6)

- Project uses Xcode 26 **approachable concurrency** (default `MainActor`
  isolation). Engine-layer types opt out explicitly with `nonisolated`
  (SE-0449) so background AVFoundation work is never main-actor bound.
- All cross-layer messages are `Sendable` (`CameraState`, `CameraError`,
  `QualityPreset`, `CameraEvent`, session/result values).
- `QualityPreset.compressionProperties` is computed (not stored) so the
  `Sendable` enum carries no non-`Sendable` `[String: Any]` storage.

## 7. Implemented media engines

### `CameraSessionEngine` (`Core/Camera/CameraSessionEngine.swift`)
- Locks the **primary back camera** (`builtInWideAngleCamera`, the iPhone 16
  main sensor) and configures the `AVCaptureSession` to a **4K-capable master
  stream** (`AVCaptureVideoDataOutput`, `420YpCbCr8BiPlanarFullRange`, no
  conversions in the capture path).
- **Dynamic preset reconfiguration** (`updatePreset` / `configure`): picks the
  device `activeFormat` closest to the preset (exact 16:9 dimensions first,
  then smallest area, then max FPS), sets `activeVideoMin/MaxFrameDuration`
  inside `beginConfiguration/commitConfiguration`, and rebuilds the render
  pipeline's pools when geometry changes. Format changes require a stopped
  session (state `.idle`), enforced by the state machine.
- Drives `CameraStateMachine` through the transition table and emits
  `CameraEvent`s; forwards processed frames to the writer while recording and
  to `dualFrameStream` (`.bufferingNewest(1)`) while previewing.

### `MetalDualCropPipeline` (`Core/Camera/MetalDualCropPipeline.swift`)
- **Zero-copy**: incoming frames are wrapped as Metal textures via
  `CVMetalTextureCache` (Y plane `r8Unorm`, UV plane `rg8Unorm`). Outputs are
  IOSurface-backed pool buffers whose planes become write textures via
  `MTLDevice.makeTexture(descriptor:iosurface:plane:)` with explicit
  `.shaderWrite` (this SDK's texture cache has no usage attribute).
- **Simultaneous center crops** in one command buffer, two dispatches:
  luma pass + chroma pass of a single `dualCropScale` MSL kernel that writes
  both destinations (landscape 16:9, portrait 9:16) per dispatch. Crop rects
  are even-aligned for 4:2:0 chroma; portrait is produced at native crop
  resolution (no scaling — true zero-latency); landscape matches the preset.
- **Bounded memory**: output `CVPixelBufferPool`s with
  `kCVPixelBufferPoolAllocationThresholdKey` — allocation fails instead of
  growing, and the frame is dropped (real-time backpressure).

### `DualAssetWriterEngine` (`Core/Camera/DualAssetWriterEngine.swift`)
- Actor; runs **two `AVAssetWriter`s** (HEVC, A18 hardware encoder) writing
  `landscape_output.mov` and `portrait_output.mov` in parallel, each with a
  pixel-buffer adaptor and an AAC audio input.
- **Aligned PTS**: both writers `startSession(atSourceTime: .zero)`; the first
  video frame's PTS becomes the rebase offset applied to every video append
  and every audio sample (pre-roll audio dropped) — identical rebasing on both
  writers keeps the pair frame-synchronized.
- Backpressure via `isReadyForMoreMediaData` (drop, don't buffer); cancels
  delete partial files.

### Memory budget (dual 4K @ 30, 420f bi-planar = 1.5 B/px)
| Component | Size |
|---|---|
| Master frame in flight (3840×2160) | 11.9 MiB |
| Landscape pool (4 × 3840×2160) | 47.4 MiB |
| Portrait pool (4 × 1216×2160) | 15.0 MiB |
| Encoder/audio/command overhead (est.) | ~5–10 MiB |
| **Total** | **≈ 80–84 MiB** (pool depth 4 gives 60 fps encoder headroom) |

The pools bound the GPU working set: while recording, every pool buffer is
owned by the writer until the encoder releases it; the preview stream is
paused during recording so it cannot hold pool buffers. (The dual frame
stream is never fed pool buffers — an unconsumed stream would starve the
pools and cause preview stutter; live preview uses the persistent preview
buffers instead.)

## 8. Next steps

1. Gallery/Photos handoff for finished dual recordings.
2. Optional: rotate the 9:16 output to upright portrait (sensor-space crops
   are currently unrotated; both outputs share the sensor orientation).

## 9. Camera switching & Cinematic Mode

- **Camera flip**: `CameraEngineProtocol.switchCamera(to:)` swaps the session's
  video input inside a single `beginConfiguration/commitConfiguration`
  transaction — the session never stops, so the render pipeline and an
  in-flight recording are uninterrupted (zero frame drops by design). The
  front camera is the TrueDepth device; the format picker falls back to the
  largest fps-capable format when the preset exceeds the camera's capabilities
  (e.g. no 4K on the front). The front-camera preview is mirrored
  horizontally in the MTKView renderer (`mirrored:` uniform) — recorded files
  stay un-mirrored.
- **Cinematic Mode**: on the iOS 26 SDK the per-input
  `AVCaptureDeviceInput.isPortraitEffectEnabled` toggle no longer exists. The
  app opts in via `Info.plist` (`NSCameraPortraitEffectEnabled`, merged through
  `INFOPLIST_FILE`) and the effect follows the system Control Center toggle.
  `CameraEngineProtocol.setCinematic(enabled:)` records the request, checks the
  current format's `isPortraitEffectSupported`, and reports the live state via
  `CameraEvent.cinematicChanged` / `cinematicUnsupported` (UI warning + pill).
- UI: `UI/CameraSwitcher.swift` — glassmorphic floating capsule with the camera
  flip (rotate icon) and the CINEMATIC/STANDARD pill; `UI/CameraScreen.swift`
  shows the fallback warning banner.
