# DualShot Camera

> **Your content, both ways. One take, zero ads.**
>
> — *No Ads Studio by TheOneKiK*

DualShot Camera is a native SwiftUI + AVFoundation iPhone app that captures one high‑quality 4K HEVC master recording and simultaneously produces both **16:9 landscape** and **9:16 portrait** videos — perfect for cross‑platform social media publishing.

---

## Why I Built This

I needed a simple, clean camera app that could record once and give me both landscape and portrait videos — without ads, without subscriptions, without tracking. Every app I found either wanted my data or tried to sell me something.

So I built my own. It's my first iOS app, made for my own need, and I'm sharing it openly.

**No Ads Studio by TheOneKiK** isn't a company — it's a promise. This app will never have ads, analytics, trackers, or upsells. Just clean code that does one thing well.

---

## Features

### Dual‑Stream Recording
- Single AVCaptureSession delivers 4K (or 1080p) master frames to a Metal‑backed Core Image pipeline.
- Each frame is crop‑rendered twice — once to a 16:9 landscape target, once to a 9:16 portrait target — via zero‑copy `CIImage(cvPixelBuffer:)` wrapping.
- Both crops are written concurrently by two independent `AVAssetWriter` instances, PTS‑rebased and synchronised.
- Audio (48 kHz AAC) is written to both tracks from a shared `AVCaptureAudioDataOutput`.

### HEVC Presets (A18‑tuned)
| Preset    | Dimensions | fps | Target bitrate | Hard cap |
|-----------|------------|-----|----------------|----------|
| p1080_30  | 1920×1080  | 30  | 9 Mbps         | 9 Mbps   |
| p1080_60  | 1920×1080  | 60  | 14 Mbps        | 14 Mbps  |
| p4k_30    | 3840×2160  | 30  | 32 Mbps        | 32 Mbps  |

- `kVTCompressionPropertyKey_DataRateLimits` enforces a 1‑second window hard cap.
- BT.709 color metadata; `allowFrameReordering = false` for low‑latency capture.
- Key‑frame every 2 seconds.

### Cinematic Mode (Portrait Effect)
- Auto‑switches active format to a depth‑capable 1080p@30 format when the current high‑fps/4K format cannot render the effect.
- The switch happens live inside an `AVCaptureSession` configuration transaction — the session never stops.
- When the system Portrait Effect toggle (Control Center) is off, the request stays **pending**; a lightweight watcher completes the activation (format auto‑adjust, toast, pill state) the moment the user enables the effect.
- Turning Cinematic off restores the user’s selected preset live.

### Live Dual Preview
- Two MTKView‑backed preview cards rendered with a Metal‑backed `CIContext` → sRGB pipeline.
- **16:9 landscape** card (960×540) – top.
- **9:16 portrait** card (540×960) – bottom.
- Both cards update at the capture frame rate with zero‑copy texture wrap via `CVMetalTextureCache`.

### Vertical Zoom (9:16 Portrait)
- **3‑way cycle: 1.0× → 1.2× → 1.5× → 1.0×**, applied exclusively to the portrait crop.
- The zoomed crop rect shrinks the 9:16 centred region by `1/scale`, then scales it back to the fixed target — delivering true optical‑reminiscent zoom.
- Updates **live** on the preview card and is **baked into the recorded vertical `.mov`**.
- The 16:9 landscape pipeline is never affected.
- Compact glassmorphic pill at the top‑trailing corner of the portrait card.

### Camera Switching (Front / Rear)
- Live input swap inside a single `beginConfiguration/commitConfiguration` block — the session never stops.
- Session preset is auto‑downgraded when the target camera cannot deliver the current resolution.
- Front‑camera mirroring + 90° rotation are applied post‑commit.

### Writer Pre‑warm
- An `AVAssetWriter` session is started in the background as soon as preview starts (the long HEVC encoder negotiation takes ~8 s cold).
- The record tap consumes the pre‑warmed session (~10–22 ms re‑warm on subsequent recordings).
- Invalidated when pipeline targets change (preset, camera, cinematic, zoom).

### Photos Integration
- Every completed dual recording is automatically saved to the Photos library via `PHPhotoLibrary.shared().performChanges`.

---

## Architecture

```
AVCaptureSession (sessionQueue)
    ├── AVCaptureVideoDataOutput (420v video‑range)
    │       └── MetalDualCropPipeline (processingQueue, userInteractive)
    │               └── DualRenderOutput × per frame
    │                       ├── → previewFrames (persistent, UI‑safe, MainActor)
    │                       └── → onRender (pool buffers → writer, if recording)
    └── AVCaptureAudioDataOutput (audioQueue)
            └── → DualAssetWriterEngine.appendAudio

DualAssetWriterEngine (writeQueue, serial)
    ├── AVAssetWriter (landscape, HEVC × 1080×1920)
    └── AVAssetWriter (portrait, HEVC × 1920×1080)
```

### Concurrency Model
- **sessionQueue** (serial, .userInitiated) — AVCaptureSession configuration.
- **processingQueue** (serial, .userInteractive) — pipeline render (Core Image).
- **writeQueue** (serial) — AVAssetWriter appends.
- **MainActor** — `@Observable CameraSessionModel` facade, SwiftUI views.
- Thread‑safe flags: `Mutex<T>` from `Synchronization`.

---

## Requirements

- **iOS 26.5** (Xcode 26.6, Swift 6.3.3)
- **iPhone 16 / A18** family recommended (HEVC hardware encoder; Portrait Effect requires depth‑capable camera)
- A physical iPhone is required (Simulator does not expose camera hardware)

---

## Project Structure

```
DualShot Camera.xcodeproj
Info.plist                              # Permissions + Portrait Effect opt‑in
DualShot Camera/
    Core/Camera/
        CameraState.swift               # Finite state machine (Idle…Error)
        CameraStateMachine.swift        # Thread‑safe Mutex‑guarded machine
        CameraEngineProtocol.swift      # Engine contract (nonisolated protocol)
        CameraSessionEngine.swift       # AVCaptureSession + pipeline wiring
        MetalDualCropPipeline.swift     # Core Image dual‑render pipeline
        DualAssetWriterProtocol.swift
        DualAssetWriterEngine.swift     # Dual AVAssetWriter management
        DualRenderOutput.swift          # Crop targets + preview frame types
        QualityPreset.swift             # 1080p30/60, 4K30 HEVC bitrates
        DualRecording.swift             # Session / result value types
        CameraEvent.swift               # Domain event enum
        VerticalZoom.swift              # 1.0/1.2/1.5× zoom enum
    UI/
        CameraScreen.swift              # Root camera view
        DualPreviewCard.swift           # Glassmorphic preview card chrome
        DualPreviewMetalView.swift      # MTKView + Metal renderer wrapper
        CameraSwitcher.swift            # Flip + Cinematic pill controls
        QualitySelectorPill.swift       # Preset picker
        RecordButton.swift              # Circular record/stop
        RecordingHUD.swift              # Elapsed time + file size
        Haptics.swift                   # Centralised haptic feedback
    ContentView.swift                   # App entry: engine → model → UI
    DualShot_CameraApp.swift            # @main App struct (fail‑soft engine)
```

---

## Key Design Decisions
- **420v (video‑range) camera input**: Core Image decodes YUV assuming video range; 420f (full‑range) caused ~50 % darkening.
- **sRGB working/output color space** on `CIContext` + `AVCaptureDevice.activeColorSpace` = .sRGB + `automaticallyConfiguresCaptureDeviceForWideColor = false`.
- **Pool‑backed recording buffers** (`poolDepth = 4`): bounded GPU memory (~80 MB peak for 4K); pool exhaustion drops frames instead of growing memory.
- **Preview buffers are persistent, not pooled**: the UI can re‑read the latest crops without holding pool allocations.
- No ads, no tracking, no internet permissions — works fully offline, requests zero network access.

---

## License

MIT — see LICENSE file.