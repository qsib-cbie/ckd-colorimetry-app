import CKDDocument
import CKDImage
import CKDResults
import Foundation
import XCTest
import ZIPFoundation

final class DocumentTests: XCTestCase {
    private func macDocument() throws -> JSONValue {
        try Paths.json(Paths.macReference.appendingPathComponent("contract/Mac analysis/analysis.ckd.json"))
    }

    private func coordinates() throws -> JSONValue {
        let archive = try Archive(url: Paths.macReference.appendingPathComponent("contract/mac_export.zip"), accessMode: .read)
        var data = Data()
        _ = try archive.extract(try XCTUnwrap(archive["coordinates.json"])) { data.append($0) }
        return try JSONValue.parse(data)
    }

    func testIOSWorkflowMatchesTheMacAndRoundTripsThroughAnExport() throws {
        let workspace = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mac = try macDocument()
        let run = try ContractWorkflow.run(
            raw: Paths.fixtures.appendingPathComponent("_NOT_ACTUAL_TEST.dng"), coordinates: try coordinates(),
            age: mac["draft"]?["age"]?.doubleValue, sex: mac["draft"]?["sex"]?.stringValue,
            classifierModel: mac["draft"]?["classifier_model"]?.stringValue, in: workspace
        )
        XCTAssertEqual(run.document.revision, 4)
        var differences: [Difference] = []
        Same.json(run.document["calibration"], mac["calibration"], tolerance: 1e-12, path: "calibration", into: &differences)
        Same.json(run.document["results"], mac["results"], tolerance: 1e-12, path: "results",
                  skip: ["versions", "calculated_at"], into: &differences)
        assertNoDifferences(differences, "iOS workflow against the Mac")

        let zip = workspace.appendingPathComponent("export.zip")
        try ExportArchive.write(run.document, folder: run.folder, image: run.image, initial: run.initial, to: zip)
        let importedWorkspace = workspace.appendingPathComponent("imported")
        try FileManager.default.createDirectory(at: importedWorkspace, withIntermediateDirectories: true)
        let (_, imported) = try ExportArchive.read(zip, into: importedWorkspace)
        XCTAssertEqual(imported.analysisID, run.document.analysisID)
        XCTAssertEqual(imported["results"], run.document["results"])
        XCTAssertEqual(imported.draft.json, run.document.draft.json)
    }

    func testEditingRulesFollowTheMac() throws {
        let workspace = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let run = try ContractWorkflow.run(
            raw: Paths.fixtures.appendingPathComponent("_NOT_ACTUAL_TEST.dng"), coordinates: try coordinates(),
            age: 50, sex: "female", classifierModel: nil, in: workspace
        )
        var document = run.document
        var draft = document.draft
        let index = try XCTUnwrap(draft.reservoirs.firstIndex { $0.analyte == "creatinine" })
        draft.reservoirs[index].review = "excluded"
        draft.reservoirs[index].reason = "Smudged"
        try AnalysisPipeline.apply(draft, to: &document)
        XCTAssertNotNil(document["results"], "a review change keeps results")
        let refreshed = ConcentrationResults(stored: try XCTUnwrap(document["results"]))
        XCTAssertEqual(refreshed.reservoirs.first { $0.id == draft.reservoirs[index].id }?.reviewStatus, "excluded")

        draft = document.draft
        draft.rois[0].points[0].x += 1
        try AnalysisPipeline.apply(draft, to: &document)
        XCTAssertNil(document["results"], "a geometry change clears results")
        XCTAssertNotNil(document["calibration"])
        XCTAssertTrue(document.draft.reservoirs.allSatisfy { $0.review == "needs_review" && $0.reason.isEmpty })

        draft = document.draft
        draft.whiteBalance[0].x += 1
        try AnalysisPipeline.apply(draft, to: &document)
        XCTAssertNil(document["white_balance"])
        XCTAssertNil(document["calibration"])

        draft = document.draft
        draft.rois[0].points[0].x = -1
        XCTAssertThrowsError(try AnalysisPipeline.apply(draft, to: &document)) { error in
            XCTAssertTrue((error as? DocumentError)?.message.hasPrefix("ROI 1:") ?? false, "\(error)")
        }

        XCTAssertThrowsError(try run.folder.save(document, expectedRevision: document.revision - 1))
        let saved = try run.folder.save(document, expectedRevision: document.revision)
        XCTAssertEqual(saved.revision, run.document.revision + 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.folder.url.appendingPathComponent(".analysis.previous.json").path))
    }

    func testDraftValidationMatchesTheMacModel() throws {
        let mac = try macDocument()
        var draft = try XCTUnwrap(mac["draft"])
        XCTAssertNoThrow(try Draft(json: draft))
        XCTAssertThrowsError(try Draft(json: draft.setting("colour", .string("red"))))
        XCTAssertThrowsError(try Draft(json: draft.setting("mode", .string("flower_12"))))
        XCTAssertThrowsError(try Draft(json: draft.setting("age", .double(0))))
        let rois = try XCTUnwrap(draft["rois"]?.arrayValues)
        XCTAssertThrowsError(try Draft(json: draft.setting("rois", .array(rois + [rois[0]]))))
        let closed = rois[0].setting("points", .array(try XCTUnwrap(rois[0]["points"]?.arrayValues) + [try XCTUnwrap(rois[0]["points"]?.arrayValues?.first)]))
        draft = draft.setting("rois", .array([closed] + rois.dropFirst()))
        XCTAssertEqual(try Draft(json: draft).rois[0].points.count, try XCTUnwrap(rois[0]["points"]?.arrayValues).count)
    }

    func testPerReservoirUreaChoicesFromTheMacAreLiftedOrDropped() throws {
        let draft = try XCTUnwrap(try macDocument()["draft"])
        let reservoirs = try XCTUnwrap(draft["reservoirs"]?.arrayValues)
        let ureaIndex = try XCTUnwrap(reservoirs.firstIndex { $0["analyte"]?.stringValue == "urea" })
        func with(_ changes: [(String, JSONValue)]) -> JSONValue {
            var copy = reservoirs
            for (key, value) in changes { copy[ureaIndex] = copy[ureaIndex].setting(key, value) }
            return draft.setting("reservoirs", .array(copy))
        }
        let shared = try Draft(json: with([("urea_ph_model", .string("pH_7.0")), ("urea_calibration", .string("ab"))]))
        XCTAssertEqual(shared.ureaPHModel, "pH_7.0")
        XCTAssertEqual(shared.ureaCalibration, "ab")
        let written = try XCTUnwrap(shared.json["reservoirs"]?.arrayValues)
        XCTAssertTrue(written.allSatisfy { $0["urea_ph_model"] == nil && $0["urea_calibration"] == nil })
        XCTAssertNil(try Draft(json: with([("urea_ph_model", .string("auto"))])).ureaPHModel)
        XCTAssertThrowsError(try Draft(json: with([("urea_calibration", .string("xyz"))])))
    }

    func testDocumentsFromNewerAppsAskForAnUpdate() throws {
        let mac = try macDocument()
        XCTAssertNoThrow(try AnalysisDocument(root: mac))
        let future = mac.setting("schema_version", .int(2)).setting("saved_with", .string("9.0.0"))
        XCTAssertThrowsError(try AnalysisDocument(root: future)) { error in
            XCTAssertEqual((error as? DocumentError)?.message,
                           "This analysis was saved by CKD Colorimetry 9.0.0. Update this app to open it.")
        }
        let unsafe = mac.setting("source", try XCTUnwrap(mac["source"]).setting("file", .string("../escape.dng")))
        XCTAssertThrowsError(try AnalysisDocument(root: unsafe))
    }

    func testMacResultsFromAnEarlierAppDifferOnlyInTheAppVersion() throws {
        let versions = try XCTUnwrap(try macDocument()["results"]?["versions"])
        XCTAssertNil(versions["platform"])
        let current = CKDVersions.compare(versions)
        XCTAssertEqual(current.calculatedOn, "mac")
        XCTAssertEqual(current.calculatedWith, "2.1.0")
        XCTAssertEqual(current.differing, ["app"])
        XCTAssertFalse(current.affectsValues)
        let libraries = versions.setting("numpy", .string("9.9.9")).setting("scikit_image", .string("0.0.1"))
            .setting("rawpy", .string("0.0.1")).setting("python", .string("3.0.0"))
        XCTAssertEqual(CKDVersions.compare(libraries), current, "Python library versions do not apply on iOS")
    }

    func testMacResultsFromOtherVersionsStillNeedRecompute() throws {
        let versions = try XCTUnwrap(try macDocument()["results"]?["versions"]).setting("app", .string(CKDVersions.app))
        for (key, value, remeasure) in [("engine", "0.0.9", true), ("flower_reference", "older_flower", true),
                                        ("libraw", "0.0.0", true), ("configuration", "older_equations", false)] {
            let comparison = CKDVersions.compare(versions.setting(key, .string(value)))
            XCTAssertEqual(comparison.differing, [key])
            XCTAssertTrue(comparison.affectsValues, key)
            XCTAssertEqual(comparison.needsRemeasure, remeasure, key)
        }
        let otherApp = CKDVersions.compare(versions.setting("app", .string("2.0.9")))
        XCTAssertTrue(otherApp.outdated)
        XCTAssertFalse(otherApp.affectsValues)
        XCTAssertEqual(CKDVersions.compare(versions.removing("app")).calculatedWith, "1.2 or earlier")
        XCTAssertEqual(CKDVersions.compare(CKDVersions.current).calculatedOn, "ios")
    }

    func testReviewEditsOnMacResultsRecalculateOnIOS() throws {
        var document = try AnalysisDocument(root: try macDocument())
        var draft = document.draft
        let index = try XCTUnwrap(draft.reservoirs.firstIndex { $0.analyte == "ph" && !$0.roiIDs.isEmpty })
        let reservoirID = draft.reservoirs[index].id
        draft.reservoirs[index].review = "excluded"
        draft.reservoirs[index].reason = "Bubble"
        try AnalysisPipeline.apply(draft, to: &document)
        let results = ConcentrationResults(stored: try XCTUnwrap(document["results"]))
        XCTAssertFalse(try XCTUnwrap(results.summary("ph")).includedIDs.contains(reservoirID))
        XCTAssertNil(document["results"]?["versions"]?["platform"], "refreshing keeps the Mac versions")

        var older = try AnalysisDocument(root: try macDocument())
        let results2 = try XCTUnwrap(older["results"])
        older.set("results", results2.setting("versions", try XCTUnwrap(results2["versions"])
            .setting("configuration", .string("older_equations"))))
        XCTAssertThrowsError(try AnalysisPipeline.apply(draft, to: &older)) { error in
            XCTAssertTrue((error as? DocumentError)?.message.contains("Differences") ?? false, "\(error)")
        }
    }

    func testPythonCompatibleJSON() throws {
        let text = "{\"a\": [1, 2.5, -0.0, 1e-05], \"b\": {\"c\": null, \"d\": \"\u{e9}\\n\\\"x\\\"\"}, \"e\": true, \"f\": []}"
        let value = try JSONValue.parse(Data(text.utf8))
        let escaped = "\"\\u00e9\\n\\\"x\\\"\""
        XCTAssertEqual(value.pythonJSON, "{\"a\": [1, 2.5, -0.0, 1e-05], \"b\": {\"c\": null, \"d\": \(escaped)}, \"e\": true, \"f\": []}")
        XCTAssertEqual(value.prettyJSON(), "{\n  \"a\": [\n    1,\n    2.5,\n    -0.0,\n    1e-05\n  ],\n  \"b\": {\n    \"c\": null,\n    \"d\": \(escaped)\n  },\n  \"e\": true,\n  \"f\": []\n}")
    }

}
