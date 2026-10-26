import CKDDocument
import Foundation
import XCTest

final class LibraryTests: XCTestCase {
    func testFoldersAnalysesRenameMoveAndRecentlyDeleted() throws {
        let root = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = WorkspaceLibrary(root: root)
        let study = try library.createFolder(named: "Study A", in: root)
        XCTAssertEqual(try library.createFolder(named: "Study A", in: root).lastPathComponent, "Study A (2)")
        let (folder, _) = try AnalysisFolder.create(importing: Paths.fixtures.appendingPathComponent("_NOT_ACTUAL_TEST.dng"), in: study)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)

        XCTAssertEqual(library.contents(of: root).map(\.name), ["Study A", "Study A (2)"])
        let analysis = try XCTUnwrap(library.contents(of: study).first)
        XCTAssertEqual(analysis.kind, .analysis)
        XCTAssertEqual(analysis.title, "_NOT_ACTUAL_TEST")
        XCTAssertEqual(library.analyses().map { $0.url.resolvingSymlinksInPath() }, [folder.url.resolvingSymlinksInPath()])

        let renamed = try library.rename(analysis, to: "Sample 1: left arm")
        XCTAssertEqual(renamed.lastPathComponent, "Sample 1- left arm")
        XCTAssertEqual(try AnalysisFolder(url: renamed).load().draft.title, "Sample 1: left arm")
        XCTAssertEqual(try AnalysisFolder(url: renamed).load().revision, 1)

        let moved = try library.move(library.item(at: renamed), to: root)
        XCTAssertEqual(moved.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertThrowsError(try library.move(library.item(at: study), to: study))

        try library.moveToRecentlyDeleted(library.item(at: study))
        XCTAssertEqual(library.contents(of: root).map(\.name), ["Study A (2)", "Sample 1- left arm"])
        let deleted = try XCTUnwrap(library.recentlyDeleted().first)
        XCTAssertEqual(deleted.name, "Study A")
        XCTAssertEqual(try library.restore(deleted).lastPathComponent, "Study A")
        XCTAssertTrue(library.recentlyDeleted().isEmpty)

        try FileManager.default.createDirectory(at: root.appendingPathComponent("Broken"), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: root.appendingPathComponent("Broken/analysis.ckd.json"))
        XCTAssertEqual(library.item(at: root.appendingPathComponent("Broken")).kind, .problem)
    }

    func testRasterCacheRebuildsMissingImagesAndChecksTheSavedHash() throws {
        let root = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Paths.macReference.appendingPathComponent("contract/Mac analysis"),
                                         to: workspace.appendingPathComponent("Mac analysis"))
        let folder = AnalysisFolder(url: workspace.appendingPathComponent("Mac analysis"))
        let document = try folder.load()
        let store = RasterStore(root: root.appendingPathComponent("cache"))

        XCTAssertNil(store.cached(document, block: "white_balance"))
        let rebuilt = try store.image(document, folder: folder, balanced: true)
        XCTAssertTrue(rebuilt.matchesSavedHash)
        XCTAssertEqual(Digest.sha256(rebuilt.image.data), document["white_balance"]?["rgba8888_sha256"]?.stringValue)
        let cached = try XCTUnwrap(store.cached(document, block: "white_balance"))
        XCTAssertEqual(cached.data, rebuilt.image.data)
        XCTAssertNotNil(store.cached(document, block: "render"))
        XCTAssertTrue(try store.image(document, folder: folder, balanced: false).matchesSavedHash)

        store.purge(analysisID: document.analysisID)
        XCTAssertNil(store.cached(document, block: "render"))
    }
}
