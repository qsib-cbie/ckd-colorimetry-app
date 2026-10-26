import XCTest
@testable import CKDResults

final class InvalidIncludeTests: XCTestCase {
    private func results(review: String) -> ConcentrationResults {
        let draft = ResultsDraft(mode: "flower_9_manual",
                                 reservoirs: [ReservoirDraft(id: 1, analyte: "creatinine", roiIDs: [1], review: review)],
                                 age: 50, sex: "female")
        let roi = ROIMeasurement(id: 1, label: "ROI 1", median: nil, mean: nil, standardDeviation: nil, pixelCount: 100,
                                 calibratedMedian: [60, -40, -40], calibratedMean: [100, 100, 100])
        return CKDConcentrations.compute(draft: draft, rois: [roi], calibration: nil)
    }

    func testInvalidValuesStayOutUnlessAReviewerIncludesThem() {
        for review in ["needs_review", "excluded"] {
            let r = results(review: review)
            XCTAssertEqual(r.reservoirs[0].reviewStatus, "mathematically_invalid", review)
            XCTAssertNil(r.summary("creatinine")?.value, review)
        }
    }

    func testAnIncludedInvalidValueMatchesTheMac() throws {
        let r = results(review: "included")
        let reservoir = r.reservoirs[0]
        XCTAssertEqual(reservoir.calculation.calculationStatus, "invalid_domain")
        XCTAssertEqual(reservoir.reviewStatus, "included")
        XCTAssertTrue(reservoir.isIncluded)
        XCTAssertEqual(try XCTUnwrap(r.summary("creatinine")?.value), -38.88899565065882, accuracy: 1e-12)
        XCTAssertEqual(r.prediction.creatinineUM, reservoir.value)
        XCTAssertTrue(reservoir.calculation.warnings.contains(CKDEquations.invalidIncluded))
        let tables = CKDTables.export(r, identity: AnalysisIdentity(analysisID: "a", analysisTitle: "t", sourceFilename: "f.dng"))
        XCTAssertTrue(try XCTUnwrap(tables["08_notes.csv"]).contains("included by the reviewer"))
    }
}
