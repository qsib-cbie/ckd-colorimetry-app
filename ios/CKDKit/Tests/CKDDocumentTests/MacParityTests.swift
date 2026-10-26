import CKDDocument
import CKDImage
import CKDResults
import Foundation
import XCTest
import ZIPFoundation

final class MacParityTests: XCTestCase {
    func testStandard24DNG() throws { try assertPipeline("dng_standard24", raw: "iPhoneRAW.DNG") }
    func testStandard24CR2() throws { try assertPipeline("cr2_standard24", raw: "SampleImg1.CR2") }
    func testFlowerAutomatic() throws { try assertPipeline("dng_flower_auto", raw: "_NOT_ACTUAL_TEST.dng") }
    func testFlowerManual() throws { try assertPipeline("dng_flower_manual", raw: "_NOT_ACTUAL_TEST.dng") }

    private func assertPipeline(_ label: String, raw: String) throws {
        let mac = try Paths.json(Paths.macReference.appendingPathComponent("pipeline/\(label).json"))
        let folderURL = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        try FileManager.default.createDirectory(at: folderURL.appendingPathComponent("original"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Paths.fixtures.appendingPathComponent(raw),
                                         to: folderURL.appendingPathComponent("original/\(raw)"))
        var root = mac
        for key in AnalysisDocument.topLevelKeys { root = root.setting(key, .null) }
        var document = try AnalysisDocument(root: root)
        let folder = AnalysisFolder(url: folderURL)

        let initial = try AnalysisPipeline.render(&document, folder: folder)
        let balanced = try AnalysisPipeline.whiteBalance(&document, folder: folder, initial: initial)
        try AnalysisPipeline.calibrate(&document, image: balanced)
        try AnalysisPipeline.analyze(&document, image: balanced)

        var differences: [Difference] = []
        let rasterPaths: Set<String> = ["array", "preview"]
        Same.json(document["render"], mac["render"], tolerance: 0, path: "render", skip: rasterPaths, into: &differences)
        Same.json(document["white_balance"], mac["white_balance"], tolerance: 1e-12, path: "white_balance", skip: rasterPaths, into: &differences)
        Same.json(document["calibration"], mac["calibration"], tolerance: 1e-9, path: "calibration", into: &differences)
        Same.json(document["results"], mac["results"], tolerance: 1e-9, path: "results", skip: ["versions", "calculated_at"], into: &differences)
        Same.json(document.source, mac["source"], tolerance: 0, path: "source", into: &differences)
        assertNoDifferences(differences, label)
        XCTAssertEqual(document["results"]?["versions"]?["platform"], .string("ios"))
    }
}

final class MacContractTests: XCTestCase {
    private var contract: URL { Paths.macReference.appendingPathComponent("contract") }

    private func zipText(_ name: String) throws -> String {
        let archive = try Archive(url: contract.appendingPathComponent("mac_export.zip"), accessMode: .read)
        var data = Data()
        _ = try archive.extract(try XCTUnwrap(archive[name])) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }

    private func openMacFolder() throws -> (AnalysisFolder, AnalysisDocument, URL) {
        let workspace = try Paths.temporary()
        let copy = workspace.appendingPathComponent("Mac analysis")
        try FileManager.default.copyItem(at: contract.appendingPathComponent("Mac analysis"), to: copy)
        let folder = AnalysisFolder(url: copy)
        return (folder, try folder.load(), workspace)
    }

    func testMacFolderOpensAndStoredTablesMatchTheMacExport() throws {
        let (folder, document, workspace) = try openMacFolder()
        defer { try? FileManager.default.removeItem(at: workspace) }
        _ = try folder.verifyOriginal(document)
        let comparison = try XCTUnwrap(document.versionComparison)
        XCTAssertEqual(comparison.calculatedOn, "mac")
        XCTAssertEqual(comparison.differing, ["app"], "the fixture was saved by Mac 2.1.0")
        XCTAssertFalse(document.resultsAffectedByVersion, "matching Mac results are current on iOS")
        let tables = CKDTables.export(ConcentrationResults(stored: try XCTUnwrap(document["results"])), identity: document.identity)
        for (name, text) in tables.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(text, try zipText(name), name)
        }
        XCTAssertEqual(ConcentrationResults(stored: try XCTUnwrap(document["results"])).json.pythonJSON,
                       try XCTUnwrap(document["results"]).removing("schema_name").removing("schema_version")
                        .removing("versions").removing("calculated_at").removing("review_ranges")
                        .removing("scientific_status").pythonJSON, "stored results round trip")
    }

    func testImageTablesAndCoordinatesMatchTheMacExport() throws {
        let (folder, document, workspace) = try openMacFolder()
        defer { try? FileManager.default.removeItem(at: workspace) }
        var working = document
        let initial = try AnalysisPipeline.render(&working, folder: folder)
        let balanced = try AnalysisPipeline.whiteBalance(&working, folder: folder, initial: initial)
        var differences: [Difference] = []
        Same.csv(try MeasurementTables.patchMeasurements(balanced, calibration: try XCTUnwrap(document["calibration"]),
                                                         identity: document.identity),
                 try zipText("03_colorchecker_patch_measurements.csv"), tolerance: 1.5e-6, name: "03", into: &differences)
        Same.csv(try MeasurementTables.roiMeasurements(balanced, document: document, identity: document.identity),
                 try zipText("04_roi_measurements.csv"), tolerance: 1.5e-6, name: "04", into: &differences)
        Same.json(CoordinatePackage.export(document), try JSONValue.parse(Data(try zipText("coordinates.json").utf8)),
                  tolerance: 0, path: "coordinates", into: &differences)
        let manifest = try JSONValue.parse(Data(try zipText("manifest.json").utf8))
        XCTAssertEqual(manifest["files"]?["02_libraw_explicit_wb_rgba8888.bin"]?.stringValue, Digest.sha256(balanced.data))
        XCTAssertEqual(manifest["files"]?["01_libraw_initial_rendered_rgba8888.bin"]?.stringValue, Digest.sha256(initial.data))
        assertNoDifferences(differences, "Mac export tables")
    }

    func testMacExportZipImports() throws {
        let workspace = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (folder, imported) = try ExportArchive.read(contract.appendingPathComponent("mac_export.zip"), into: workspace)
        let mac = try Paths.json(contract.appendingPathComponent("Mac analysis/analysis.ckd.json"))
        XCTAssertEqual(imported.analysisID, mac["analysis_id"]?.stringValue)
        XCTAssertEqual(imported.revision, mac["revision"]?.intValue)
        XCTAssertEqual(imported["render"]?["array"]?.stringValue?.hasPrefix(".cache/"), true)
        XCTAssertEqual(imported["results"], mac["results"])
        XCTAssertEqual(try folder.load().analysisID, imported.analysisID)
        _ = try folder.verifyOriginal(imported)
    }

    func testCoordinatePackageImportsIntoTheSameImage() throws {
        let (_, document, workspace) = try openMacFolder()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let package = try JSONValue.parse(Data(try zipText("coordinates.json").utf8))
        let draft = try CoordinatePackage.importDraft(package, into: document)
        XCTAssertEqual(draft.rois, document.draft.rois)
        XCTAssertEqual(draft.manualPatches, document.draft.manualPatches)
        XCTAssertEqual(draft.mode, document.draft.mode)
        XCTAssertNil(draft.age)
        XCTAssertTrue(draft.reservoirs.allSatisfy { $0.review == "needs_review" })
        var wrong = package.setting("source_image_sha256", .string("0"))
        XCTAssertThrowsError(try CoordinatePackage.importDraft(wrong, into: document))
        wrong = package.setting("schema_version", .int(3))
        XCTAssertThrowsError(try CoordinatePackage.importDraft(wrong, into: document))
    }
}
