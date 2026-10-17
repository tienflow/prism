import XCTest
@testable import Prism

final class ReferenceImageImporterTests: XCTestCase {

    func testSupportedExtensionsAccepted() {
        for ext in ["png", "jpg", "jpeg", "heic", "tif", "tiff", "bmp", "gif", "webp"] {
            let url = URL(fileURLWithPath: "/tmp/ref.\(ext)")
            XCTAssertTrue(ReferenceImageImporter.isSupportedImage(url), "应当支持 .\(ext)")
        }
    }

    func testUppercaseExtensionAccepted() {
        let url = URL(fileURLWithPath: "/tmp/REF.PNG")
        XCTAssertTrue(ReferenceImageImporter.isSupportedImage(url))
    }

    func testUnsupportedExtensionsRejected() {
        for ext in ["txt", "pdf", "mp4", "zip", ""] {
            let url = URL(fileURLWithPath: "/tmp/file.\(ext)")
            XCTAssertFalse(ReferenceImageImporter.isSupportedImage(url), "不应接受 .\(ext)")
        }
    }
}
