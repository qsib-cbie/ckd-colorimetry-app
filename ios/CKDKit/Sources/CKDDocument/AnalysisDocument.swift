import CKDImage
import CKDResults
import CryptoKit
import Foundation

public struct VersionComparison: Sendable, Equatable {
    public let calculatedOn: String
    public let calculatedWith: String
    public let differing: [String]
    public let affectsValues: Bool
    public let needsRemeasure: Bool

    public var outdated: Bool { !differing.isEmpty }
}

public enum CKDVersions {
    public static let app = "2.2.0"
    public static let engine = "0.1.1"
    public static let platform = "ios"
    public static let comparedKeys = ["app", "engine", "configuration", "flower_reference", "libraw"]
    public static let measurementKeys: Set<String> = ["engine", "flower_reference", "libraw"]

    public static var current: JSONValue {
        .object([
            ("app", .string(app)), ("engine", .string(engine)), ("configuration", .string(CKDEquations.configVersion)),
            ("flower_reference", .string(CKDEquations.flowerVersion)), ("platform", .string(platform)),
            ("libraw", .string(QCamRawImport.libRawVersionTriple)),
        ])
    }

    public static func compare(_ saved: JSONValue?) -> VersionComparison {
        let differing = comparedKeys.filter { (saved?[$0] ?? .null) != current[$0] }
        let remeasure = differing.contains { measurementKeys.contains($0) }
        return VersionComparison(
            calculatedOn: saved?["platform"]?.stringValue == platform ? "ios" : "mac",
            calculatedWith: saved?["app"]?.stringValue ?? "1.2 or earlier",
            differing: differing,
            affectsValues: remeasure || differing.contains("configuration"),
            needsRemeasure: remeasure
        )
    }

    public static func affectsValues(_ saved: JSONValue?) -> Bool {
        compare(saved).affectsValues
    }

    static func tuple(_ value: String?) -> [Int] {
        guard let value else { return [] }
        let parts = value.split(separator: ".").prefix(3).map { Int($0) }
        return parts.contains(nil) ? [] : parts.compactMap { $0 }
    }

    static func isNewer(_ saved: String?) -> Bool {
        let savedTuple = tuple(saved)
        return !savedTuple.isEmpty && tuple(app).lexicographicallyPrecedes(savedTuple)
    }
}

public enum Clock {
    public static func now() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxx"
        return formatter.string(from: Date())
    }
}

public struct AnalysisDocument: Sendable {
    public static let topLevelKeys = ["render", "white_balance", "calibration", "results", "export", "job"]
    public private(set) var root: JSONValue
    public private(set) var draft: Draft

    public init(data: Data) throws {
        guard data.count <= 16 * 1024 * 1024 else { throw DocumentError("Project metadata is too large.") }
        let root: JSONValue
        do {
            root = try JSONValue.parse(data)
        } catch {
            throw DocumentError("Cannot read analysis.ckd.json. Restore the last valid project backup.")
        }
        try self.init(root: root)
    }

    public init(root: JSONValue) throws {
        do {
            draft = try Self.check(root)
        } catch {
            let savedWith = root["saved_with"]?.stringValue
            if CKDVersions.isNewer(savedWith) {
                throw DocumentError("This analysis was saved by CKD Colorimetry \(savedWith!). Update this app to open it.")
            }
            throw error
        }
        var normalized = root
        for key in Self.topLevelKeys where normalized[key] == nil {
            normalized = normalized.setting(key, .null)
        }
        self.root = normalized.setting("draft", draft.json)
    }

    public static func new(filename: String, sha256: String, bytes: Int) -> AnalysisDocument {
        let id = UUID().uuidString.lowercased()
        let stem = (filename as NSString).deletingPathExtension
        let draft = Draft.newAnalysis(title: stem)
        let now = Clock.now()
        let root: JSONValue = .object([
            ("id", .string(id)), ("revision", .int(0)), ("created_at", .string(now)), ("updated_at", .string(now)),
            ("source", .object([("filename", .string(filename)), ("file", .string("original/" + filename)),
                                ("sha256", .string(sha256)), ("bytes", .int(bytes))])),
            ("draft", draft.json), ("render", .null), ("white_balance", .null), ("calibration", .null),
            ("results", .null), ("export", .null), ("job", .null),
        ])
        return try! AnalysisDocument(root: portable(root))
    }

    static func portable(_ root: JSONValue) -> JSONValue {
        let id = root["analysis_id"]?.stringValue ?? root["id"]?.stringValue ?? ""
        return root.setting("id", .string(id)).setting("analysis_id", .string(id))
            .setting("schema_name", .string("ckd_project")).setting("schema_version", .int(1))
            .removing("project_path").removing("read_only")
    }

    static func check(_ root: JSONValue) throws -> Draft {
        guard root["schema_name"]?.stringValue == "ckd_project", root["schema_version"]?.intValue == 1 else {
            throw DocumentError("Unsupported project version. Open this folder with a compatible CKD app.")
        }
        for key in ["id", "revision", "source", "draft", "created_at", "updated_at"] where root[key] == nil {
            throw DocumentError("The project metadata is incomplete.")
        }
        guard root["revision"]?.intValue != nil else { throw DocumentError("The project metadata is incomplete.") }
        let draft = try Draft(json: root["draft"]!)
        var paths = [root["source"]?["file"]?.stringValue ?? ""]
        for name in ["render", "white_balance"] {
            if let block = root[name], !block.isNull {
                paths += ["array", "preview"].map { block[$0]?.stringValue ?? "" }
            }
        }
        if let export = root["export"], !export.isNull {
            paths.append(export["file"]?.stringValue ?? "")
        }
        for path in paths {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw DocumentError("The project contains an invalid artifact path.")
            }
        }
        return draft
    }

    public var analysisID: String { root["analysis_id"]?.stringValue ?? root["id"]?.stringValue ?? "" }
    public var revision: Int { root["revision"]?.intValue ?? 0 }
    public var source: JSONValue { root["source"] ?? .null }
    public var sourceFilename: String { source["filename"]?.stringValue ?? "" }
    public var sourceFile: String { source["file"]?.stringValue ?? "" }
    public var sourceSHA256: String { source["sha256"]?.stringValue ?? "" }
    public var width: Int? { source["width"]?.intValue }
    public var height: Int? { source["height"]?.intValue }

    public subscript(key: String) -> JSONValue? {
        guard let value = root[key], !value.isNull else { return nil }
        return value
    }

    public var identity: AnalysisIdentity {
        AnalysisIdentity(analysisID: analysisID, analysisTitle: draft.title, sourceFilename: sourceFilename)
    }

    public mutating func set(_ key: String, _ value: JSONValue?) {
        root = root.setting(key, value ?? .null)
    }

    public mutating func setSource(width: Int, height: Int) {
        set("source", source.setting("width", .int(width)).setting("height", .int(height)))
    }

    public mutating func replaceDraft(_ draft: Draft) throws {
        var normalized = draft
        try normalized.normalize()
        self.draft = normalized
        root = root.setting("draft", normalized.json)
    }

    mutating func assignNewID() {
        let previous = analysisID
        let id = UUID().uuidString.lowercased()
        root = root.setting("id", .string(id)).setting("analysis_id", .string(id))
            .setting("copied_from", .object([("analysis_id", .string(previous)), ("copied_at", .string(Clock.now()))]))
    }

    mutating func stamp(revision: Int) {
        root = root.setting("revision", .int(revision)).setting("updated_at", .string(Clock.now()))
    }

    public func encoded() -> Data {
        let value = Self.portable(root).setting("saved_with", .string(CKDVersions.app))
        return Data((value.prettyJSON() + "\n").utf8)
    }

    public var calibrationSummary: CalibrationSummary? {
        guard let calibration = self["calibration"] else { return nil }
        return CalibrationSummary(
            coefficients: calibration["coefficients"]?.arrayValues?.map { $0.arrayValues?.compactMap(\.doubleValue) ?? [] },
            rmse: calibration["rmse"]?.doubleValue,
            referenceLab: calibration["reference_lab"]?.arrayValues?.map { $0.arrayValues?.compactMap(\.doubleValue) ?? [] }
        )
    }

    public var roiMeasurements: [ROIMeasurement] {
        (self["results"]?["rois"]?.arrayValues ?? []).compactMap { roi in
            func lab(_ key: String) -> [Double]? { roi[key]?.arrayValues?.compactMap(\.doubleValue) }
            guard let id = roi["id"]?.intValue, let calibrated = lab("calibrated_median") else { return nil }
            return ROIMeasurement(id: id, label: roi["label"]?.stringValue, median: lab("median"), mean: lab("mean"),
                                  standardDeviation: lab("standard_deviation"), pixelCount: roi["pixel_count"]?.intValue,
                                  calibratedMedian: calibrated, calibratedMean: lab("calibrated_mean"))
        }
    }

    public var versionComparison: VersionComparison? {
        self["results"].map { CKDVersions.compare($0["versions"]) }
    }

    public var resultsAffectedByVersion: Bool {
        versionComparison?.affectsValues ?? false
    }
}

public enum Digest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
