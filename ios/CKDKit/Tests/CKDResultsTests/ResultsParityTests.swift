import Foundation
import XCTest
@testable import CKDResults

final class ResultsParityTests: XCTestCase {
    func testEveryCaseMatchesTheMacEngine() throws {
        let cases = try ResultsFixtures.cases()
        XCTAssertEqual(cases.count, 17)
        for item in cases {
            let name = item["name"] as? String ?? "?"
            let draft = try ResultsFixtures.decode(item["draft"], as: ResultsDraft.self)
            let rois = try ResultsFixtures.decode(item["rois"], as: [ROIMeasurement].self)
            let calibration = item["calibration"] is NSNull
                ? nil : try ResultsFixtures.decode(item["calibration"], as: CalibrationSummary.self)
            let identity = try ResultsFixtures.decode(item["identity"], as: AnalysisIdentity.self)
            let expected = try XCTUnwrap(item["expected"] as? [String: Any])

            let results = CKDConcentrations.compute(draft: draft, rois: rois, calibration: calibration)
            var mismatches: [Mismatch] = []
            Compare.json(results.json.foundationObject, try XCTUnwrap(expected["results"]), into: &mismatches)

            let tables = CKDTables.export(results, identity: identity)
            let expectedTables = try XCTUnwrap(expected["tables"] as? [String: String])
            XCTAssertEqual(Set(tables.keys), Set(expectedTables.keys), name)
            for (table, text) in expectedTables.sorted(by: { $0.key < $1.key }) {
                Compare.csv(tables[table] ?? "", text, name: table, into: &mismatches)
            }
            XCTAssertTrue(mismatches.isEmpty, "\(name): \(mismatches.count) mismatches\n"
                          + mismatches.prefix(12).map(\.description).joined(separator: "\n"))
        }
    }

    func testPythonFloatFormatting() {
        let cases: [(Double, String)] = [
            (1.0, "1.0"), (-2.5, "-2.5"), (0.1, "0.1"), (1e-05, "1e-05"), (0.0001, "0.0001"), (1e16, "1e+16"),
            (1e15, "1000000000000000.0"), (123456789.125, "123456789.125"), (6.604903476320032, "6.604903476320032"),
            (-0.0, "-0.0"), (5e-324, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"),
            (0.30000000000000004, "0.30000000000000004"), (2.5e-05, "2.5e-05"),
        ]
        for (value, text) in cases {
            XCTAssertEqual(PythonFormat.float(value), text)
        }
    }

    func testCSVQuotingAndFormulaPrefix() {
        let text = CSVText.make(fields: ["a", "b"], rows: [
            [.text("=SUM(1)"), .text("plain, \"quoted\"\nline")],
            [.text("  -x"), .double(-1.5)],
        ])
        XCTAssertEqual(text, "a,b\r\n'=SUM(1),\"plain, \"\"quoted\"\"\nline\"\r\n'  -x,-1.5\r\n")
    }
}
