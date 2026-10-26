import Foundation

public struct UreaCalibration: Sendable {
    public let label: String
    public let version: String
    public let models: [String: [Double]]
}

public struct SingleClassifier: Sendable {
    public let intercept: Double
    public let analyte: Double
    public let age: Double
    public let male: Double
    public let threshold: Double
    public let auc: Double
    public let version: String
}

public enum CKDEquations {
    public static let configVersion = "ckd_research_2026_10_14"
    public static let flowerVersion = "flower9_printed_lab_regression_2026_07_21"
    public static let analytes = ["ph", "urea", "creatinine"]
    public static let ranges: [String: (minimum: Double, maximum: Double)] = [
        "ph": (6.0, 7.0), "urea": (0.0, 500.0), "creatinine": (0.0, 200.0),
    ]
    public static let units = ["ph": "pH", "urea": "mM", "creatinine": "uM"]
    public static let equations = [
        "ph": "ph_quadratic_screenshot_rounded_v1",
        "urea": "urea_ph_specific_screenshot_rounded_v1",
        "creatinine": "creatinine_inverse_screenshot_rounded_v1",
    ]
    public static let phQuadratic = -10.392
    public static let phLinear = 82.361
    public static let phIntercept = -96.528
    public static let creatinineOffset = 0.705
    public static let creatinineSlope = 0.0112
    public static let creatinineNumerator = 0.856
    public static let creatinineDenominator = 0.00560
    public static let invalidDomain = "Invalid equation domain or negative concentration; cannot be included."
    public static let invalidIncluded = "Invalid equation domain or negative concentration; included by the reviewer, "
        + "so it counts in the averages, the prediction and the export."

    public static let ureaCalibrations: [String: UreaCalibration] = [
        "lab": UreaCalibration(label: "L*a*b* (2026-07-21)", version: equations["urea"]!, models: [
            "pH_6.0": [328.758, -3.707, 0.409, 0],
            "pH_6.5": [91.418, -0.014, 0, -1.639],
            "pH_7.0": [592.133, -5.940, -2.399, -0.925],
        ]),
        "ab": UreaCalibration(label: "a*b* only (2026-10-12)", version: "urea_ph_specific_ab_2026_10_12", models: [
            "pH_6.0": [15.7643, 0, 1.7388, -0.3501],
            "pH_6.5": [43.5382, 0, 0.8451, -0.8451],
            "pH_7.0": [31.5956, 0, 0.7921, -0.7921],
        ]),
    ]
    public static let ureaModelLimits = (low: 6.25, high: 6.75)
    public static let classifierIntercept = 6.28
    public static let classifierUrea = 0.25
    public static let classifierCreatinine = 0.15
    public static let classifierAge = 0.03
    public static let classifierMale = 0.42
    public static let classifierThreshold = 0.305
    public static let classifierVersion = "g3_logistic_collaborator_v1"
    public static let singleClassifiers: [String: SingleClassifier] = [
        "creatinine": SingleClassifier(intercept: -5.1855, analyte: 0.2463, age: 0.0494, male: 0.319,
                                       threshold: 0.579, auc: 0.923, version: "g3_logistic_creatinine_age_sex_2026_10_12"),
        "urea": SingleClassifier(intercept: -6.0376, analyte: 0.3449, age: 0.0359, male: -0.5728,
                                 threshold: 0.422, auc: 0.947, version: "g3_logistic_urea_age_sex_2026_10_12"),
    ]
    public static let classifierLabels = [
        "full": "Urea + creatinine + age + sex",
        "creatinine": "Creatinine + age + sex",
        "urea": "Urea + age + sex",
    ]

    public static func ureaModel(_ ph: Double?) -> String? {
        guard let ph, ph.isFinite else { return nil }
        return ph <= ureaModelLimits.low ? "pH_6.0" : ph <= ureaModelLimits.high ? "pH_6.5" : "pH_7.0"
    }

    public static func phValue(_ lab: [Double]) -> Double? {
        let d = phLinear * phLinear - 4 * phQuadratic * (phIntercept - lab[2])
        return d >= 0 ? (-phLinear - sqrt(d)) / (2 * phQuadratic) : nil
    }

    public static func creatinineValue(_ lab: [Double]) -> Double? {
        let d = creatinineOffset - creatinineSlope * lab[1]
        return d >= 0 ? (creatinineNumerator - sqrt(d)) / creatinineDenominator : nil
    }

    public static func ureaValue(_ lab: [Double], model: String, calibration: String = "lab") -> Double {
        let coefficients = ureaCalibrations[calibration]!.models[model]!
        return zip(coefficients, [1.0] + lab).reduce(0.0) { $0 + $1.0 * $1.1 }
    }

    public static func equationVersion(_ analyte: String, model: String? = nil, ureaCalibration: String = "lab") -> String {
        if analyte == "urea" {
            return ureaCalibrations[ureaCalibration]!.version + (model.map { ":" + $0 } ?? "")
        }
        return equations[analyte] ?? ""
    }

    public static func calculate(
        _ analyte: String,
        lab: [Double],
        ph: Double? = nil,
        manualModel: String? = nil,
        ureaCalibration: String = "lab"
    ) -> Calculation {
        var warnings: [String] = []
        var model: String?
        var value: Double?
        var status = "valid"
        if analyte != "urea" {
            value = analyte == "ph" ? phValue(lab) : creatinineValue(lab)
        } else if let manualModel {
            model = manualModel
            value = ureaValue(lab, model: manualModel, calibration: ureaCalibration)
        } else if let ph, ph.isFinite {
            let chosen = ureaModel(ph)!
            model = chosen
            value = ureaValue(lab, model: chosen, calibration: ureaCalibration)
            if !(6 <= ph && ph <= 7) {
                warnings.append("Endpoint urea model used outside the pH calibration range.")
            }
        } else {
            status = "missing_input"
            warnings.append("Reviewed pH is required for final urea, or choose a urea pH model.")
        }
        if status == "valid" && (value == nil || !value!.isFinite || value! < 0) {
            if let current = value, !current.isFinite {
                value = nil
            }
            status = "invalid_domain"
            warnings.append(invalidDomain)
        }
        if let value, let range = ranges[analyte], !(range.minimum <= value && value <= range.maximum) {
            warnings.append("Outside the provisional software review range.")
        }
        return Calculation(
            value: value,
            calculationStatus: status,
            warnings: warnings,
            ureaPHModel: model,
            unit: units[analyte] ?? "",
            equationVersion: equationVersion(analyte, model: value != nil ? model : nil, ureaCalibration: ureaCalibration)
        )
    }
}

public struct Calculation: Sendable {
    public var value: Double?
    public var calculationStatus: String
    public var warnings: [String]
    public var ureaPHModel: String?
    public var unit: String
    public var equationVersion: String
}
