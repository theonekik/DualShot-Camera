import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class CameraViewModel: NSObject, ObservableObject {
    @Published private(set) var state: RecorderState = .preparing
    @Published private(set) var statusText = "Preparing camera"
    @Published private(set) var exportProgress: Double = 0
    @Published private(set) var elapsedTime = "00:00"
    @Published private(set) var cameraPosition: CapturePosition = .back
    @Published private(set) var qualityLabel = "4K HEVC master"

    let captureSession: AVCaptureSession

    private let cameraManager = CameraManager()
    private let permissionManager = PermissionManager()
    private let exportService = ExportService()
    private let photoLibraryService = PhotoLibraryService()
    private let thermalMonitor = ThermalMonitor()
    private var recordingStartedAt: Date?
    private var timerTask: Task<Void, Never>?

    var isRecording: Bool {
        state == .recording
    }

    var canRecord: Bool {
        switch state {
        case .ready, .recording:
            true
        default:
            false
        }
    }

    var canSwitchCamera: Bool {
        state == .ready
    }

    override init() {
        captureSession = cameraManager.session
        super.init()
        cameraManager.delegate = self
    }

    func prepare() async {
        guard case .preparing = state else { return }
        do {
            try await permissionManager.requestCameraAndMicrophone()
            try await cameraManager.configure(position: .back)
            cameraManager.startSession()
            startOrientationMonitoring()
            state = .ready
            statusText = "Frame once. Get both formats."
        } catch {
            setFailure(error)
        }
    }

    func handleScenePhase(_ scenePhase: ScenePhase) async {
        switch scenePhase {
        case .active:
            cameraManager.startSession()
        case .background:
            if isRecording {
                await stopAndProcessRecording()
            }
            cameraManager.stopSession()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func switchCamera() async {
        guard canSwitchCamera else { return }
        do {
            cameraPosition = try await cameraManager.switchCamera()
            statusText = "\(cameraPosition.rawValue) camera"
        } catch {
            setFailure(error)
        }
    }

    func toggleRecording() async {
        if isRecording {
            await stopAndProcessRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        guard canRecord else { return }
        if thermalMonitor.shouldReduceLoad {
            statusText = "Device is warm. Recording will continue, but keep takes shorter."
        }

        do {
            state = .recording
            exportProgress = 0
            recordingStartedAt = Date()
            elapsedTime = "00:00"
            startTimer()
            try await cameraManager.startRecording()
            statusText = ""
        } catch {
            stopTimer()
            recordingStartedAt = nil
            setFailure(error)
        }
    }

    private func stopAndProcessRecording() async {
        guard isRecording else { return }
        stopTimer()
        state = .exporting(progress: 0)
        statusText = "Finalizing master"

        do {
            let masterURL = try await cameraManager.stopRecording()
            statusText = "Exporting 16:9 and 9:16"
            let videos = try await exportService.exportBoth(from: masterURL) { [weak self] progress in
                Task { @MainActor in
                    self?.exportProgress = progress.combined
                    self?.state = .exporting(progress: progress.combined)
                }
            }
            statusText = "Saving to Photos"
            try await photoLibraryService.save(videos)
            state = .saved(videos)
            exportProgress = 1
            statusText = "Saved landscape and portrait videos"
            recordingStartedAt = nil
        } catch {
            setFailure(error)
        }
    }

    private func setFailure(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if case AppError.permissionDenied = error {
            state = .permissionDenied(message)
        } else {
            state = .failed(message)
        }
        statusText = message
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    self?.updateElapsedTime()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func updateElapsedTime() {
        guard let recordingStartedAt else { return }
        let seconds = max(0, Int(Date().timeIntervalSince(recordingStartedAt)))
        elapsedTime = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func startOrientationMonitoring() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        cameraManager.updateOrientation(UIDevice.current.orientation)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    @objc private func deviceOrientationDidChange() {
        cameraManager.updateOrientation(UIDevice.current.orientation)
    }
}

extension CameraViewModel: CameraManagerDelegate {
    nonisolated func cameraManagerDidStopUnexpectedly(_ manager: CameraManager, message: String) {
        Task { @MainActor in
            if self.isRecording {
                self.stopTimer()
            }
            self.state = .failed(message)
            self.statusText = message
        }
    }
}
