import AVFoundation
import UIKit

protocol CameraManagerDelegate: AnyObject {
    func cameraManagerDidStopUnexpectedly(_ manager: CameraManager, message: String)
}

final class CameraManager: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    weak var delegate: CameraManagerDelegate?

    private let sessionQueue = DispatchQueue(label: "DualAspectRecorder.CameraSession")
    private let videoQueue = DispatchQueue(label: "DualAspectRecorder.VideoOutput", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "DualAspectRecorder.AudioOutput", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var currentPosition: CapturePosition = .back
    private var writer: RecordingWriter?
    private var latestVideoFormat: CMFormatDescription?
    private var latestAudioFormat: CMFormatDescription?
    private var currentOrientation: RecordingOrientation = .portrait
    private var isConfigured = false

    override init() {
        super.init()
        observeSessionNotifications()
    }

    func configure(position: CapturePosition = .back) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    try self.configureLocked(position: position)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func startSession() {
        sessionQueue.async {
            guard self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stopSession() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func switchCamera() async throws -> CapturePosition {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                let next: CapturePosition = self.currentPosition == .back ? .front : .back
                do {
                    try self.setCameraLocked(position: next)
                    continuation.resume(returning: next)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func updateOrientation(_ orientation: UIDeviceOrientation) {
        let recordingOrientation: RecordingOrientation
        switch orientation {
        case .landscapeLeft:
            recordingOrientation = .landscapeRight
        case .landscapeRight:
            recordingOrientation = .landscapeLeft
        case .portraitUpsideDown:
            recordingOrientation = .portraitUpsideDown
        default:
            recordingOrientation = .portrait
        }

        sessionQueue.async {
            self.currentOrientation = recordingOrientation
        }
    }

    func startRecording() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    guard self.writer == nil else { throw AppError.cannotStartRecording("A recording is already active.") }
                    guard let latestVideoFormat = self.latestVideoFormat else {
                        throw AppError.cannotStartRecording("The camera has not produced a video frame yet.")
                    }
                    let url = Self.makeOutputURL(prefix: "master", extension: "mov")
                    let writer = RecordingWriter(outputURL: url)
                    try writer.start(videoFormat: latestVideoFormat, audioFormat: self.latestAudioFormat)
                    self.writer = writer
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stopRecording() async throws -> URL {
        let writer = await withCheckedContinuation { continuation in
            sessionQueue.async {
                let writer = self.writer
                self.writer = nil
                continuation.resume(returning: writer)
            }
        }
        guard let writer else { throw AppError.cannotFinishRecording }
        return try await writer.finish()
    }

    private func configureLocked(position: CapturePosition) throws {
        guard !isConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .hd4K3840x2160
        try setCameraLocked(position: position)
        try setMicrophoneLocked()
        configureOutputsLocked()
        session.commitConfiguration()
        isConfigured = true
    }

    private func setCameraLocked(position: CapturePosition) throws {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: position.avPosition
        )

        guard let device = discovery.devices.first ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position.avPosition) else {
            throw AppError.cameraUnavailable
        }

        try configureDeviceFor4K60(device)
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        if let videoInput {
            session.removeInput(videoInput)
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw AppError.cannotConfigureSession("Video input cannot be added.")
        }
        session.addInput(input)
        videoInput = input
        currentPosition = position
        session.commitConfiguration()
    }

    private func setMicrophoneLocked() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw AppError.microphoneUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw AppError.cannotConfigureSession("Audio input cannot be added.")
        }
        session.addInput(input)
        audioInput = input
    }

    private func configureOutputsLocked() {
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        applyRotation(to: videoOutput.connection(with: .video))
        videoOutput.connection(with: .video)?.isVideoMirrored = currentPosition == .front

        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
    }

    private func configureDeviceFor4K60(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        var selected: AVCaptureDevice.Format?
        var selectedFrameRate: Double = 0

        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width >= 3840, dimensions.height >= 2160 else { continue }
            let ranges = format.videoSupportedFrameRateRanges
            let maxFrameRate = ranges.map(\.maxFrameRate).max() ?? 0
            if maxFrameRate > selectedFrameRate {
                selected = format
                selectedFrameRate = maxFrameRate
            }
        }

        if let selected {
            device.activeFormat = selected
            let fps = min(selectedFrameRate, 60)
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
        }

        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = true
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    private func observeSessionNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterrupted(_:)), name: AVCaptureSession.wasInterruptedNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError(_:)), name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    @objc private func sessionInterrupted(_ notification: Notification) {
        delegate?.cameraManagerDidStopUnexpectedly(self, message: "Camera session was interrupted.")
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        delegate?.cameraManagerDidStopUnexpectedly(self, message: error?.localizedDescription ?? "Camera runtime error.")
    }

    private static func makeOutputURL(prefix: String, extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoOutput {
            applyRotation(to: connection)
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = currentPosition == .front
            }
            latestVideoFormat = CMSampleBufferGetFormatDescription(sampleBuffer)
            writer?.appendVideo(sampleBuffer, transform: currentOrientation.transform(mirrored: currentPosition == .front))
        } else if output == audioOutput {
            latestAudioFormat = CMSampleBufferGetFormatDescription(sampleBuffer)
            writer?.appendAudio(sampleBuffer)
        }
    }

    private func applyRotation(to connection: AVCaptureConnection?) {
        guard let connection, connection.isVideoRotationAngleSupported(currentOrientation.rotationAngle) else { return }
        connection.videoRotationAngle = currentOrientation.rotationAngle
    }
}

private enum RecordingOrientation {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    var rotationAngle: CGFloat {
        switch self {
        case .portrait: 90
        case .portraitUpsideDown: 270
        case .landscapeLeft: 180
        case .landscapeRight: 0
        }
    }

    func transform(mirrored: Bool) -> CGAffineTransform {
        var transform: CGAffineTransform
        switch self {
        case .portrait:
            transform = CGAffineTransform(rotationAngle: .pi / 2)
        case .portraitUpsideDown:
            transform = CGAffineTransform(rotationAngle: -.pi / 2)
        case .landscapeRight:
            transform = .identity
        case .landscapeLeft:
            transform = CGAffineTransform(rotationAngle: .pi)
        }

        if mirrored {
            transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1))
        }
        return transform
    }
}
