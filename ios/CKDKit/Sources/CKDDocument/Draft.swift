import CKDImage
import CKDResults
import Foundation

public struct DocumentError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct DraftROI: Sendable, Equatable {
    public var id: Int
    public var label: String
    public var points: [QCamPoint]

    public init(id: Int, label: String, points: [QCamPoint]) {
        self.id = id
        self.label = label
        self.points = points
    }
}

public struct Draft: Sendable {
    public static let maximumReservoirs = 1000
    public static let maximumROIs = 5000
    public static let modes: Set<String> = ["flower_9", "flower_9_manual", "standard_24_grid"]

    public var title = "Untitled analysis"
    public var mode = "flower_9"
    public var whiteBalance: [QCamPoint] = []
    public var corners: [QCamPoint] = []
    public var manualPatches: [[QCamPoint]] = []
    public var rois: [DraftROI] = []
    public var reservoirs: [ReservoirDraft] = []
    public var age: Double?
    public var sex: String?
    public var ureaPHModel: String?
    public var ureaCalibration = "lab"
    public var classifierModel: String?

    public init() {}

    public static func newAnalysis(title: String) -> Draft {
        var draft = Draft()
        let trimmed = String(String.UnicodeScalarView(title.unicodeScalars.prefix(120)))
        draft.title = trimmed.isEmpty ? "Untitled analysis" : trimmed
        draft.mode = "flower_9_manual"
        draft.reservoirs = (1...6).map { ReservoirDraft(id: $0) }
        return draft
    }

    public var resultsDraft: ResultsDraft {
        ResultsDraft(mode: mode, reservoirs: reservoirs, age: age, sex: sex, ureaPHModel: ureaPHModel,
                     ureaCalibration: ureaCalibration, classifierModel: classifierModel)
    }

    public init(json: JSONValue) throws {
        guard let pairs = json.objectPairs else { throw DocumentError("The draft must be an object.") }
        let known: Set<String> = ["title", "mode", "white_balance", "corners", "manual_patches", "rois", "reservoirs",
                                  "age", "sex", "urea_ph_model", "urea_calibration", "classifier_model"]
        if let unknown = pairs.first(where: { !known.contains($0.0) }) {
            throw DocumentError("Unknown draft field \(unknown.0).")
        }
        var legacyUrea: [(model: String?, calibration: String?)] = []
        for (key, value) in pairs {
            switch key {
            case "title": title = try Self.text(value, key, minimum: 1, maximum: 120)
            case "mode": mode = try Self.choice(value, key, Self.modes)
            case "white_balance": whiteBalance = try Self.points(value, key, maximum: 128)
            case "corners": corners = try Self.points(value, key, maximum: 4)
            case "manual_patches":
                let patches = try Self.array(value, key, maximum: 9)
                manualPatches = try patches.map { try Self.points($0, key, maximum: Int.max) }
            case "rois":
                rois = try Self.array(value, key, maximum: Self.maximumROIs).map(Self.roi)
            case "reservoirs":
                let values = try Self.array(value, key, maximum: Self.maximumReservoirs)
                reservoirs = try values.map(Self.reservoir)
                legacyUrea = try values.map {
                    (try Self.optionalChoice($0["urea_ph_model"] ?? .null, "urea_ph_model", ["auto", "pH_6.0", "pH_6.5", "pH_7.0"]),
                     try Self.optionalChoice($0["urea_calibration"] ?? .null, "urea_calibration", ["lab", "ab"]))
                }
            case "age":
                if !value.isNull {
                    let number = try Self.number(value, key)
                    guard number > 0 else { throw DocumentError("Age must be greater than 0.") }
                    age = number
                }
            case "sex": sex = try Self.optionalChoice(value, key, ["female", "male"])
            case "urea_ph_model": ureaPHModel = try Self.optionalChoice(value, key, ["pH_6.0", "pH_6.5", "pH_7.0"])
            case "urea_calibration": ureaCalibration = try Self.choice(value, key, ["lab", "ab"])
            case "classifier_model": classifierModel = try Self.optionalChoice(value, key, ["full", "creatinine", "urea"])
            default: break
            }
        }
        liftReservoirUreaSettings(legacyUrea)
        try normalize()
    }

    /// Older Mac files may carry per-reservoir urea choices; a choice shared by every urea reservoir
    /// becomes the analysis setting and differing ones are dropped, as on the Mac.
    mutating func liftReservoirUreaSettings(_ legacy: [(model: String?, calibration: String?)]) {
        let urea = zip(reservoirs, legacy).filter { $0.0.analyte == "urea" }.map(\.1)
        let models = Set(urea.map { $0.model == nil ? ureaPHModel ?? "" : $0.model == "auto" ? "" : $0.model! })
        let calibrations = Set(urea.map { $0.calibration ?? ureaCalibration })
        if models.count == 1, let model = models.first { ureaPHModel = model.isEmpty ? nil : model }
        if calibrations.count == 1, let calibration = calibrations.first { ureaCalibration = calibration }
    }

    public mutating func normalize() throws {
        func dropClosing(_ points: inout [QCamPoint]) {
            if points.count > 3, points.first == points.last { points.removeLast() }
        }
        dropClosing(&whiteBalance)
        for index in manualPatches.indices { dropClosing(&manualPatches[index]) }
        for index in rois.indices { dropClosing(&rois[index].points) }
        guard Set(rois.map(\.id)).count == rois.count else { throw DocumentError("ROI IDs must be unique.") }
        guard Set(reservoirs.map(\.id)).count == reservoirs.count else { throw DocumentError("Reservoir IDs must be unique.") }
        let assigned = reservoirs.flatMap(\.roiIDs)
        guard Set(assigned).count == assigned.count else { throw DocumentError("Each ROI can belong to only one reservoir.") }
        guard Set(assigned).isSubset(of: Set(rois.map(\.id))) else { throw DocumentError("An assigned ROI is missing.") }
    }

    public var json: JSONValue {
        func points(_ values: [QCamPoint]) -> JSONValue {
            .array(values.map { .object([("x", .double($0.x)), ("y", .double($0.y))]) })
        }
        return .object([
            ("title", .string(title)), ("mode", .string(mode)), ("white_balance", points(whiteBalance)),
            ("corners", points(corners)), ("manual_patches", .array(manualPatches.map(points))),
            ("rois", .array(rois.map { .object([("id", .int($0.id)), ("label", .string($0.label)), ("points", points($0.points))]) })),
            ("reservoirs", .array(reservoirs.map {
                .object([
                    ("id", .int($0.id)), ("analyte", .text($0.analyte)), ("custom_name", .string($0.customName)),
                    ("condition", .string($0.condition)), ("replicate", .string($0.replicate)),
                    ("roi_ids", .array($0.roiIDs.map(JSONValue.int))), ("review", .string($0.review)), ("reason", .string($0.reason)),
                ])
            })),
            ("age", .number(age)), ("sex", .text(sex)), ("urea_ph_model", .text(ureaPHModel)),
            ("urea_calibration", .string(ureaCalibration)), ("classifier_model", .text(classifierModel)),
        ])
    }

    private static func roi(_ value: JSONValue) throws -> DraftROI {
        guard let pairs = value.objectPairs else { throw DocumentError("An ROI must be an object.") }
        guard Set(pairs.map(\.0)).isSubset(of: ["id", "label", "points"]) else { throw DocumentError("Unknown ROI field.") }
        let id = try integer(value["id"] ?? .null, "ROI id")
        guard id > 0 else { throw DocumentError("ROI IDs must be positive.") }
        return DraftROI(id: id, label: try text(value["label"] ?? .null, "ROI label", minimum: 1, maximum: 80),
                        points: try points(value["points"] ?? .null, "ROI points", minimum: 3, maximum: 128))
    }

    private static func reservoir(_ value: JSONValue) throws -> ReservoirDraft {
        guard let pairs = value.objectPairs else { throw DocumentError("A reservoir must be an object.") }
        let known: Set<String> = ["id", "analyte", "custom_name", "condition", "replicate", "roi_ids", "review", "reason",
                                  "urea_ph_model", "urea_calibration"]
        guard Set(pairs.map(\.0)).isSubset(of: known) else { throw DocumentError("Unknown reservoir field.") }
        let id = try integer(value["id"] ?? .null, "reservoir id")
        guard (1...maximumReservoirs).contains(id) else { throw DocumentError("Reservoir IDs must be 1 to \(maximumReservoirs).") }
        let roiIDs = try array(value["roi_ids"] ?? .array([]), "roi_ids", maximum: maximumROIs).map { try integer($0, "roi_ids") }
        return ReservoirDraft(
            id: id,
            analyte: try optionalChoice(value["analyte"] ?? .null, "analyte", ["ph", "urea", "creatinine", "custom"]),
            customName: try text(value["custom_name"] ?? .string(""), "custom_name", minimum: 0, maximum: 80),
            condition: try text(value["condition"] ?? .string(""), "condition", minimum: 0, maximum: 80),
            replicate: try text(value["replicate"] ?? .string(""), "replicate", minimum: 0, maximum: 40),
            roiIDs: roiIDs,
            review: try choice(value["review"] ?? .string("needs_review"), "review", ["needs_review", "included", "excluded"]),
            reason: try text(value["reason"] ?? .string(""), "reason", minimum: 0, maximum: 500)
        )
    }

    private static func array(_ value: JSONValue, _ key: String, maximum: Int) throws -> [JSONValue] {
        guard let values = value.arrayValues else { throw DocumentError("\(key) must be a list.") }
        guard values.count <= maximum else { throw DocumentError("\(key) has more than \(maximum) items.") }
        return values
    }

    private static func points(_ value: JSONValue, _ key: String, minimum: Int = 0, maximum: Int) throws -> [QCamPoint] {
        let values = try array(value, key, maximum: maximum)
        guard values.count >= minimum else { throw DocumentError("\(key) needs at least \(minimum) points.") }
        return try values.map { point in
            guard let pairs = point.objectPairs, Set(pairs.map(\.0)) == ["x", "y"] else {
                throw DocumentError("\(key) points need x and y.")
            }
            return QCamPoint(x: try number(point["x"]!, key), y: try number(point["y"]!, key))
        }
    }

    private static func number(_ value: JSONValue, _ key: String) throws -> Double {
        guard let number = value.doubleValue, number.isFinite else { throw DocumentError("\(key) must be a finite number.") }
        return number
    }

    private static func integer(_ value: JSONValue, _ key: String) throws -> Int {
        if let number = value.intValue { return number }
        if case .double(let number) = value, number.rounded() == number, abs(number) < 1e15 { return Int(number) }
        throw DocumentError("\(key) must be an integer.")
    }

    private static func text(_ value: JSONValue, _ key: String, minimum: Int, maximum: Int) throws -> String {
        guard let text = value.stringValue else { throw DocumentError("\(key) must be text.") }
        let length = text.unicodeScalars.count
        guard length >= minimum, length <= maximum else { throw DocumentError("\(key) must be \(minimum) to \(maximum) characters.") }
        return text
    }

    private static func choice(_ value: JSONValue, _ key: String, _ options: Set<String>) throws -> String {
        guard let text = value.stringValue, options.contains(text) else { throw DocumentError("\(key) has an unsupported value.") }
        return text
    }

    private static func optionalChoice(_ value: JSONValue, _ key: String, _ options: Set<String>) throws -> String? {
        value.isNull ? nil : try choice(value, key, options)
    }
}

public enum PolygonRules {
    public static func validate(_ points: [QCamPoint], width: Int, height: Int) throws -> [QCamPoint] {
        var p = points
        if p.count > 1, p.first == p.last { p.removeLast() }
        guard (3...128).contains(p.count), p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw DocumentError("A polygon needs 3 to 128 finite vertices.")
        }
        guard p.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.x <= Double(width - 1) && $0.y <= Double(height - 1) }) else {
            throw DocumentError("Polygon vertices must stay inside the original image.")
        }
        guard Set(p).count == p.count else { throw DocumentError("Polygon vertices must be unique.") }
        var a = 0.0
        var b = 0.0
        for i in p.indices {
            let previous = p[(i + p.count - 1) % p.count]
            a += p[i].x * previous.y
            b += p[i].y * previous.x
        }
        guard abs(a - b) / 2 >= 0.5 else { throw DocumentError("Polygon area is too small.") }
        let n = p.count
        for i in 0..<n {
            for j in (i + 1)..<n where !(j == i + 1 || (i == 0 && j == n - 1)) {
                if segmentsIntersect(p[i], p[(i + 1) % n], p[j], p[(j + 1) % n]) {
                    throw DocumentError("A polygon must not cross or touch itself.")
                }
            }
        }
        return p
    }

    private static func cross(_ a: QCamPoint, _ b: QCamPoint, _ c: QCamPoint) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func segmentsIntersect(_ a: QCamPoint, _ b: QCamPoint, _ c: QCamPoint, _ d: QCamPoint) -> Bool {
        let values = [cross(a, b, c), cross(a, b, d), cross(c, d, a), cross(c, d, b)]
        if values[0] * values[1] < 0 && values[2] * values[3] < 0 { return true }
        for (value, p, q, r) in [(values[0], a, b, c), (values[1], a, b, d), (values[2], c, d, a), (values[3], c, d, b)] {
            if abs(value) < 1e-9,
               r.x >= min(p.x, q.x) - 1e-9, r.y >= min(p.y, q.y) - 1e-9,
               r.x <= max(p.x, q.x) + 1e-9, r.y <= max(p.y, q.y) + 1e-9 {
                return true
            }
        }
        return false
    }
}
