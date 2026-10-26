import Foundation
import XCTest
@testable import CKDImage

final class PythonLabParityTests: XCTestCase {
    func testSampleCR2AgainstLegacyPython() throws { try assertLegacyROIs("SampleImg1.CR2") }
    func testIPhoneDNGAgainstLegacyPython() throws { try assertLegacyROIs("iPhoneRAW.DNG") }

    func testSkimageConstants() {
        let cases: [([Double], [Double])] = [
            ([255, 255, 255], [100.0, -0.0024549378620508655, 0.004653421154054982]),
            ([255, 0, 0], [53.2405879437449, 80.0923082256922, 67.2027510444287]),
            ([10, 200, 30], [70.5001319946117, -70.51383107333548, 64.94083996261955]),
        ]
        for (rgb, expected) in cases {
            let lab = QCamMath.rgbToLab(red: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255)
            assertValues([lab.lStar, lab.aStar, lab.bStar], expected, tolerance: 1e-12, "rgb \(rgb)")
        }
    }

    private func assertLegacyROIs(_ name: String) throws {
        let legacy = try Fixtures.json("\(name)_full_color_analyzed_run.json")
        let image = try RenderedFixture.named(name).balanced.image
        let raster = (legacy["python_rendered_raster"] as? [String: Any])?["rendered_raster"] as? [String: Any]
        let rgba = raster?["rgba8888"] as? [String: Any]
        XCTAssertEqual(Fixtures.sha256(image.data), rgba?["sha256"] as? String, "legacy Python raster")

        var compared = 0
        for case let roi as [String: Any] in legacy["roi_measurements"] as? [Any] ?? [] {
            guard let stats = roi["lab_stats"] as? [String: Any],
                  let geometry = roi["geometry"] as? [String: Any] else { continue }
            let polygon = QCamPolygon(points: try Fixtures.decode(geometry["polygon"], as: [QCamPoint].self))
            let actual = try image.labStats(for: polygon, sampling: QCamAnalysisPipeline.roiSampling)
            XCTAssertEqual(actual.pixelCount, stats["pixel_count"] as? Int, "\(name) pixel count")
            assertLabArray(actual.median, stats["median"], "\(name) median")
            assertLabArray(actual.mean, stats["mean"], "\(name) mean")
            assertLabArray(actual.standardDeviation, stats["standard_deviation"], "\(name) SD")
            compared += 1
        }
        XCTAssertGreaterThan(compared, 0)
    }

    private func assertLabArray(_ actual: QCamLab, _ expected: Any?, _ label: String) {
        assertValues([actual.lStar, actual.aStar, actual.bStar], expected, tolerance: 1e-10, label)
    }
}
