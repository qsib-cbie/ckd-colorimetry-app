import CKDDocument
import CKDResults
import XCTest

final class WorkflowUITests: XCTestCase {
    private let fixtures = TestFiles.fixtures

    private var raw: URL { fixtures.appendingPathComponent("_NOT_ACTUAL_TEST.dng") }
    private var coordinates: URL { fixtures.appendingPathComponent("synthetic-flower-coordinates.json") }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CKD_UI_TEST_RESET": "1",
            "CKD_UI_TEST_RAW": TestFiles.appPath(raw),
            "CKD_UI_TEST_COORDINATES": try String(contentsOf: coordinates, encoding: .utf8),
        ]
        app.launch()
        return app
    }

    private func tapWhenEnabled(_ element: XCUIElement, timeout: TimeInterval = 60, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) missing", file: file, line: line)
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: element)
        wait(for: [enabled], timeout: timeout)
        element.tap()
    }

    private func expectedSummaries() throws -> [String: String] {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ckd-ui-expected-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let run = try ContractWorkflow.run(raw: raw, coordinates: try JSONValue.parse(Data(contentsOf: coordinates)),
                                           age: nil, sex: nil, classifierModel: nil, in: workspace)
        let results = ConcentrationResults(stored: try XCTUnwrap(run.document["results"]))
        var out: [String: String] = [:]
        for summary in results.summaries {
            guard let value = summary.value else { out[summary.analyte] = "Not available"; continue }
            let unit = summary.unit == "uM" ? "µM" : summary.unit
            out[summary.analyte] = String(format: "%.3f", value) + (summary.sd.map { " ± " + String(format: "%.3f", $0) } ?? "") + " \(unit)"
        }
        return out
    }

    func testRenderIsRefusedWhenMemoryIsShort() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["CKD_UI_TEST_RESET": "1", "CKD_UI_TEST_RAW": TestFiles.appPath(raw), "CKD_UI_TEST_AVAILABLE_MEMORY_MB": "100"]
        app.launch()
        tapWhenEnabled(app.buttons["library.analysis._NOT_ACTUAL_TEST"], timeout: 20)
        tapWhenEnabled(app.buttons["action.render"])
        let needed = (try MemoryBudget.required(for: raw, holdsImage: false) + 1_048_575) / 1_048_576
        let message = app.staticTexts.matching(identifier: "banner.text")
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS 'about 100 MB free'",
                                  "This image needs about \(needed) MB of memory to process")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Render the RAW image"].exists)
        XCTAssertTrue(app.buttons["action.render"].isEnabled)
    }

    func testOpeningARawFileRendersAndRunsToAnExport() throws {
        let expected = try expectedSummaries()
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CKD_UI_TEST_RESET": "1",
            "CKD_UI_TEST_OPEN_RAW": TestFiles.appPath(raw),
            "CKD_UI_TEST_COORDINATES": try String(contentsOf: coordinates, encoding: .utf8),
        ]
        app.launch()

        XCTAssertTrue(app.buttons["action.whiteBalance"].waitForExistence(timeout: 120), "rendering starts on its own after import")
        XCTAssertFalse(app.buttons["action.render"].exists)
        tapWhenEnabled(app.buttons["analysis.menu"])
        tapWhenEnabled(app.buttons["test.importCoordinates"])
        tapWhenEnabled(app.buttons["action.whiteBalance"], timeout: 120)
        tapWhenEnabled(app.buttons["action.calibrate"], timeout: 120)
        tapWhenEnabled(app.buttons["action.analyze"], timeout: 120)
        for (analyte, name) in [("ph", "pH"), ("urea", "Urea"), ("creatinine", "Creatinine")] {
            let text = app.staticTexts["result.summary.\(analyte)"]
            XCTAssertTrue(text.waitForExistence(timeout: 60), analyte)
            XCTAssertEqual(text.label, "\(name), \(expected[analyte] ?? "")", analyte)
        }

        tapWhenEnabled(app.buttons["analysis.menu"])
        tapWhenEnabled(app.buttons["analysis.export"])
        let ready = app.staticTexts.matching(identifier: "banner.text").matching(NSPredicate(format: "label BEGINSWITH 'Export ready:'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 60))
        attach(app, "export")
    }

    private func importThroughFiles(_ file: URL, menu: String) throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The Files picker positions are for the iPad layout")
        try XCTSkipIf(TestFiles.onDevice, "The Files picker lists other apps' folders on a device, so its positions differ")
        let app = XCUIApplication()
        app.launchEnvironment = ["CKD_UI_TEST_RESET": "1", "CKD_UI_TEST_STAGE_FILE": TestFiles.appPath(file)]
        app.launch()
        tapWhenEnabled(app.buttons["library.add"], timeout: 20)
        tapWhenEnabled(app.buttons[menu], timeout: 5)
        let screen = app.coordinate(withNormalizedOffset: .zero)
        for x in [123.0, 515, 395, 395] {
            sleep(3)
            screen.withOffset(CGVector(dx: x, dy: x == 123 ? 324 : 174)).tap()
        }
        return app
    }

    func testImportRawThroughFilesStartsProcessing() throws {
        let app = try importThroughFiles(raw, menu: "Import RAW…")
        XCTAssertTrue(app.buttons["action.whiteBalance"].waitForExistence(timeout: 120), "rendering starts on its own after a Files import")
        XCTAssertFalse(app.buttons["action.render"].exists)
    }

    func testImportExportZipThroughFiles() throws {
        let zip = fixtures.appendingPathComponent("mac_reference/contract/mac_export.zip")
        let app = try importThroughFiles(zip, menu: "Import export ZIP…")
        XCTAssertTrue(app.staticTexts["result.summary.ph"].waitForExistence(timeout: 60))
    }

    func testFullWorkflowMatchesCKDKitAndDrawsROIs() throws {
        let expected = try expectedSummaries()
        let app = try launch()
        tapWhenEnabled(app.buttons["library.analysis._NOT_ACTUAL_TEST"], timeout: 20)

        tapWhenEnabled(app.buttons["action.render"])
        XCTAssertTrue(app.buttons["action.whiteBalance"].waitForExistence(timeout: 60))
        tapWhenEnabled(app.buttons["analysis.menu"])
        tapWhenEnabled(app.buttons["test.importCoordinates"])
        tapWhenEnabled(app.buttons["action.whiteBalance"])
        tapWhenEnabled(app.buttons["action.calibrate"])
        tapWhenEnabled(app.buttons["action.analyze"])

        for (analyte, name) in [("ph", "pH"), ("urea", "Urea"), ("creatinine", "Creatinine")] {
            let text = app.staticTexts["result.summary.\(analyte)"]
            XCTAssertTrue(text.waitForExistence(timeout: 60), analyte)
            XCTAssertEqual(text.label, "\(name), \(expected[analyte] ?? "")", analyte)
        }
        attach(app, "results")

        app.buttons["Reservoirs"].tap()
        tapWhenEnabled(app.buttons["tool.rectangle"])
        let canvas = app.descendants(matching: .any)["canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.30))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.36, dy: 0.36))
        start.press(forDuration: 0.2, thenDragTo: end)
        tapWhenEnabled(app.buttons["Continue"], timeout: 10)
        let picker = app.buttons["reservoir.picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let assigned = expectation(for: NSPredicate(format: "label ENDSWITH 'Reservoir 1 · pH · 2 ROIs'"), evaluatedWith: picker)
        wait(for: [assigned], timeout: 10)
        attach(app, "reservoirs")

        app.buttons["Results"].tap()
        XCTAssertTrue(app.staticTexts["Analyze the reservoirs to see concentrations and the prediction."].waitForExistence(timeout: 10))
    }

    func testStandard24DNG() throws { try assertFixture("dng_standard24", raw: "iPhoneRAW.DNG") }
    func testStandard24CR2() throws { try assertFixture("cr2_standard24", raw: "SampleImg1.CR2") }
    func testFlowerAutomatic() throws { try assertFixture("dng_flower_auto", raw: "_NOT_ACTUAL_TEST.dng") }
    func testFlowerManual() throws { try assertFixture("dng_flower_manual", raw: "_NOT_ACTUAL_TEST.dng") }

    private func assertFixture(_ label: String, raw name: String) throws {
        let mac = try AnalysisDocument(root: try JSONValue.parse(Data(contentsOf: fixtures.appendingPathComponent("mac_reference/pipeline/\(label).json"))))
        let package = CoordinatePackage.export(mac)
        let rawFile = fixtures.appendingPathComponent(name)

        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ckd-ui-expected-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let run = try ContractWorkflow.run(raw: rawFile, coordinates: try JSONValue.parse(Data(package.prettyJSON().utf8)),
                                           age: nil, sex: nil, classifierModel: nil, in: workspace)
        let expected = ConcentrationResults(stored: try XCTUnwrap(run.document["results"]))
        let reference = ConcentrationResults(stored: try XCTUnwrap(mac["results"]))
        XCTAssertEqual(expected.summaries.map(\.analyte), reference.summaries.map(\.analyte), label)
        for (summary, macSummary) in zip(expected.summaries, reference.summaries) {
            XCTAssertEqual(summary.value == nil, macSummary.value == nil, "\(label) \(summary.analyte)")
            if let value = summary.value, let macValue = macSummary.value {
                XCTAssertEqual(value, macValue, accuracy: 1e-9, "\(label) \(summary.analyte) matches the Mac")
            }
        }

        let app = XCUIApplication()
        app.launchEnvironment = ["CKD_UI_TEST_RESET": "1", "CKD_UI_TEST_RAW": TestFiles.appPath(rawFile), "CKD_UI_TEST_COORDINATES": package.prettyJSON()]
        app.launch()
        tapWhenEnabled(app.buttons["library.analysis.\((name as NSString).deletingPathExtension)"], timeout: 20)
        tapWhenEnabled(app.buttons["action.render"])
        XCTAssertTrue(app.buttons["action.whiteBalance"].waitForExistence(timeout: 120))
        tapWhenEnabled(app.buttons["analysis.menu"])
        tapWhenEnabled(app.buttons["test.importCoordinates"])
        tapWhenEnabled(app.buttons["action.whiteBalance"], timeout: 120)
        tapWhenEnabled(app.buttons["action.calibrate"], timeout: 120)
        tapWhenEnabled(app.buttons["action.analyze"], timeout: 120)
        let firstResult = app.staticTexts.matching(NSPredicate(format: "identifier IN %@", ["result.prediction", "result.summary.ph"])).firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 120), label)
        let names = ["ph": "pH", "urea": "Urea", "creatinine": "Creatinine"]
        for summary in expected.summaries {
            let text = app.staticTexts["result.summary.\(summary.analyte)"]
            XCTAssertTrue(text.waitForExistence(timeout: 10), "\(label) \(summary.analyte)")
            let value = summary.value.map { String(format: "%.3f", $0) + (summary.sd.map { " ± " + String(format: "%.3f", $0) } ?? "")
                + " " + (summary.unit == "uM" ? "µM" : summary.unit) } ?? "Not available"
            XCTAssertEqual(text.label, "\(names[summary.analyte] ?? summary.analyte), \(value)", "\(label) \(summary.analyte)")
        }
        XCTAssertEqual(expected.summaries.isEmpty, !app.staticTexts["result.summary.ph"].exists, label)
        attach(app, label)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
