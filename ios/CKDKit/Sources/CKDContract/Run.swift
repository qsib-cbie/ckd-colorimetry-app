import CKDDocument
import CKDResults
import Foundation

enum StatsRun {
    static func scaled(_ value: JSONValue, by factor: Double) -> JSONValue {
        if let pairs = value.objectPairs {
            if pairs.count == 2, let x = value["x"]?.doubleValue, let y = value["y"]?.doubleValue {
                return .object([("x", .double(x * factor + 0.5)), ("y", .double(y * factor + 0.5))])
            }
            return .object(pairs.map { ($0.0, scaled($0.1, by: factor)) })
        }
        return value.arrayValues.map { .array($0.map { scaled($0, by: factor) }) } ?? value
    }

    static func peakMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return (Double(usage.ru_maxrss) / 1_048_576 * 10).rounded() / 10
    }

    static func run(document documentURL: URL, raw: URL, scale: Double, output: URL) throws {
        let mac = try AnalysisDocument(root: try JSONValue.parse(Data(contentsOf: documentURL)))
        var package = CoordinatePackage.export(mac)
        if scale != 1 {
            package = scaled(package, by: scale)
                .setting("source_image_sha256", .string(try Digest.sha256(file: raw)))
                .setting("image_dimensions", .object([("width", .int(Int(Double(mac.width ?? 0) * scale))),
                                                      ("height", .int(Int(Double(mac.height ?? 0) * scale)))]))
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var stages: [(String, JSONValue)] = []
        func stage<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            let start = Date()
            let value = try body()
            stages.append((name, .object([("seconds", .double((Date().timeIntervalSince(start) * 1e4).rounded() / 1e4)),
                                          ("peak_rss_mb", .double(peakMB()))])))
            return value
        }
        var (folder, document) = try AnalysisFolder.create(importing: raw, in: output)
        let initial = try stage("render") { try AnalysisPipeline.render(&document, folder: folder) }
        document = try folder.save(document, expectedRevision: document.revision)
        var draft = try CoordinatePackage.importDraft(package, into: document)
        try AnalysisPipeline.apply(draft, to: &document, imported: true)
        draft = document.draft
        draft.age = mac.draft.age
        draft.sex = mac.draft.sex
        draft.classifierModel = mac.draft.classifierModel
        draft.ureaPHModel = mac.draft.ureaPHModel
        draft.ureaCalibration = mac.draft.ureaCalibration
        try AnalysisPipeline.apply(draft, to: &document)
        let balanced = try stage("white_balance") { try AnalysisPipeline.whiteBalance(&document, folder: folder, initial: initial) }
        try stage("calibrate") { try AnalysisPipeline.calibrate(&document, image: balanced) }
        try stage("analyze") { try AnalysisPipeline.analyze(&document, image: balanced) }
        let identity = document.identity
        var tables = CKDTables.export(ConcentrationResults(stored: document["results"] ?? .null), identity: identity)
        tables["04_roi_measurements.csv"] = try MeasurementTables.roiMeasurements(balanced, document: document, identity: identity)
        if let calibration = document["calibration"] {
            tables["03_colorchecker_patch_measurements.csv"] = try MeasurementTables.patchMeasurements(
                balanced, calibration: calibration, identity: identity)
        }
        let summary: JSONValue = .object([
            ("stages", .object(stages)),
            ("size", .array([.int(initial.height), .int(initial.width)])),
            ("render_sha", .string(Digest.sha256(initial.data))), ("wb_sha", .string(Digest.sha256(balanced.data))),
            ("wb_multipliers", document["white_balance"]?["white_balance"] ?? .null),
            ("calibration", document["calibration"] ?? .null), ("results", document["results"] ?? .null),
            ("identity", .object([("analysis_id", .string(identity.analysisID)), ("analysis_title", .string(identity.analysisTitle)),
                                  ("source_filename", .string(identity.sourceFilename))])),
            ("tables", .object(tables.keys.sorted().map { ($0, .string(tables[$0]!)) })),
        ])
        try Data(summary.prettyJSON().utf8).write(to: output.appendingPathComponent("ios.json"))
        print("Wrote \(output.appendingPathComponent("ios.json").path)")
    }
}
