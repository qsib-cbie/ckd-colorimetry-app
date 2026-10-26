import CKDDocument
import CKDImage
import CKDResults
import XCTest

final class EditingUITests: XCTestCase {
    private let fixtures = TestFiles.fixtures
    private var contract: URL { fixtures.appendingPathComponent("mac_reference/contract") }
    private var scratch: URL { TestFiles.scratch("ui-test-editing") }

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

    private func screenPoint(_ point: QCamPoint, canvas: XCUIElement, image: CGSize) -> XCUICoordinate {
        let frame = canvas.frame
        let scale = min(frame.width / image.width, frame.height / image.height)
        let x = (frame.width - image.width * scale) / 2 + (point.x + 0.5) * scale
        let y = (frame.height - image.height * scale) / 2 + (point.y + 0.5) * scale
        return canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    func testMovingAPointClearsResultsAndUndoRestoresThem() throws {
        let mac = try AnalysisFolder(url: contract.appendingPathComponent("Mac analysis")).load()
        let expected = ConcentrationResults(stored: try XCTUnwrap(mac["results"]))
        let ph = try XCTUnwrap(expected.summaries.first { $0.analyte == "ph" })
        let phText = "pH, " + String(format: "%.3f", try XCTUnwrap(ph.value)) + " ± " + String(format: "%.3f", try XCTUnwrap(ph.sd)) + " pH"
        let roi = try XCTUnwrap(mac.draft.rois.first)
        let image = CGSize(width: try XCTUnwrap(mac.width), height: try XCTUnwrap(mac.height))

        let app = launch(["CKD_UI_TEST_IMPORT_ZIP": TestFiles.appPath(contract.appendingPathComponent("mac_export.zip"))])
        let row = app.buttons["library.analysis.\(mac.draft.title)"]
        waitEnabled(row, timeout: 20)
        row.tap()
        let summary = app.staticTexts["result.summary.ph"]
        XCTAssertTrue(summary.waitForExistence(timeout: 60))
        XCTAssertEqual(summary.label, phText)

        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.segmentedControls["steps"].buttons["Reservoirs"].waitForExistence(timeout: 10))
        waitEnabled(app.buttons["tool.rectangle"], timeout: 120)
        let canvas = app.otherElements["canvas"]
        let centroid = QCamPoint(x: roi.points.map(\.x).reduce(0, +) / Double(roi.points.count),
                                 y: roi.points.map(\.y).reduce(0, +) / Double(roi.points.count))
        screenPoint(centroid, canvas: canvas, image: image).tap()
        XCTAssertTrue(canvas.waitForValue("\(roi.label) selected"))

        let vertex = screenPoint(roi.points[0], canvas: canvas, image: image)
        vertex.press(forDuration: 0.1, thenDragTo: vertex.withOffset(CGVector(dx: -25, dy: -25)))
        let move = app.buttons["Continue"]
        XCTAssertTrue(move.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Move this point?"].exists)
        move.tap()
        XCTAssertTrue(app.staticTexts["result.summary.ph"].waitForNonExistence(timeout: 10))

        waitEnabled(app.buttons["analysis.undo"], timeout: 10)
        app.buttons["analysis.undo"].tap()
        let restored = app.staticTexts.matching(identifier: "banner.text").matching(NSPredicate(format: "label == 'Restored the saved results for this version.'")).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        app.typeKey("5", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["result.summary.ph"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["result.summary.ph"].label, phText)

        waitEnabled(app.buttons["analysis.redo"], timeout: 10)
        app.buttons["analysis.redo"].tap()
        XCTAssertTrue(app.staticTexts["Redo this change?"].waitForExistence(timeout: 10))
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["result.summary.ph"].waitForNonExistence(timeout: 10))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["result.summary.ph"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["result.summary.ph"].label, phText)
    }

    func testEditingControlsMatchTheMac() throws {
        let app = launch(["CKD_UI_TEST_IMPORT_ZIP": TestFiles.appPath(contract.appendingPathComponent("mac_export.zip"))])
        let row = app.buttons["library.analysis.dng_flower_manual"]
        waitEnabled(row, timeout: 20)
        row.tap()
        XCTAssertTrue(app.staticTexts["result.summary.ph"].waitForExistence(timeout: 60))

        app.typeKey("3", modifierFlags: .command)
        let marker = app.buttons["calibration.mode"]
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        marker.tap()
        XCTAssertTrue(app.buttons["Standard 24 · legacy 24-patch"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Flower 9 · marker corners"].exists)
        app.buttons["Standard 24 · legacy 24-patch"].tap()
        XCTAssertTrue(app.staticTexts["Change the marker type?"].waitForExistence(timeout: 10))
        let cancel = app.buttons["Cancel"]
        if cancel.exists && cancel.isHittable {
            cancel.tap()
        } else {
            app.descendants(matching: .any)["canvas"].coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).tap()
        }
        XCTAssertTrue(app.staticTexts["Change the marker type?"].waitForNonExistence(timeout: 10))

        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.buttons["reservoir.picker"].waitForExistence(timeout: 10))
        for _ in 0..<8 where !(app.textFields["reservoir.condition"].exists && app.textFields["reservoir.condition"].isHittable) {
            let start = app.buttons["reservoir.picker"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)))
        }
        XCTAssertTrue(app.textFields["reservoir.customName"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["reservoir.condition"].exists)
        XCTAssertFalse(app.textFields["reservoir.replicate"].exists)
        XCTAssertTrue(app.staticTexts["Notes"].exists || app.textFields["reservoir.condition"].label == "Notes")
        XCTAssertTrue(app.staticTexts["Custom biomarker"].exists || app.textFields["reservoir.customName"].label == "Custom biomarker")

        app.buttons["analysis.menu"].tap()
        waitEnabled(app.buttons["analysis.reset"], timeout: 10)
        app.buttons["analysis.reset"].tap()
        XCTAssertTrue(app.staticTexts["Reset this analysis?"].waitForExistence(timeout: 10))
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.segmentedControls["steps"].buttons["White balance"].waitForExistence(timeout: 10))
        waitEnabled(app.buttons["analysis.undo"], timeout: 10)
        app.buttons["analysis.undo"].tap()
        if app.buttons["Continue"].waitForExistence(timeout: 5) { app.buttons["Continue"].tap() }
        app.typeKey("5", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["result.summary.ph"].waitForExistence(timeout: 30))
    }

    func testImportFromPhotosTakesTheRawOriginal() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CKD_UI_TEST_PHOTOS"] == "1",
                          "Add a DNG to the simulator's Photos (xcrun simctl addmedia) and set TEST_RUNNER_CKD_UI_TEST_PHOTOS=1")
        let app = launch([:])
        func pick(column: Int) {
            waitEnabled(app.buttons["library.add"], timeout: 20)
            app.buttons["library.add"].tap()
            waitEnabled(app.buttons["library.importPhoto"], timeout: 5)
            app.buttons["library.importPhoto"].tap()
            sleep(3)
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 357 + 91 * column, dy: 548)).tap()
        }
        pick(column: 1)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'no RAW original'")).firstMatch.waitForExistence(timeout: 30))
        app.buttons["OK"].tap()
        pick(column: 0)
        XCTAssertTrue(app.buttons["action.whiteBalance"].waitForExistence(timeout: 120))
    }

    func testDragAnAnalysisIntoAFolder() throws {
        let app = launch(["CKD_UI_TEST_IMPORT_ZIP": TestFiles.appPath(contract.appendingPathComponent("mac_export.zip"))])
        let row = app.buttons["library.analysis.dng_flower_manual"]
        waitEnabled(row, timeout: 20)
        app.buttons["library.add"].tap()
        app.buttons["New Folder"].tap()
        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.clearAndType("Study")
        app.buttons["Save"].tap()
        let folder = app.buttons["library.folder.Study"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))

        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.9, thenDragTo: folder.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)),
                    withVelocity: 150, thenHoldForDuration: 0.8)
        XCTAssertTrue(row.waitForNonExistence(timeout: 10))
        folder.tap()
        XCTAssertTrue(app.buttons["library.analysis.dng_flower_manual"].waitForExistence(timeout: 10))
    }

    func testChoosingAWorkspaceFolderAndSwitchingBack() throws {
        try XCTSkipIf(TestFiles.onDevice, "On a device the app cannot open the workspace folder this test builds")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let workspace = scratch.appendingPathComponent("Shared workspace " + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Study"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.copyItem(at: contract.appendingPathComponent("Mac analysis"),
                                         to: workspace.appendingPathComponent("Study/Mac analysis"))
        try Data().write(to: workspace.appendingPathComponent(".ckd-workspace.lock"))

        let app = launch(["CKD_UI_TEST_WORKSPACE": workspace.path])
        let folder = app.buttons["library.folder.Study"]
        XCTAssertTrue(folder.waitForExistence(timeout: 20))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", workspace.lastPathComponent)).firstMatch.waitForExistence(timeout: 5))
        app.buttons["settings.useDevice"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'CKD Colorimetry'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["library.folder.Study"].exists)
        let recent = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", workspace.lastPathComponent)).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.tap()
        let back = app.navigationBars["Settings"].buttons["Library"]
        if back.waitForExistence(timeout: 2) { back.tap() }
        XCTAssertTrue(app.buttons["library.folder.Study"].waitForExistence(timeout: 10))
        app.buttons["library.folder.Study"].tap()
        XCTAssertTrue(app.buttons["library.analysis.dng_flower_manual"].waitForExistence(timeout: 10))
    }
}

extension XCUIElement {
    func waitForValue(_ value: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func clearAndType(_ text: String) {
        coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -2, dy: 0)).tap()
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
