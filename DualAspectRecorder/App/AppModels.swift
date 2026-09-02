import AVFoundation
import CoreGraphics
import Foundation

enum CapturePosition: String, CaseIterable, Identifiable {
    case back = "Rear"
    case front = "Front"

    var id: String { rawValue }

    var avPosition: AVCaptureDevice.Position {
        switch self {
        case .back: .back
        case .front: .front
        }
    }
}

enum RecorderState: Equatable {
    case idle
    case preparing
    case ready
    case recording
    case exporting(progress: Double)
    case saved(ExportedVideos)
    case failed(String)
    case permissionDenied(String)
}

struct ExportedVideos: Equatable {
    let landscapeURL: URL
    let portraitURL: URL
}

enum ExportAspect: String, CaseIterable {
    case landscape
    case portrait

    var displayName: String {
        switch self {
        case .landscape: "Landscape 16:9"
        case .portrait: "Portrait 9:16"
        }
    }

    var renderSize: CGSize {
        switch self {
        case .landscape: CGSize(width: 3840, height: 2160)
        case .portrait: CGSize(width: 2160, height: 3840)
        }
    }

    var aspectRatio: CGFloat {
        renderSize.width / renderSize.height
    }
}

struct ExportProgress: Equatable {
    var landscape: Double = 0
    var portrait: Double = 0

    var combined: Double {
        (landscape + portrait) / 2
    }
}

enum AppError: LocalizedError {
    case cameraUnavailable
    case microphoneUnavailable
    case cannotConfigureSession(String)
    case cannotStartRecording(String)
    case cannotFinishRecording
    case exportFailed(String)
    case photoSaveFailed(String)
    case permissionDenied(String)
    case lowStorage

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            "Camera is unavailable on this device."
        case .microphoneUnavailable:
            "Microphone is unavailable on this device."
        case .cannotConfigureSession(let detail):
            "Camera setup failed: \(detail)"
        case .cannotStartRecording(let detail):
            "Recording could not start: \(detail)"
        case .cannotFinishRecording:
            "Recording could not be finalized."
        case .exportFailed(let detail):
            "Export failed: \(detail)"
        case .photoSaveFailed(let detail):
            "Saving to Photos failed: \(detail)"
        case .permissionDenied(let detail):
            detail
        case .lowStorage:
            "Not enough local storage is available for a high-quality recording."
        }
    }
}

struct ExportGeometry {
    let renderSize: CGSize
    let cleanApertureSize: CGSize
    let preferredTransform: CGAffineTransform

    var naturalDisplaySize: CGSize {
        let transformed = CGRect(origin: .zero, size: cleanApertureSize).applying(preferredTransform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    func centeredCropTransform() -> CGAffineTransform {
        let source = naturalDisplaySize
        let scale = max(renderSize.width / source.width, renderSize.height / source.height)
        let scaled = CGSize(width: source.width * scale, height: source.height * scale)
        let x = (renderSize.width - scaled.width) / 2
        let y = (renderSize.height - scaled.height) / 2
        return preferredTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: x / scale, y: y / scale))
    }
}
