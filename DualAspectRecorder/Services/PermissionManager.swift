import AVFoundation
import Photos

struct PermissionManager {
    func requestCameraAndMicrophone() async throws {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        guard camera else {
            throw AppError.permissionDenied("Camera access is required to record video.")
        }

        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphone else {
            throw AppError.permissionDenied("Microphone access is required to capture synchronized audio.")
        }
    }

    func requestPhotoAddAccess() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw AppError.permissionDenied("Photos access is required to save exported videos.")
        }
    }
}
