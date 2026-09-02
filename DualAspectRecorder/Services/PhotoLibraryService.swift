import Foundation
import Photos

struct PhotoLibraryService {
    private let permissions = PermissionManager()

    func save(_ videos: ExportedVideos) async throws {
        try await permissions.requestPhotoAddAccess()

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videos.landscapeURL)
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videos.portraitURL)
        }
    }
}
