@preconcurrency import AVFoundation
import Foundation
import UIKit

struct ExportService: Sendable {
    func exportBoth(from masterURL: URL, progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportedVideos {
        let asset = AVURLAsset(url: masterURL)
        let landscapeURL = Self.makeOutputURL(prefix: "landscape-16x9")
        let portraitURL = Self.makeOutputURL(prefix: "portrait-9x16")
        try await export(asset: asset, aspect: .landscape, outputURL: landscapeURL) { value in
            progress(ExportProgress(landscape: value, portrait: 0))
        }

        try await export(asset: asset, aspect: .portrait, outputURL: portraitURL) { value in
            progress(ExportProgress(landscape: 1, portrait: value))
        }

        progress(ExportProgress(landscape: 1, portrait: 1))
        return ExportedVideos(landscapeURL: landscapeURL, portraitURL: portraitURL)
    }

    private func export(asset: AVURLAsset, aspect: ExportAspect, outputURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.removeItemIfExists(at: outputURL)

        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)

        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError.exportFailed("No video track was found in the master recording.")
        }
        let preferredTransform = try await sourceVideo.load(.preferredTransform)
        let naturalSize = try await sourceVideo.load(.naturalSize)

        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AppError.exportFailed("Could not create a video composition track.")
        }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: .zero)
        videoTrack.preferredTransform = .identity

        if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceAudio, at: .zero)
        }

        let renderSize = aspect.renderSize
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        videoComposition.sourceTrackIDForFrameTiming = videoTrack.trackID
        videoComposition.renderScale = 1

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        let transform = Self.centerCropTransform(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            renderSize: renderSize
        )
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let preset = Self.bestPreset(for: aspect)
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw AppError.exportFailed("Could not create an export session.")
        }

        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = false

        progress(0.05)
        do {
            try await exportSession.export(to: outputURL, as: .mov)
            progress(1)
        } catch {
            throw AppError.exportFailed(error.localizedDescription)
        }
    }

    static func centerCropTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform, renderSize: CGSize) -> CGAffineTransform {
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displaySize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
        let scale = max(renderSize.width / displaySize.width, renderSize.height / displaySize.height)
        let scaledSize = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
        let translateToOrigin = CGAffineTransform(translationX: -transformedRect.minX, y: -transformedRect.minY)
        let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
        let center = CGAffineTransform(
            translationX: (renderSize.width - scaledSize.width) / 2,
            y: (renderSize.height - scaledSize.height) / 2
        )
        return preferredTransform
            .concatenating(translateToOrigin)
            .concatenating(scaleTransform)
            .concatenating(center)
    }

    private static func bestPreset(for aspect: ExportAspect) -> String {
        switch aspect {
        case .landscape:
            if AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVC3840x2160) {
                return AVAssetExportPresetHEVC3840x2160
            }
        case .portrait:
            if AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality) {
                return AVAssetExportPresetHEVCHighestQuality
            }
        }
        return AVAssetExportPresetHighestQuality
    }

    private static func makeOutputURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .appendingPathExtension("mov")
    }
}
