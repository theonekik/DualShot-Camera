@preconcurrency import AVFoundation
import Foundation
import VideoToolbox

final class RecordingWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DualAspectRecorder.RecordingWriter")
    private let outputURL: URL
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var startTime: CMTime?
    private var isFinishing = false
    private var continuation: CheckedContinuation<URL, Error>?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start(videoFormat: CMFormatDescription, audioFormat: CMFormatDescription?) throws {
        try FileManager.default.removeItemIfExists(at: outputURL)

        let dimensions = CMVideoFormatDescriptionGetDimensions(videoFormat)
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        let bitrate = adaptiveBitrate(width: width, height: height)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = true
        videoInput.mediaTimeScale = 600

        guard writer.canAdd(videoInput) else {
            throw AppError.cannotStartRecording("The video encoder could not be attached.")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audioFormat {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 192_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput

        guard writer.startWriting() else {
            throw AppError.cannotStartRecording(writer.error?.localizedDescription ?? "Unknown writer error.")
        }
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer, transform: CGAffineTransform) {
        let buffer = SendableSampleBuffer(sampleBuffer: sampleBuffer)
        queue.async { [weak self] in
            self?.append(buffer.sampleBuffer, mediaType: .video, transform: transform)
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        let buffer = SendableSampleBuffer(sampleBuffer: sampleBuffer)
        queue.async { [weak self] in
            self?.append(buffer.sampleBuffer, mediaType: .audio, transform: .identity)
        }
    }

    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return }
                self.continuation = continuation
                self.finishLocked()
            }
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, mediaType: AVMediaType, transform: CGAffineTransform) {
        guard !isFinishing, let writer else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTime == nil, mediaType == .video {
            startTime = timestamp
            videoInput?.transform = transform
            writer.startSession(atSourceTime: timestamp)
        }

        guard startTime != nil else { return }

        switch mediaType {
        case .video:
            if videoInput?.isReadyForMoreMediaData == true {
                videoInput?.append(sampleBuffer)
            }
        case .audio:
            if audioInput?.isReadyForMoreMediaData == true {
                audioInput?.append(sampleBuffer)
            }
        default:
            break
        }
    }

    private func finishLocked() {
        guard !isFinishing, let writer else {
            continuation?.resume(throwing: AppError.cannotFinishRecording)
            continuation = nil
            return
        }

        isFinishing = true
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        writer.finishWriting { [weak self] in
            guard let recorder = self else { return }
            recorder.queue.async {
                recorder.completeFinishLocked()
            }
        }
    }

    private func completeFinishLocked() {
        if writer?.status == .completed {
            continuation?.resume(returning: outputURL)
        } else {
            continuation?.resume(throwing: AppError.cannotStartRecording(writer?.error?.localizedDescription ?? "Writer did not complete."))
        }
        continuation = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        startTime = nil
        isFinishing = false
    }

    private func adaptiveBitrate(width: Int, height: Int) -> Int {
        let pixels = width * height
        if pixels >= 3840 * 2160 {
            return 90_000_000
        } else if pixels >= 1920 * 1080 {
            return 35_000_000
        } else {
            return 16_000_000
        }
    }
}

private struct SendableSampleBuffer: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
}

extension FileManager {
    func removeItemIfExists(at url: URL) throws {
        if fileExists(atPath: url.path) {
            try removeItem(at: url)
        }
    }
}
