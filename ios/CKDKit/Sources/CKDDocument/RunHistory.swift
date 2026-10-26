import CKDResults
import Foundation

public enum RunHistory {
    public static let directoryName = "runs"

    public struct Snapshot: Identifiable, Sendable {
        public let url: URL
        public let imported: Bool
        public let createdAt: String?
        public let revision: Int?
        public let versions: JSONValue?
        public let keepsPreviousResults: Bool

        public var id: String { url.lastPathComponent }
    }

    public static func record(_ document: AnalysisDocument, previous: JSONValue?, in folder: AnalysisFolder) throws {
        guard let results = document["results"] else { return }
        var files: [(String, Data)] = [
            ("analysis.json", json(AnalysisDocument.portable(document.root).setting("job", .null).setting("export", .null))),
            ("results.json", json(results)),
            ("coordinates.json", json(CoordinatePackage.export(document))),
        ]
        let tables = CKDTables.export(ConcentrationResults(stored: results), identity: document.identity)
        files += tables.keys.sorted().map { ($0, Data(tables[$0]!.utf8)) }
        if let previous, previous != results {
            files.append(("previous_results.json", json(previous)))
        }
        let runs = folder.url.appendingPathComponent(directoryName)
        let staged = runs.appendingPathComponent(".run-" + hex(32))
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        do {
            for (name, data) in files { try data.write(to: staged.appendingPathComponent(name)) }
            let manifest: JSONValue = .object([
                ("schema_name", .string("ckd_run_snapshot")), ("schema_version", .int(1)), ("created_at", .string(Clock.now())),
                ("analysis_id", .string(document.analysisID)), ("revision", .int(document.revision)),
                ("source_sha256", .string(document.sourceSHA256)), ("versions", results["versions"] ?? .object([])),
                ("files", .object(files.map { ($0.0, .string(Digest.sha256($0.1))) })),
            ])
            try AnalysisFolder.atomicWrite(json(manifest), to: staged.appendingPathComponent("manifest.json"))
            try FileManager.default.moveItem(at: staged, to: runs.appendingPathComponent(String(format: "run-%06d-", document.revision) + hex(8)))
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    static func recordImport(_ document: AnalysisDocument, extras: [String: URL], in analysis: URL) throws {
        let snapshot = analysis.appendingPathComponent(directoryName).appendingPathComponent("imported-0001")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try json(AnalysisDocument.portable(document.root)).write(to: snapshot.appendingPathComponent("analysis.json"))
        if let results = document["results"] {
            try json(results).write(to: snapshot.appendingPathComponent("results.json"))
        }
        for (name, source) in extras where !["analysis.json", "results.json", "manifest.json"].contains(name) && !name.hasPrefix("original/") {
            let target = snapshot.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
        }
        var digests: [(String, JSONValue)] = []
        let enumerator = FileManager.default.enumerator(atPath: snapshot.path)
        while let relative = enumerator?.nextObject() as? String {
            let file = snapshot.appendingPathComponent(relative)
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                digests.append((relative, .string(try Digest.sha256(file: file))))
            }
        }
        let manifest: JSONValue = .object([
            ("schema_name", .string("ckd_imported_run")), ("schema_version", .int(1)),
            ("source_sha256", .string(document.sourceSHA256)),
            ("files", .object(digests.sorted { $0.0 < $1.0 })),
        ])
        try AnalysisFolder.atomicWrite(json(manifest), to: snapshot.appendingPathComponent("manifest.json"))
    }

    public static func list(_ folder: AnalysisFolder) -> [Snapshot] {
        let runs = folder.url.appendingPathComponent(directoryName)
        let entries = (try? FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { !$0.lastPathComponent.hasPrefix(".") }.compactMap { url -> Snapshot? in
            guard let manifest = try? JSONValue.parse(Data(contentsOf: url.appendingPathComponent("manifest.json"))) else { return nil }
            let imported = manifest["schema_name"]?.stringValue == "ckd_imported_run"
            let results = imported ? try? JSONValue.parse(Data(contentsOf: url.appendingPathComponent("results.json"))) : nil
            return Snapshot(url: url, imported: imported,
                            createdAt: manifest["created_at"]?.stringValue ?? results?["calculated_at"]?.stringValue,
                            revision: manifest["revision"]?.intValue,
                            versions: manifest["versions"] ?? results?["versions"],
                            keepsPreviousResults: manifest["files"]?["previous_results.json"] != nil)
        }.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    static func json(_ value: JSONValue) -> Data { Data(value.prettyJSON().utf8) }

    static func hex(_ count: Int) -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(count))
    }
}
