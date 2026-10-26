import Foundation

public struct ReservoirDraft: Codable, Sendable {
    public var id: Int
    public var analyte: String?
    public var customName: String
    public var condition: String
    public var replicate: String
    public var roiIDs: [Int]
    public var review: String
    public var reason: String

    public init(id: Int, analyte: String? = nil, customName: String = "", condition: String = "", replicate: String = "",
                roiIDs: [Int] = [], review: String = "needs_review", reason: String = "") {
        self.id = id
        self.analyte = analyte
        self.customName = customName
        self.condition = condition
        self.replicate = replicate
        self.roiIDs = roiIDs
        self.review = review
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case id, analyte, condition, replicate, review, reason
        case customName = "custom_name"
        case roiIDs = "roi_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(Int.self, forKey: .id),
            analyte: try c.decodeIfPresent(String.self, forKey: .analyte),
            customName: try c.decodeIfPresent(String.self, forKey: .customName) ?? "",
            condition: try c.decodeIfPresent(String.self, forKey: .condition) ?? "",
            replicate: try c.decodeIfPresent(String.self, forKey: .replicate) ?? "",
            roiIDs: try c.decodeIfPresent([Int].self, forKey: .roiIDs) ?? [],
            review: try c.decodeIfPresent(String.self, forKey: .review) ?? "needs_review",
            reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        )
    }

    var json: [(String, JSONValue)] {
        [
            ("id", .int(id)), ("analyte", .text(analyte)), ("custom_name", .string(customName)),
            ("condition", .string(condition)), ("replicate", .string(replicate)),
            ("roi_ids", .array(roiIDs.map(JSONValue.int))), ("review", .string(review)), ("reason", .string(reason)),
        ]
    }
}

public struct ResultsDraft: Codable, Sendable {
    public var mode: String
    public var reservoirs: [ReservoirDraft]
    public var age: Double?
    public var sex: String?
    public var ureaPHModel: String?
    public var ureaCalibration: String
    public var classifierModel: String?

    public init(mode: String = "flower_9", reservoirs: [ReservoirDraft] = [], age: Double? = nil, sex: String? = nil,
                ureaPHModel: String? = nil, ureaCalibration: String = "lab", classifierModel: String? = nil) {
        self.mode = mode
        self.reservoirs = reservoirs
        self.age = age
        self.sex = sex
        self.ureaPHModel = ureaPHModel
        self.ureaCalibration = ureaCalibration
        self.classifierModel = classifierModel
    }

    enum CodingKeys: String, CodingKey {
        case mode, reservoirs, age, sex
        case ureaPHModel = "urea_ph_model"
        case ureaCalibration = "urea_calibration"
        case classifierModel = "classifier_model"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try c.decodeIfPresent(String.self, forKey: .mode) ?? "flower_9",
            reservoirs: try c.decodeIfPresent([ReservoirDraft].self, forKey: .reservoirs) ?? [],
            age: try c.decodeIfPresent(Double.self, forKey: .age),
            sex: try c.decodeIfPresent(String.self, forKey: .sex),
            ureaPHModel: try c.decodeIfPresent(String.self, forKey: .ureaPHModel),
            ureaCalibration: try c.decodeIfPresent(String.self, forKey: .ureaCalibration) ?? "lab",
            classifierModel: try c.decodeIfPresent(String.self, forKey: .classifierModel)
        )
    }
}

public struct ROIMeasurement: Codable, Sendable {
    public var id: Int
    public var label: String?
    public var median: [Double]?
    public var mean: [Double]?
    public var standardDeviation: [Double]?
    public var pixelCount: Int?
    public var calibratedMedian: [Double]
    public var calibratedMean: [Double]?

    public init(id: Int, label: String?, median: [Double]?, mean: [Double]?, standardDeviation: [Double]?,
                pixelCount: Int?, calibratedMedian: [Double], calibratedMean: [Double]?) {
        self.id = id
        self.label = label
        self.median = median
        self.mean = mean
        self.standardDeviation = standardDeviation
        self.pixelCount = pixelCount
        self.calibratedMedian = calibratedMedian
        self.calibratedMean = calibratedMean
    }

    enum CodingKeys: String, CodingKey {
        case id, label, median, mean
        case standardDeviation = "standard_deviation"
        case pixelCount = "pixel_count"
        case calibratedMedian = "calibrated_median"
        case calibratedMean = "calibrated_mean"
    }

    var displayLabel: String {
        if let label, !label.isEmpty { return label }
        return "ROI \(id)"
    }

    var json: JSONValue {
        var pairs: [(String, JSONValue)] = [("id", .int(id))]
        if let label { pairs.append(("label", .string(label))) }
        if let median { pairs.append(("median", .numbers(median))) }
        if let mean { pairs.append(("mean", .numbers(mean))) }
        if let standardDeviation { pairs.append(("standard_deviation", .numbers(standardDeviation))) }
        if let pixelCount { pairs.append(("pixel_count", .int(pixelCount))) }
        pairs.append(("calibrated_median", .numbers(calibratedMedian)))
        if let calibratedMean { pairs.append(("calibrated_mean", .numbers(calibratedMean))) }
        return .object(pairs)
    }
}

public struct CalibrationSummary: Codable, Sendable {
    public var coefficients: [[Double]]?
    public var rmse: Double?
    public var referenceLab: [[Double]]?

    public init(coefficients: [[Double]]?, rmse: Double?, referenceLab: [[Double]]?) {
        self.coefficients = coefficients
        self.rmse = rmse
        self.referenceLab = referenceLab
    }

    enum CodingKeys: String, CodingKey {
        case coefficients, rmse
        case referenceLab = "reference_lab"
    }

    public func apply(_ lab: [Double]) -> [Double]? {
        guard let coefficients, coefficients.count == 4 else { return nil }
        let input = lab + [1.0]
        return (0..<3).map { column in
            zip(input, coefficients).reduce(0.0) { $0 + $1.0 * $1.1[column] }
        }
    }
}
