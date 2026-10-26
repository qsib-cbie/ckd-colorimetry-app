import CKDImage
import Foundation
import XCTest

final class JPEGXLTests: XCTestCase {
    func testJPEGXLDNGsAreExplainedInsteadOfRendered() throws {
        var data = try Data(contentsOf: Fixtures.directory.appendingPathComponent("iPhoneRAW.DNG"))
        let losslessJPEG = Data([0x01, 0x03, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x07])
        var start = data.startIndex
        var patched = 0
        while let range = data.range(of: losslessJPEG, in: start..<data.endIndex) {
            data[range.upperBound - 2] = 0xCD
            data[range.upperBound - 1] = 0x42
            patched += 1
            start = range.upperBound
        }
        XCTAssertGreaterThan(patched, 0)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("jpeg-xl-\(UUID().uuidString).DNG")
        try data.write(to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        XCTAssertTrue(QCamRawImport.usesJPEGXL(url: copy))
        for name in ["iPhoneRAW.DNG", "SampleImg1.CR2", "_NOT_ACTUAL_TEST.dng"] {
            XCTAssertFalse(QCamRawImport.usesJPEGXL(url: Fixtures.directory.appendingPathComponent(name)), name)
        }
        XCTAssertThrowsError(try QCamRawImport.validate(url: copy)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("This DNG uses JPEG XL compression"), error.localizedDescription)
        }
        XCTAssertThrowsError(try QCamRawImport.render(url: copy)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("This DNG uses JPEG XL compression"), error.localizedDescription)
        }
    }
}
