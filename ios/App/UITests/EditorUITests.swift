import XCTest

final class EditorUITests: XCTestCase {
    private let fixtures = TestFiles.fixtures

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func tapWhenEnabled(_ element: XCUIElement, timeout: TimeInterval = 60, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) missing", file: file, line: line)
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: element)], timeout: timeout)
        element.tap()
    }

    private func continueIfAsked(_ app: XCUIApplication, title: String? = nil) {
        if let title { XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10), title) }
        let button = app.buttons["Continue"]
        if button.waitForExistence(timeout: title == nil ? 2 : 10) { button.tap() }
    }

    private func roiCount(_ app: XCUIApplication) -> Int {
        let picker = app.buttons["reservoir.picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        return Int(picker.label.components(separatedBy: " · ").last?.split(separator: " ").first ?? "") ?? -1
    }

    private func waitForROIs(_ app: XCUIApplication, _ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let suffix = count == 1 ? "· 1 ROI" : "· \(count) ROIs"
        let changed = expectation(for: NSPredicate(format: "label ENDSWITH %@", suffix), evaluatedWith: app.buttons["reservoir.picker"])
        if XCTWaiter().wait(for: [changed], timeout: 10) != .completed {
            XCTFail("expected \(count) ROIs in the active reservoir, found \(roiCount(app))", file: file, line: line)
        }
    }

    private func drag(_ canvas: XCUIElement, from: CGVector, to: CGVector) {
        canvas.coordinate(withNormalizedOffset: from).press(forDuration: 0.2, thenDragTo: canvas.coordinate(withNormalizedOffset: to))
    }

    private func reservoirLabel(_ app: XCUIApplication) -> String {
        app.buttons["reservoir.picker"].label
    }

    private func openAnalyzed() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CKD_UI_TEST_RESET": "1",
            "CKD_UI_TEST_RAW": TestFiles.appPath(fixtures.appendingPathComponent("_NOT_ACTUAL_TEST.dng")),
            "CKD_UI_TEST_COORDINATES": try String(contentsOf: fixtures.appendingPathComponent("synthetic-flower-coordinates.json"), encoding: .utf8),
        ]
        app.launch()
        tapWhenEnabled(app.buttons["library.analysis._NOT_ACTUAL_TEST"], timeout: 20)
        tapWhenEnabled(app.buttons["action.render"])
        tapWhenEnabled(app.buttons["analysis.menu"], timeout: 120)
        tapWhenEnabled(app.buttons["test.importCoordinates"])
        tapWhenEnabled(app.buttons["action.whiteBalance"], timeout: 120)
        tapWhenEnabled(app.buttons["action.calibrate"], timeout: 120)
        tapWhenEnabled(app.buttons["action.analyze"], timeout: 120)
        XCTAssertTrue(app.staticTexts["result.summary.ph"].waitForExistence(timeout: 120))
        return app
    }

    func testDrawingReservoirsAndRedoingStepsMatchTheMac() throws {
        let app = try openAnalyzed()
        let canvas = app.descendants(matching: .any)["canvas"]

        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.buttons["reservoir.picker"].waitForExistence(timeout: 10))
        let start = roiCount(app)
        XCTAssertGreaterThan(start, 0)

        tapWhenEnabled(app.buttons["tool.rectangle"])
        drag(canvas, from: CGVector(dx: 0.30, dy: 0.30), to: CGVector(dx: 0.35, dy: 0.35))
        continueIfAsked(app, title: "Change this analysis?")
        waitForROIs(app, start + 1)
        XCTAssertTrue(app.buttons["Cancel"].exists, "drawing stays on after an ROI")
        drag(canvas, from: CGVector(dx: 0.40, dy: 0.30), to: CGVector(dx: 0.45, dy: 0.35))
        waitForROIs(app, start + 2)
        app.buttons["Cancel"].tap()

        tapWhenEnabled(app.buttons["tool.polygon"])
        for offset in [CGVector(dx: 0.50, dy: 0.50), CGVector(dx: 0.56, dy: 0.50), CGVector(dx: 0.53, dy: 0.56), CGVector(dx: 0.50, dy: 0.50)] {
            canvas.coordinate(withNormalizedOffset: offset).tap()
        }
        waitForROIs(app, start + 3)
        app.buttons["Cancel"].tap()

        let first = reservoirLabel(app)
        XCTAssertTrue(first.contains("Reservoir 1 ·"), first)
        app.typeKey("n", modifierFlags: [])
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS 'Reservoir 2 ·'"), evaluatedWith: app.buttons["reservoir.picker"])], timeout: 5)

        XCTAssertGreaterThan(roiCount(app), 0, reservoirLabel(app))
        tapWhenEnabled(app.buttons["Remove"])
        XCTAssertTrue(app.buttons["Remove reservoir"].waitForExistence(timeout: 10))
        app.buttons["Remove reservoir"].tap()
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS \'Reservoir 1 ·\'"), evaluatedWith: app.buttons["reservoir.picker"])], timeout: 5)
        waitForROIs(app, start + 3)
        app.typeKey("n", modifierFlags: [])
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS \'Reservoir 3 ·\'"), evaluatedWith: app.buttons["reservoir.picker"])], timeout: 5)
        app.typeKey("n", modifierFlags: [])
        app.typeKey("n", modifierFlags: [])
        app.typeKey("n", modifierFlags: [])
        app.typeKey("n", modifierFlags: [])
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS \'Reservoir 1 ·\'"), evaluatedWith: app.buttons["reservoir.picker"])], timeout: 5)

        app.typeKey("2", modifierFlags: .command)
        tapWhenEnabled(app.buttons["tool.rectangle"])
        drag(canvas, from: CGVector(dx: 0.60, dy: 0.60), to: CGVector(dx: 0.66, dy: 0.66))
        continueIfAsked(app, title: "Redraw the white-balance area?")
        app.typeKey("4", modifierFlags: .command)
        waitForROIs(app, 0)

        tapWhenEnabled(app.buttons["analysis.undo"])
        continueIfAsked(app)
        app.typeKey("4", modifierFlags: .command)
        waitForROIs(app, start + 3)
    }

    func testStandard24MarkerRectangleAndSixReservoirs() throws {
        let app = try openAnalyzed()
        let canvas = app.descendants(matching: .any)["canvas"]

        app.typeKey("3", modifierFlags: .command)
        tapWhenEnabled(app.buttons["calibration.mode"])
        tapWhenEnabled(app.buttons["Standard 24 · legacy 24-patch"], timeout: 5)
        continueIfAsked(app, title: "Change the marker type?")

        tapWhenEnabled(app.buttons["tool.rectangle"])
        drag(canvas, from: CGVector(dx: 0.25, dy: 0.25), to: CGVector(dx: 0.75, dy: 0.75))
        wait(for: [expectation(for: NSPredicate(format: "value == 'Marker selected'"), evaluatedWith: canvas)], timeout: 10)
        XCTAssertTrue(app.buttons["action.calibrate"].isEnabled)

        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.buttons["reservoir.picker"].waitForExistence(timeout: 10))
        waitForROIs(app, 0)
        for next in 2...6 {
            app.typeKey("n", modifierFlags: [])
            wait(for: [expectation(for: NSPredicate(format: "label CONTAINS %@", "Reservoir \(next) ·"), evaluatedWith: app.buttons["reservoir.picker"])], timeout: 5)
        }
        app.typeKey("n", modifierFlags: [])
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS \'Reservoir 1 ·\'"), evaluatedWith: app.buttons["reservoir.picker"])], timeout: 5)
    }

    func testResultsShowAnalyteNamesAndKeepTheReviewMenu() throws {
        let app = try openAnalyzed()
        app.typeKey("5", modifierFlags: .command)
        for name in ["pH", "Urea", "Creatinine"] {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", name)).firstMatch.waitForExistence(timeout: 10), name)
        }
        let review = app.buttons["review.1"]
        for _ in 0..<10 where !review.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        }
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertTrue(review.isEnabled)
        review.tap()
        XCTAssertTrue(app.buttons["Exclude…"].waitForExistence(timeout: 5))
        app.buttons["Exclude…"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Exclude"].tap()
        let notFinal = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Not final'")).firstMatch
        for _ in 0..<10 where !notFinal.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        }
        XCTAssertTrue(notFinal.waitForExistence(timeout: 10), "pH with nothing included shows a Not final value")
    }
}
