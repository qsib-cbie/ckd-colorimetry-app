import Foundation
import XCTest
@testable import CKDImage

final class RasterParityTests: XCTestCase {
    func testSampleCR2() throws { try assertRasterPipeline("SampleImg1.CR2") }
    func testIPhoneDNG() throws { try assertRasterPipeline("iPhoneRAW.DNG") }
    func testSyntheticFlowerDNG() throws { try assertRasterPipeline("_NOT_ACTUAL_TEST.dng") }

    private func assertRasterPipeline(_ name: String) throws {
        let reference = try Fixtures.json("swift_core/\(name).json")
        let rendered = try RenderedFixture.named(name)
        let initial = rendered.initial
        let balanced = rendered.balanced
        let firstPassHash: String? = rendered.firstPassHash
        XCTAssertEqual(Fixtures.sha256(initial.image.data), reference["initial_rgba_sha256"] as? String, "initial raster")
        XCTAssertEqual([initial.image.width, initial.image.height], reference["dimensions"] as? [Int])
        assertValues(initial.cameraWhiteBalance, reference["camera_whitebalance"], tolerance: 0, "camera white balance")

        let firstPass = reference["first_pass"] as? [String: Any]
        let secondPass = reference["second_pass"] as? [String: Any]
        assertRGB(balanced.initialMean, firstPass?["mean"], tolerance: 1e-12, "initial mean")
        assertValues(balanced.firstPassWhiteBalance, firstPass?["multipliers"], tolerance: 1e-12, "first pass multipliers")
        XCTAssertEqual(firstPassHash, reference["first_pass_rgba_sha256"] as? String, "first pass raster")
        assertRGB(balanced.firstPassMean, secondPass?["mean"], tolerance: 1e-12, "first pass mean")
        assertValues(balanced.explicitWhiteBalance, secondPass?["multipliers"], tolerance: 1e-12, "final multipliers")
        assertClose(balanced.brightness, secondPass?["brightness"], tolerance: 1e-12, "brightness")
        XCTAssertEqual(Fixtures.sha256(balanced.image.data), reference["final_rgba_sha256"] as? String, "final raster")
    }
}
