import CKDDocument
import CKDResults
import XCTest

final class ExchangeUITests: XCTestCase {
    private let fixtures = TestFiles.fixtures
    private var contract: URL { fixtures.appendingPathComponent("mac_reference/contract") }
    private var scratch: URL { TestFiles.scratch("ui-test-exchange") }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ environment: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["CKD_UI_TEST_RESET": "1"].merging(environment) { $1 }
        app.launch()
        return app
    }

    private func waitEnabled(_ element: XCUIElement, _ enabled: Bool = true, timeout: TimeInterval = 60) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element)")
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == %@", NSNumber(value: enabled)), evaluatedWith: element)], timeout: timeout)
    }

    private func summaryText(_ summary: AnalyteSummary) -> String {
        let names = ["ph": "pH", "urea": "Urea", "creatinine": "Creatinine"]
        let value = summary.value.map { String(format: "%.3f", $0) + (summary.sd.map { " ± " + String(format: "%.3f", $0) } ?? "")
            + " " + (summary.unit == "uM" ? "µM" : summary.unit) } ?? "Not available"
        return "\(names[summary.analyte]!), \(value)"
    }

    func testMacExportZipOpensWithMacResultsAndExportsAgain() throws {
        let mac = try AnalysisFolder(url: contract.appendingPathComponent("Mac analysis")).load()
        let expected = ConcentrationResults(stored: try XCTUnwrap(mac["results"]))
        let app = launch(["CKD_UI_TEST_IMPORT_ZIP": TestFiles.appPath(contract.appendingPathComponent("mac_export.zip"))])
        let row = app.buttons["library.analysis.\(mac.draft.title)"]
        waitEnabled(row, timeout: 20)
        row.tap()
        for summary in expected.summaries {
            let text = app.staticTexts["result.summary.\(summary.analyte)"]
            XCTAssertTrue(text.waitForExistence(timeout: 60), summary.analyte)
            XCTAssertEqual(text.label, summaryText(summary))
        }
        let banner = app.staticTexts.matching(identifier: "banner.text").matching(NSPredicate(format: "label BEGINSWITH 'Calculated on a Mac with CKD 2.1.0.'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["banner.recompute"].exists)

        waitEnabled(app.buttons["analysis.menu"])
        app.buttons["analysis.menu"].tap()
        waitEnabled(app.buttons["analysis.export"])
        app.buttons["analysis.export"].tap()
        let ready = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Export ready: \(mac.draft.title)_'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 60))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "share-sheet"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRecomputeResultsFromOlderEquations() throws {
        try XCTSkipIf(TestFiles.onDevice, "On a device the app cannot open the ZIP this test builds")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let workspace = scratch.appendingPathComponent("build-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let run = try ContractWorkflow.run(
            raw: fixtures.appendingPathComponent("_NOT_ACTUAL_TEST.dng"),
            coordinates: try JSONValue.parse(Data(contentsOf: fixtures.appendingPathComponent("synthetic-flower-coordinates.json"))),
            age: nil, sex: nil, classifierModel: nil, in: workspace
        )
        var older = run.document
        let results = try XCTUnwrap(older["results"])
        older.set("results", results.setting("versions", try XCTUnwrap(results["versions"]).setting("configuration", .string("older_equations"))))
        older = try run.folder.save(older, expectedRevision: older.revision)
        let zip = scratch.appendingPathComponent("older-equations.zip")
        try? FileManager.default.removeItem(at: zip)
        try ExportArchive.write(older, folder: run.folder, image: run.image, to: zip)

        let app = launch(["CKD_UI_TEST_IMPORT_ZIP": zip.path])
        let row = app.buttons["library.analysis._NOT_ACTUAL_TEST"]
        waitEnabled(row, timeout: 20)
        row.tap()
        let banner = app.staticTexts.matching(identifier: "banner.text")
            .matching(NSPredicate(format: "label CONTAINS 'The equations differ' AND label CONTAINS 'Reviews are locked'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 60))
        app.buttons["banner.differences"].tap()
        let summary = app.staticTexts["differences.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(summary.label.contains("The equations changed."), summary.label)
        XCTAssertTrue(app.descendants(matching: .any)["differences.version.configuration"].label.contains("older_equations"))
        let firstValue = app.descendants(matching: .any)["differences.value.0"]
        if !firstValue.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(firstValue.waitForExistence(timeout: 5))
        XCTAssertTrue(firstValue.label.contains("Unchanged"), firstValue.label)
        app.buttons["differences.recompute"].tap()
        XCTAssertTrue(app.buttons["banner.differences"].waitForNonExistence(timeout: 60))
        XCTAssertFalse(app.staticTexts.matching(identifier: "banner.text").matching(NSPredicate(format: "label CONTAINS 'Reviews are locked'")).firstMatch.exists)
        let expected = ConcentrationResults(stored: try XCTUnwrap(run.document["results"]))
        for summary in expected.summaries {
            XCTAssertEqual(app.staticTexts["result.summary.\(summary.analyte)"].label, summaryText(summary))
        }
        waitEnabled(app.buttons["analysis.menu"])
        app.buttons["analysis.menu"].tap()
        app.buttons["analysis.runs"].tap()
        let runs = app.descendants(matching: .any).matching(identifier: "runs.row")
        XCTAssertTrue(runs.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(runs.count, 2)
        XCTAssertTrue(runs.element(boundBy: 0).label.contains("Keeps the results it replaced"), runs.element(boundBy: 0).label)
        XCTAssertTrue(runs.element(boundBy: 1).label.hasPrefix("Imported results"), runs.element(boundBy: 1).label)
    }

    func testMacFolderImportAndDuplicateIDs() throws {
        let app = launch([
            "CKD_UI_TEST_IMPORT_FOLDER": TestFiles.appPath(contract.appendingPathComponent("Mac analysis")),
            "CKD_UI_TEST_IMPORT_ZIP": TestFiles.appPath(contract.appendingPathComponent("mac_export.zip")),
        ])
        let duplicates = app.staticTexts.matching(identifier: "library.duplicate")
        XCTAssertTrue(duplicates.firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(duplicates.count, 2)
        let rows = app.buttons.matching(identifier: "library.analysis.dng_flower_manual")
        XCTAssertEqual(rows.count, 2)
        rows.element(boundBy: 1).press(forDuration: 1.2)
        let menuItem = app.buttons["Give this copy its own ID"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 10))
        menuItem.tap()
        XCTAssertTrue(duplicates.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertEqual(rows.count, 2)
    }

    func testAcknowledgementsShowTheLibRawNotice() throws {
        let app = launch([:])
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let link = app.buttons["settings.acknowledgements"]
        if !link.waitForExistence(timeout: 3) { app.swipeUp() }
        link.tap()
        app.buttons["acknowledgements.LibRaw"].tap()
        let text = app.staticTexts["license.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(text.label.contains("Common Development and Distribution License"), text.label)
        XCTAssertTrue(text.label.contains("b860248a89d9082b8e0a1e202e516f46af9adb29"))
    }

    private func brightness(_ app: XCUIApplication) -> Double {
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(app.screenshot().image.cgImage!, in: CGRect(x: 0, y: 0, width: size, height: size))
        let luminance = stride(from: 0, to: pixels.count, by: 4).map {
            0.2126 * Double(pixels[$0]) + 0.7152 * Double(pixels[$0 + 1]) + 0.0722 * Double(pixels[$0 + 2])
        }
        return luminance.reduce(0, +) / Double(size * size) / 255
    }

    private func waitForBrightness(_ app: XCUIApplication, dark: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        var value = brightness(app)
        while (dark ? value > 0.35 : value < 0.65) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            value = brightness(app)
        }
        XCTAssertTrue(dark ? value <= 0.35 : value >= 0.65, "brightness \(value)", file: file, line: line)
    }

    func testAppearanceSwitchesAndPersists() throws {
        let system = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .light
        defer { XCUIDevice.shared.appearance = system }
        var app = launch([:])
        app.buttons["Settings"].tap()
        var picker = app.segmentedControls["settings.appearance"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(picker.buttons["System"].isSelected)
        waitForBrightness(app, dark: false)
        picker.buttons["Dark"].tap()
        waitForBrightness(app, dark: true)
        picker.buttons["Light"].tap()
        waitForBrightness(app, dark: false)
        picker.buttons["Dark"].tap()
        waitForBrightness(app, dark: true)

        app.terminate()
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 20))
        waitForBrightness(app, dark: true)
        app.buttons["Settings"].tap()
        picker = app.segmentedControls["settings.appearance"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(picker.buttons["Dark"].isSelected)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "settings-dark"
        attachment.lifetime = .keepAlways
        add(attachment)
        picker.buttons["System"].tap()
        waitForBrightness(app, dark: false)
    }

    private func reveal(_ element: XCUIElement, from anchor: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(anchor.waitForExistence(timeout: 60), "\(anchor)")
        let window = app.windows.firstMatch
        let y = anchor.frame.midY / window.frame.height
        let actions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'action.'"))
        func clearOfActions() -> Bool {
            actions.allElementsBoundByIndex.allSatisfy { !$0.exists || !$0.frame.intersects(element.frame) }
        }
        for _ in 0..<10 where !(element.exists && element.isHittable && clearOfActions()) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y))
                .press(forDuration: 0.01, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y - 0.1)),
                       withVelocity: .default, thenHoldForDuration: 0)
        }
        XCTAssertTrue(element.isHittable, "\(element)")
    }

    private func finishEditing(_ app: XCUIApplication) {
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 2) { done.tap() } else { app.typeText("\n") }
    }

    func testAgeAndLabelsSaveWhenEditingEnds() throws {
        let app = launch(["CKD_UI_TEST_IMPORT_ZIP": TestFiles.appPath(contract.appendingPathComponent("mac_export.zip"))])
        let row = app.buttons["library.analysis.dng_flower_manual"]
        waitEnabled(row, timeout: 20)
        row.tap()
        let age = app.textFields["input.age"]
        reveal(age, from: app.staticTexts["result.summary.ph"], in: app)
        XCTAssertEqual(age.value as? String, "50")
        age.clearAndType("61")
        finishEditing(app)

        let steps = app.segmentedControls["steps"]
        steps.buttons["Reservoirs"].tap()
        let condition = app.textFields["reservoir.condition"]
        reveal(condition, from: app.buttons["reservoir.picker"], in: app)
        condition.clearAndType("fasting")
        finishEditing(app)

        steps.buttons["Results"].tap()
        reveal(age, from: app.staticTexts["result.summary.ph"], in: app)
        XCTAssertEqual(age.value as? String, "61")
        steps.buttons["Reservoirs"].tap()
        reveal(condition, from: app.buttons["reservoir.picker"], in: app)
        XCTAssertEqual(condition.value as? String, "fasting")
    }

    func testEquationsAndVersionsPage() throws {
        let app = launch([:])
        let link = app.buttons["library.equations"]
        XCTAssertTrue(link.waitForExistence(timeout: 20))
        link.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ckd_research_2026_10_14'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '0.22.1'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '1.0.0'")).firstMatch.exists, "iPad and iPhone app version")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '2.2.0'")).firstMatch.exists, "CKD release shared with the Mac")
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'AUC 0.923'")).firstMatch.waitForExistence(timeout: 10))
    }
}
