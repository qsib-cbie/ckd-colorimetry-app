import CKDDocument
import CKDResults
import XCTest

final class LargeImageUITests: XCTestCase {
    private var fixtures: URL { TestFiles.fixtures }
    private var large: URL { TestFiles.large }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func tapWhenEnabled(_ element: XCUIElement, timeout: TimeInterval = 600) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element)")
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: element)], timeout: timeout)
        element.tap()
    }

    private func mark(_ step: String, since start: Date) {
        print(String(format: "CKDLARGE %@ %.1f s at %.3f", step, Date().timeIntervalSince(start), Date().timeIntervalSince1970))
    }

    private func summaryText(_ summary: AnalyteSummary) -> String {
        let names = ["ph": "pH", "urea": "Urea", "creatinine": "Creatinine"]
        let value = summary.value.map { String(format: "%.3f", $0) + (summary.sd.map { " ± " + String(format: "%.3f", $0) } ?? "")
            + " " + (summary.unit == "uM" ? "µM" : summary.unit) } ?? "Not available"
        return "\(names[summary.analyte]!), \(value)"
    }

    private func doubled(_ value: JSONValue) -> JSONValue {
        if let pairs = value.objectPairs {
            if pairs.count == 2, let x = value["x"]?.doubleValue, let y = value["y"]?.doubleValue {
                return .object([("x", .double(x * 2 + 0.5)), ("y", .double(y * 2 + 0.5))])
            }
            return .object(pairs.map { ($0.0, doubled($0.1)) })
        }
        if let values = value.arrayValues { return .array(values.map(doubled)) }
        return value
    }

    func testProRAW48MegapixelWorkflowAndExport() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: large.path),
                          "Run ios/scripts/make_upscaled_dng.py api/tests/fixtures/iPhoneRAW.DNG tmp/large/ProRAW48.DNG first.")
        let mac = try AnalysisDocument(root: try JSONValue.parse(Data(contentsOf: fixtures.appendingPathComponent("mac_reference/pipeline/dng_standard24.json"))))
        let width = try XCTUnwrap(mac.width) * 2, height = try XCTUnwrap(mac.height) * 2
        let package = doubled(CoordinatePackage.export(mac))
            .setting("source_image_filename", .string(large.lastPathComponent))
            .setting("source_image_sha256", .string(try Digest.sha256(file: large)))
            .setting("image_dimensions", .object([("width", .int(width)), ("height", .int(height))]))

        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ckd-large-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let run = try ContractWorkflow.run(raw: large, coordinates: package, age: nil, sex: nil, classifierModel: nil, in: workspace)
        let expected = ConcentrationResults(stored: try XCTUnwrap(run.document["results"]))
        let pairs = zip(run.document.roiMeasurements, mac.roiMeasurements)
        let largest = pairs.flatMap { zip($0.calibratedMedian, $1.calibratedMedian).map { abs($0 - $1) } }.max() ?? .infinity
        print(String(format: "CKDLARGE roi_lab_difference %.4f over %d ROIs", largest, mac.roiMeasurements.count))
        XCTAssertEqual(run.document.roiMeasurements.count, mac.roiMeasurements.count)
        XCTAssertLessThan(largest, 1.0, "48 MP calibrated ROI medians stay within 1 L*a*b* unit of the 12 MP originals")

        let app = XCUIApplication()
        app.launchEnvironment = ["CKD_UI_TEST_RESET": "1", "CKD_UI_TEST_RAW": TestFiles.appPath(large), "CKD_UI_TEST_COORDINATES": package.prettyJSON()]
        app.launch()
        tapWhenEnabled(app.buttons["library.analysis.ProRAW48"], timeout: 60)
        var start = Date()
        tapWhenEnabled(app.buttons["action.render"])
        XCTAssertTrue(app.buttons["action.whiteBalance"].waitForExistence(timeout: 600))
        mark("render", since: start)
        tapWhenEnabled(app.buttons["analysis.menu"])
        tapWhenEnabled(app.buttons["test.importCoordinates"])
        start = Date()
        tapWhenEnabled(app.buttons["action.whiteBalance"])
        XCTAssertTrue(app.buttons["action.calibrate"].waitForExistence(timeout: 600))
        mark("white_balance", since: start)
        start = Date()
        tapWhenEnabled(app.buttons["action.calibrate"])
        XCTAssertTrue(app.buttons["action.analyze"].waitForExistence(timeout: 600))
        mark("calibrate", since: start)
        start = Date()
        tapWhenEnabled(app.buttons["action.analyze"])
        let first = app.staticTexts.matching(NSPredicate(format: "identifier IN %@", ["result.prediction", "result.summary.ph"])).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 600))
        mark("analyze", since: start)
        for summary in expected.summaries {
            let text = app.staticTexts["result.summary.\(summary.analyte)"]
            XCTAssertTrue(text.waitForExistence(timeout: 10), summary.analyte)
            XCTAssertEqual(text.label, summaryText(summary))
        }
        tapWhenEnabled(app.buttons["analysis.menu"])
        start = Date()
        tapWhenEnabled(app.buttons["analysis.export"])
        let ready = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Export ready: ProRAW48_'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 600))
        mark("export", since: start)
        Thread.sleep(forTimeInterval: 2)
    }
}
