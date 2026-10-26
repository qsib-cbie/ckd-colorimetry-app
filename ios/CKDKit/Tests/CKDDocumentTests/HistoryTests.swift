import CKDDocument
import CKDImage
import CKDResults
import Foundation
import XCTest

final class HistoryTests: XCTestCase {
    private func macFolder() throws -> (AnalysisFolder, URL) {
        let workspace = try Paths.temporary()
        let copy = workspace.appendingPathComponent("Mac analysis")
        try FileManager.default.copyItem(at: Paths.macReference.appendingPathComponent("contract/Mac analysis"), to: copy)
        return (AnalysisFolder(url: copy), workspace)
    }

    private func olderEquations(_ document: inout AnalysisDocument) throws {
        let results = try XCTUnwrap(document["results"])
        var reservoirs = try XCTUnwrap(results["reservoirs"]?.arrayValues)
        reservoirs[1] = reservoirs[1].setting("value", .double(try XCTUnwrap(reservoirs[1]["value"]?.doubleValue) + 10))
        document.set("results", results.setting("reservoirs", .array(reservoirs))
            .setting("versions", try XCTUnwrap(results["versions"]).setting("configuration", .string("older_equations"))))
    }

    func testDifferencesPreviewEquationChangesAndHideRemeasuredValues() throws {
        let (folder, workspace) = try macFolder()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mac = try folder.load()
        var document = mac
        try olderEquations(&document)
        let differences = try XCTUnwrap(document.differences)
        XCTAssertEqual(differences.versions.filter(\.differs).map(\.key), ["app", "configuration"])
        XCTAssertEqual(differences.versions.first { $0.key == "configuration" }?.saved, "older_equations")
        let reference = ConcentrationResults(stored: try XCTUnwrap(mac["results"]))
        let second = try XCTUnwrap(differences.values.first { $0.kind == .reservoir(2, "urea") })
        XCTAssertEqual(second.changed, true)
        XCTAssertEqual(try XCTUnwrap(second.current), try XCTUnwrap(reference.reservoirs[1].value), accuracy: 1e-9)
        XCTAssertEqual(differences.values.first { $0.kind == .reservoir(1, "ph") }?.changed, false)
        XCTAssertEqual(differences.values.last?.kind, .prediction)
        XCTAssertTrue(differences.values.contains { $0.kind == .summary("urea") && $0.changed == false })

        var engine = mac
        let results = try XCTUnwrap(engine["results"])
        engine.set("results", results.setting("versions", try XCTUnwrap(results["versions"]).setting("engine", .string("0.0.9"))))
        let remeasured = try XCTUnwrap(engine.differences)
        XCTAssertTrue(remeasured.comparison.needsRemeasure)
        XCTAssertTrue(remeasured.values.allSatisfy { $0.current == nil && $0.changed == nil })
        XCTAssertFalse(try XCTUnwrap(mac.differences).comparison.affectsValues)
    }

    func testRecomputeRecordsARunSnapshotWithPreviousResults() throws {
        let (folder, workspace) = try macFolder()
        defer { try? FileManager.default.removeItem(at: workspace) }
        var document = try folder.load()
        try olderEquations(&document)
        let previous = document["results"]
        _ = try AnalysisPipeline.recompute(&document, folder: folder)
        try RunHistory.record(document, previous: previous, in: folder)
        let snapshots = RunHistory.list(AnalysisFolder(url: folder.url))
        XCTAssertEqual(snapshots.count, 1)
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertTrue(snapshot.id.hasPrefix(String(format: "run-%06d-", document.revision)))
        XCTAssertFalse(snapshot.imported)
        XCTAssertTrue(snapshot.keepsPreviousResults)
        XCTAssertEqual(snapshot.versions?["platform"]?.stringValue, "ios")
        let manifest = try Paths.json(snapshot.url.appendingPathComponent("manifest.json"))
        XCTAssertEqual(manifest["schema_name"]?.stringValue, "ckd_run_snapshot")
        XCTAssertEqual(manifest["analysis_id"]?.stringValue, document.analysisID)
        let files = try XCTUnwrap(manifest["files"]?.objectPairs)
        XCTAssertEqual(Array(files.map(\.0).prefix(3)), ["analysis.json", "results.json", "coordinates.json"])
        XCTAssertTrue(files.contains { $0.0 == "05_reservoirs.csv" })
        for (name, digest) in files {
            XCTAssertEqual(try Digest.sha256(file: snapshot.url.appendingPathComponent(name)), digest.stringValue, name)
        }
        XCTAssertEqual(try Paths.json(snapshot.url.appendingPathComponent("previous_results.json")), previous)
    }

    func testZipImportKeepsAnImportedRunSnapshot() throws {
        let workspace = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (folder, _) = try ExportArchive.read(Paths.macReference.appendingPathComponent("contract/mac_export.zip"), into: workspace)
        let snapshot = try XCTUnwrap(RunHistory.list(folder).first)
        XCTAssertEqual(snapshot.id, "imported-0001")
        XCTAssertTrue(snapshot.imported)
        let manifest = try Paths.json(snapshot.url.appendingPathComponent("manifest.json"))
        XCTAssertEqual(manifest["schema_name"]?.stringValue, "ckd_imported_run")
        let files = try XCTUnwrap(manifest["files"]?.objectPairs)
        XCTAssertTrue(files.contains { $0.0 == "results.json" })
        XCTAssertTrue(files.contains { $0.0 == "04_roi_measurements.csv" })
        XCTAssertFalse(files.contains { $0.0.hasPrefix("original/") || $0.0 == "manifest.json" })
        for (name, digest) in files {
            XCTAssertEqual(try Digest.sha256(file: snapshot.url.appendingPathComponent(name)), digest.stringValue, name)
        }
    }

    func testUndoingAGeometryEditRestoresSavedResultsFromHistory() throws {
        let (folder, workspace) = try macFolder()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let original = try folder.load()
        var moved = original.draft
        moved.rois[0].points[0] = QCamPoint(x: moved.rois[0].points[0].x + 2, y: moved.rois[0].points[0].y)
        var document = original
        try AnalysisPipeline.apply(moved, to: &document, history: folder.history)
        XCTAssertNil(document["results"])
        XCTAssertNotNil(document["calibration"])
        document = try folder.save(document, expectedRevision: original.revision)
        XCTAssertEqual(folder.history().map(\.revision), [original.revision])

        var undone = document
        try AnalysisPipeline.apply(original.draft, to: &undone, history: folder.history)
        XCTAssertEqual(undone["results"], original["results"])
        XCTAssertEqual(undone["calibration"], original["calibration"])
        XCTAssertEqual(undone["white_balance"], original["white_balance"])
        XCTAssertEqual(undone.draft.json, original.draft.json)
        undone = try folder.save(undone, expectedRevision: document.revision)
        XCTAssertEqual(folder.history().map(\.revision), [document.revision, original.revision])

        var reimported = undone
        try AnalysisPipeline.apply(moved, to: &reimported, imported: true, history: folder.history)
        XCTAssertNil(reimported["white_balance"], "imports never restore from history")
    }

    func testHistoryKeepsTheLatestTwentyVersions() throws {
        let (folder, workspace) = try macFolder()
        defer { try? FileManager.default.removeItem(at: workspace) }
        var document = try folder.load()
        let first = document.revision
        for index in 0..<25 {
            var draft = document.draft
            draft.title = "Title \(index)"
            try document.replaceDraft(draft)
            document = try folder.save(document, expectedRevision: document.revision)
        }
        let revisions = folder.history().map(\.revision)
        XCTAssertEqual(revisions.count, AnalysisFolder.historyLimit)
        XCTAssertEqual(revisions.first, first + 24)
        XCTAssertEqual(revisions.last, first + 5)
    }
}
