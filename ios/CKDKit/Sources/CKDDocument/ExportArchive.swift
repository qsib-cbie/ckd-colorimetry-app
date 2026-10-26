import CKDImage
import CKDResults
import Foundation
import ZIPFoundation

public enum ExportArchive {
    public static func write(_ document: AnalysisDocument, folder: AnalysisFolder, image: QCamRGBAImage,
                             initial: QCamRGBAImage? = nil, to destination: URL) throws {
        guard let results = document["results"] else { throw DocumentError("Analyze before exporting results.") }
        let identity = document.identity
        var files: [(String, JSONValue)] = []
        let archive = try Archive(url: destination, accessMode: .create)

        func add(_ name: String, _ data: Data, compressed: Bool = true) throws {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: compressed ? .deflate : .none) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
            files.append((name, .string(Digest.sha256(data))))
        }
        func json(_ value: JSONValue) -> Data { Data(value.prettyJSON().utf8) }

        let portable = AnalysisDocument.portable(document.root).setting("job", .null).setting("export", .null)
        try add("coordinates.json", json(CoordinatePackage.export(document)))
        try add("results.json", json(results))
        try add("analysis.json", json(portable))
        var tables = CKDTables.export(ConcentrationResults(stored: results), identity: identity)
        tables["04_roi_measurements.csv"] = try MeasurementTables.roiMeasurements(image, document: document, identity: identity)
        if let calibration = document["calibration"] {
            tables["03_colorchecker_patch_measurements.csv"] = try MeasurementTables.patchMeasurements(
                image, calibration: calibration, identity: identity)
        }
        for name in tables.keys.sorted() { try add(name, Data(tables[name]!.utf8)) }
        try add("roi_overlay.png", try Overlay.png(image, rois: document.draft.rois), compressed: false)

        let original = try folder.verifyOriginal(document)
        let originalName = "original/" + document.sourceFilename
        try archive.addEntry(with: originalName, fileURL: original,
                             compressionMethod: original.pathExtension.lowercased() == "cr2" ? .none : .deflate)
        files.append((originalName, .string(document.sourceSHA256)))

        if let initial {
            var rasters = [("01_libraw_initial_rendered", "libraw_initial_camera_wb_rendered_input", initial, document["render"])]
            if let balanced = document["white_balance"] {
                rasters.append(("02_libraw_explicit_wb", "libraw_explicit_wb_analysis_input", image, balanced))
            }
            for (prefix, stage, raster, meta) in rasters {
                let name = "\(prefix)_rgba8888.bin"
                try add(name, raster.data)
                let parameters: JSONValue = .object((meta?.objectPairs ?? []).filter { $0.0 != "array" && $0.0 != "preview" })
                try add("\(prefix)_raster.json", json(.object([
                    ("schema_name", .string("qdaq_ckd_sweat_debug_raster")), ("schema_version", .int(1)),
                    ("stage", .string(stage)), ("coordinate_system", .string("top_left_image_pixels")),
                    ("width", .int(raster.width)), ("height", .int(raster.height)), ("source_numpy_dtype", .string("uint8")),
                    ("format", .string("raw_interleaved_rgba8888")), ("byte_order", .string("R,G,B,A")),
                    ("row_stride_bytes", .int(raster.width * 4)), ("rgba8888_filename", .string(name)),
                    ("rgba8888_sha256", .string(Digest.sha256(raster.data))),
                    ("source_image_filename", .string(document.sourceFilename)),
                    ("source_image_sha256", .string(document.sourceSHA256)),
                    ("render_method", .string(QCamRawImport.renderMethod)), ("render_parameters", parameters),
                ])))
            }
        }
        let manifest: JSONValue = .object([
            ("schema_name", .string("ckd_export")), ("schema_version", .int(1)),
            ("analysis_id", .string(document.analysisID)), ("revision", .int(document.revision)),
            ("exported_at", .string(Clock.now())), ("versions", results["versions"] ?? .object([])),
            ("exported_with", CKDVersions.current), ("source", document.source),
            ("coordinate_system", .string("top_left_image_pixels")), ("files", .object(files)),
        ])
        let data = json(manifest)
        try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(data.count),
                             compressionMethod: .deflate) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }

    public static func read(_ zip: URL, into parent: URL) throws -> (AnalysisFolder, AnalysisDocument) {
        let archive = try Archive(url: zip, accessMode: .read)
        var names = Set<String>()
        var total: Int64 = 0
        for entry in archive {
            let name = entry.path
            guard !names.contains(name), entry.type == .file, !name.hasPrefix("/"),
                  !name.split(separator: "/").contains(".."), !name.contains("\\") else {
                throw DocumentError("The archive contains duplicate or unsafe paths.")
            }
            names.insert(name)
            total += Int64(entry.uncompressedSize)
            guard entry.uncompressedSize <= 1 << 30, total <= 4 << 30 else {
                throw DocumentError("The archive exceeds the supported import size.")
            }
        }
        guard let manifestEntry = archive["manifest.json"] else { throw DocumentError("This file is not a CKD export ZIP.") }
        var manifestData = Data()
        _ = try archive.extract(manifestEntry) { manifestData.append($0) }
        let manifest = try JSONValue.parse(manifestData)
        guard ["ckd_export", "ckd_web_export"].contains(manifest["schema_name"]?.stringValue ?? ""),
              manifest["schema_version"]?.intValue == 1, let files = manifest["files"]?.objectPairs else {
            throw DocumentError("Choose a CKD result ZIP containing an original image and analysis.json.")
        }
        guard names == Set(files.map(\.0)).union(["manifest.json"]) else {
            throw DocumentError("The export manifest does not match its contents.")
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("ckd-import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        for (name, expected) in files {
            let destination = staging.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(archive[name]!, to: destination)
            guard try Digest.sha256(file: destination) == expected.stringValue else {
                throw DocumentError("Export checksum mismatch: \(name)")
            }
        }
        var root = try JSONValue.parse(Data(contentsOf: staging.appendingPathComponent("analysis.json")))
        let filename = (root["source"]?["filename"]?.stringValue ?? "").replacingOccurrences(of: "\\", with: "/")
        let base = (filename as NSString).lastPathComponent
        let original = staging.appendingPathComponent("original/" + (root["source"]?["filename"]?.stringValue ?? ""))
        guard FileManager.default.fileExists(atPath: original.path),
              try Digest.sha256(file: original) == root["source"]?["sha256"]?.stringValue else {
            throw DocumentError("The original image hash does not match the saved analysis.")
        }
        root = root.setting("source", (root["source"] ?? .null).setting("file", .string("original/" + base)))
        root = root.setting("analysis_id", .string(root["analysis_id"]?.stringValue ?? root["id"]?.stringValue ?? ""))
        root = root.removing("owner_id").removing("access")
        for field in ["render", "white_balance"] {
            guard var block = root[field], !block.isNull else { continue }
            for key in ["array", "preview"] {
                let old = block[key]?.stringValue ?? ""
                block = block.setting(key, .string(".cache/" + (old as NSString).lastPathComponent))
            }
            root = root.setting(field, block)
        }
        root = root.setting("export", .null)
        if let job = root["job"], ["queued", "running"].contains(job["status"]?.stringValue ?? "") {
            root = root.setting("job", job.setting("status", .string("failed"))
                .setting("error", .string("This job was interrupted before import. Retry the calculation.")))
        }
        let document = try AnalysisDocument(root: AnalysisDocument.portable(root))
        let staged = parent.appendingPathComponent(".import-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))
        do {
            try FileManager.default.createDirectory(at: staged.appendingPathComponent("original"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: original, to: staged.appendingPathComponent("original/" + base))
            try RunHistory.recordImport(document, extras: Dictionary(uniqueKeysWithValues: files.map { ($0.0, staging.appendingPathComponent($0.0)) }),
                                        in: staged)
            try AnalysisFolder.atomicWrite(document.encoded(), to: staged.appendingPathComponent(AnalysisFolder.documentName))
            let destination = try AnalysisFolder.publish(staged, in: parent, name: document.draft.title)
            return (AnalysisFolder(url: destination), document)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }
}
