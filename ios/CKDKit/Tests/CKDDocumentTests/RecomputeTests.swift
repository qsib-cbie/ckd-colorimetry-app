import CKDDocument
import CKDResults
import Foundation
import XCTest

final class RecomputeTests: XCTestCase {
    private func macFolder() throws -> (AnalysisFolder, URL) {
        let workspace = try Paths.temporary()
        let copy = workspace.appendingPathComponent("Mac analysis")
        try FileManager.default.copyItem(at: Paths.macReference.appendingPathComponent("contract/Mac analysis"), to: copy)
        return (AnalysisFolder(url: copy), workspace)
    }

    private func older(_ document: inout AnalysisDocument, key: String, value: String) throws {
        let results = try XCTUnwrap(document["results"])
        var reservoirs = try XCTUnwrap(results["reservoirs"]?.arrayValues)
        let second = reservoirs[1]
        reservoirs[1] = second.setting("value", .double(try XCTUnwrap(second["value"]?.doubleValue) + 10))
        document.set("results", results.setting("reservoirs", .array(reservoirs))
            .setting("versions", try XCTUnwrap(results["versions"]).setting(key, .string(value))))
        var draft = document.draft
        for index in 0..<3 { draft.reservoirs[index].review = "included" }
        try document.replaceDraft(draft)
    }

    func testEquationChangeRecalculatesFromStoredMeasurementsAndResetsChangedReviews() throws {
        let (folder, workspace) = try macFolder()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mac = try folder.load()
        var document = mac
        try older(&document, key: "configuration", value: "older_equations")
        XCTAssertTrue(try XCTUnwrap(document.versionComparison).affectsValues)
        XCTAssertFalse(try XCTUnwrap(document.versionComparison).needsRemeasure)

        let images = try AnalysisPipeline.recompute(&document, folder: folder)
        XCTAssertNil(images.initial)
        let comparison = try XCTUnwrap(document.versionComparison)
        XCTAssertFalse(comparison.outdated)
        XCTAssertEqual(comparison.calculatedOn, "ios")
        XCTAssertEqual(document.draft.reservoirs.prefix(3).map(\.review), ["included", "needs_review", "included"])
        let recomputed = ConcentrationResults(stored: try XCTUnwrap(document["results"]))
        let reference = ConcentrationResults(stored: try XCTUnwrap(mac["results"]))
        XCTAssertEqual(try XCTUnwrap(recomputed.reservoirs[1].value), try XCTUnwrap(reference.reservoirs[1].value), accuracy: 1e-9)
        XCTAssertEqual(document["render"], mac["render"], "no re-render for an equation change")
    }

    func testEngineChangeRemeasuresFromTheOriginalAndKeepsMatchingReviews() throws {
        let (folder, workspace) = try macFolder()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mac = try folder.load()
        var document = mac
        let results = try XCTUnwrap(document["results"])
        document.set("results", results.setting("versions", try XCTUnwrap(results["versions"]).setting("engine", .string("0.0.9"))))
        var draft = document.draft
        for index in 0..<3 { draft.reservoirs[index].review = "included" }
        try document.replaceDraft(draft)
        XCTAssertTrue(try XCTUnwrap(document.versionComparison).needsRemeasure)

        let images = try AnalysisPipeline.recompute(&document, folder: folder)
        XCTAssertNotNil(images.initial)
        XCTAssertNotNil(images.balanced)
        XCTAssertEqual(document["render"]?["rgba8888_sha256"], mac["render"]?["rgba8888_sha256"])
        XCTAssertEqual(document["white_balance"]?["rgba8888_sha256"], mac["white_balance"]?["rgba8888_sha256"])
        XCTAssertEqual(document.draft.reservoirs.prefix(3).map(\.review), ["included", "included", "included"],
                       "rounding differences keep reviews")
        var differences: [Difference] = []
        Same.json(document["results"]?["summaries"], mac["results"]?["summaries"], tolerance: 1e-9, path: "summaries", into: &differences)
        assertNoDifferences(differences, "remeasured summaries")
        XCTAssertEqual(document.versionComparison?.calculatedOn, "ios")
    }

    func testNewIDExportNameAndFolderImport() throws {
        let (folder, workspace) = try macFolder()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let library = WorkspaceLibrary(root: workspace)
        let copied = try library.importFolder(folder.url, into: workspace)
        XCTAssertEqual(copied.lastPathComponent, "Mac analysis (2)")
        XCTAssertEqual(library.duplicateAnalysisIDs().count, 1)
        let before = try folder.load()
        let renumbered = try AnalysisFolder(url: copied).assignNewID()
        XCTAssertNotEqual(renumbered.analysisID, before.analysisID)
        XCTAssertEqual(renumbered["copied_from"]?["analysis_id"]?.stringValue, before.analysisID)
        XCTAssertEqual(renumbered.revision, before.revision + 1)
        XCTAssertTrue(library.duplicateAnalysisIDs().isEmpty)
        XCTAssertNoThrow(try AnalysisFolder(url: copied).load())

        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        try Data(count: 16).write(to: folder.url.appendingPathComponent(".cache/r1-render.npy"))
        let third = try library.importFolder(folder.url, into: workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: third.appendingPathComponent(".cache").path))
        XCTAssertThrowsError(try library.importFolder(workspace.appendingPathComponent("Mac analysis/original"), into: workspace))

        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 19; components.hour = 9; components.minute = 5; components.second = 7
        let date = try XCTUnwrap(Calendar.current.date(from: components))
        XCTAssertEqual(AnalysisFolder.exportFilename(title: "Sample 1: left/arm é", date: date), "Sample 1- left-arm_2026-10-19_090507.zip")
        XCTAssertEqual(AnalysisFolder.exportFilename(title: "...", date: date), "ckd-analysis_2026-10-19_090507.zip")
    }
}
