import XCTest
@testable import DualAspectRecorder

final class DualAspectRecorderTests: XCTestCase {
    func testLandscapeExportAspectRatio() {
        XCTAssertEqual(ExportAspect.landscape.renderSize.width / ExportAspect.landscape.renderSize.height, 16.0 / 9.0, accuracy: 0.001)
    }

    func testPortraitExportAspectRatio() {
        XCTAssertEqual(ExportAspect.portrait.renderSize.width / ExportAspect.portrait.renderSize.height, 9.0 / 16.0, accuracy: 0.001)
    }

    func testCenterCropFillsRenderCanvas() {
        let transform = ExportService.centerCropTransform(
            naturalSize: CGSize(width: 3840, height: 2160),
            preferredTransform: .identity,
            renderSize: ExportAspect.portrait.renderSize
        )
        let transformed = CGRect(x: 0, y: 0, width: 3840, height: 2160).applying(transform)
        XCTAssertLessThanOrEqual(transformed.minX, 0.1)
        XCTAssertGreaterThanOrEqual(transformed.maxX, ExportAspect.portrait.renderSize.width - 0.1)
        XCTAssertEqual(transformed.height, ExportAspect.portrait.renderSize.height, accuracy: 0.1)
    }
}
