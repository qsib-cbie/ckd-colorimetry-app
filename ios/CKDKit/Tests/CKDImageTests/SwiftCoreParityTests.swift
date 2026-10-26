import Foundation
import XCTest
@testable import CKDImage

final class SwiftCoreParityTests: XCTestCase {
    private let swiftLab = 0.01

    func testSampleCR2Standard24() throws { try assertCalibratedROIs("SampleImg1.CR2", inputs: "inputs", expected: "expected") }
    func testIPhoneDNGStandard24() throws { try assertCalibratedROIs("iPhoneRAW.DNG", inputs: "inputs", expected: "expected") }
    func testSyntheticFlower() throws { try assertCalibratedROIs("_NOT_ACTUAL_TEST.dng", inputs: "inputs", expected: "expected") }
    func testSyntheticFlowerManual() throws {
        try assertCalibratedROIs("_NOT_ACTUAL_TEST.dng", inputs: "manual_inputs", expected: "manual_expected")
    }

    func testFitsOnIdenticalLab() throws {
        let units = try Fixtures.json("swift_core/units.json")
        for case let item as [String: Any] in units["fits"] as? [Any] ?? [] {
            let input = item["input"] as? [String: Any] ?? [:]
            let measured = labs(input["measured"])
            let reference = labs(input["reference"])
            let coefficients = QCamMath.abAffineCoefficients(measured: measured, reference: reference)
            if item["coefficients"] is NSNull {
                XCTAssertNil(coefficients)
                continue
            }
            let expected = item["coefficients"] as? [[Any]] ?? []
            XCTAssertEqual(coefficients?.count, expected.count)
            for (row, values) in zip(coefficients ?? [], expected) {
                assertValues(row, values, tolerance: 1e-10, "fit")
            }
        }
    }

    func testSamplingOnSyntheticBuffers() throws {
        let units = try Fixtures.json("swift_core/units.json")
        for case let item as [String: Any] in units["sampling"] as? [Any] ?? [] {
            let input = item["input"] as? [String: Any] ?? [:]
            let expected = item["expected"] as? [String: Any] ?? [:]
            let rgb = input["rgb"] as? [[Int]] ?? []
            let bytes = rgb.flatMap { $0.map { UInt8($0) } + [UInt8(255)] }
            let image = QCamRGBAImage(
                width: input["width"] as? Int ?? 0,
                height: input["height"] as? Int ?? 0,
                data: Data(bytes)
            )
            let polygon = try Fixtures.decode(input["polygon"], as: QCamPolygon.self)
            let stats = try image.labStats(for: polygon, sampling: .boundaryInclusivePolygon)
            let mean = try image.rgbMean(for: polygon, sampling: .boundaryInclusivePolygon)
            XCTAssertEqual(stats.pixelCount, expected["pixel_count"] as? Int)
            assertRGB(mean, expected["rgb_mean"], tolerance: 1e-12, "rgb mean")
            assertLab(stats.median, expected["median"], tolerance: swiftLab, "median")
            assertLab(stats.mean, expected["mean"], tolerance: swiftLab, "mean")
            assertLab(stats.standardDeviation, expected["standard_deviation"], tolerance: swiftLab, "sd")
        }
    }

    private func assertCalibratedROIs(_ name: String, inputs inputsKey: String, expected expectedKey: String) throws {
        let reference = try Fixtures.json("swift_core/\(name).json")
        let inputs = reference[inputsKey] as? [String: Any] ?? [:]
        let expected = reference[expectedKey] as? [String: Any] ?? [:]
        let image = try RenderedFixture.named(name).balanced.image

        let calibration: QCamCalibration
        switch inputs["mode"] as? String {
        case "flower_9_manual":
            calibration = try QCamCalibration.calibrateFlower9(
                buffer: image,
                manualPolygons: try Fixtures.decode(inputs["manual"], as: [QCamPolygon].self)
            )
        case "flower_9":
            calibration = try QCamCalibration.calibrate(
                buffer: image,
                corners: try Fixtures.decode(inputs["corners"], as: [QCamPoint].self),
                markerKind: .flower9
            )
        default:
            calibration = try QCamCalibration.calibrate(
                buffer: image,
                corners: try Fixtures.decode(inputs["corners"], as: [QCamPoint].self),
                markerKind: .standard24
            )
        }
        let expectedCalibration = expected["calibration"] as? [String: Any] ?? [:]
        let expectedCoefficients = expectedCalibration["coefficients"] as? [[Any]] ?? []
        XCTAssertEqual(calibration.coefficients.count, expectedCoefficients.count)
        for (row, values) in zip(calibration.coefficients, expectedCoefficients) {
            assertValues(row, values, tolerance: swiftLab, "\(name) coefficients")
        }
        assertClose(calibration.rmse, expectedCalibration["rmse"], tolerance: swiftLab, "\(name) rmse")
        XCTAssertEqual(calibration.orientationLabel, expectedCalibration["orientation"] as? String)
        XCTAssertEqual(calibration.patchOrderLabel, expectedCalibration["patch_order"] as? String)

        let rois = try Fixtures.decode(inputs["rois"], as: [QCamROI].self)
        let results = try QCamAnalysisPipeline.analyzeROIs(image: image, calibration: calibration, rois: rois)
        let expectedResults = (expected["results"] as? [String: Any])?["roi_results"] as? [[String: Any]] ?? []
        XCTAssertEqual(results.count, expectedResults.count)
        for (actual, expectedROI) in zip(results, expectedResults) {
            XCTAssertEqual(actual.roiID, expectedROI["roi_id"] as? Int)
            XCTAssertEqual(actual.pixelCount, expectedROI["pixel_count"] as? Int)
            assertLab(actual.rawMedian, expectedROI["raw_median"], tolerance: swiftLab, "ROI \(actual.roiID) raw median")
            assertLab(actual.rawMean, expectedROI["raw_mean"], tolerance: swiftLab, "ROI \(actual.roiID) raw mean")
            assertLab(actual.rawStandardDeviation, expectedROI["raw_standard_deviation"], tolerance: swiftLab, "ROI \(actual.roiID) raw SD")
            assertLab(actual.calibratedMedian, expectedROI["calibrated_median"], tolerance: swiftLab, "ROI \(actual.roiID) calibrated median")
            assertLab(actual.calibratedMean, expectedROI["calibrated_mean"], tolerance: swiftLab, "ROI \(actual.roiID) calibrated mean")
        }
    }

    private func labs(_ value: Any?) -> [QCamLab] {
        (value as? [[Any]] ?? []).map {
            QCamLab(lStar: number($0[0]), aStar: number($0[1]), bStar: number($0[2]))
        }
    }
}
