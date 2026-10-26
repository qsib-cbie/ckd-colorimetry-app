import Foundation

public struct Prediction: Sendable {
    public var status: String
    public var probability: Double?
    public var threshold: Double?
    public var classification: String?
    public var ureaMM: Double?
    public var creatinineUM: Double?
    public var ageYears: Double?
    public var sex: String?
    public var equationVersion: String?
    public var reason: String?
    public var model: String?
    public var modelLabel: String?
    public var modelSource: String?
    public var availableModels: [String]?
    public var auc: Double?

    public var isComplete: Bool { status == "complete" }

    static func notCalculated(_ reason: String) -> Prediction {
        Prediction(status: "not_calculated", reason: reason)
    }

    var json: JSONValue {
        var pairs: [(String, JSONValue)] = [("status", .string(status))]
        if isComplete {
            pairs += [
                ("probability", .number(probability)), ("threshold", .number(threshold)),
                ("classification", .text(classification)), ("urea_mM", .number(ureaMM)),
                ("creatinine_uM", .number(creatinineUM)), ("age_years", .number(ageYears)),
                ("sex", .text(sex)), ("equation_version", .text(equationVersion)),
            ]
        }
        if let reason { pairs.append(("reason", .string(reason))) }
        if let model {
            pairs += [
                ("model", .string(model)), ("model_label", .text(modelLabel)), ("model_source", .text(modelSource)),
                ("available_models", .array((availableModels ?? []).map(JSONValue.string))), ("auc", .number(auc)),
            ]
        }
        return .object(pairs)
    }

    func field(_ key: String) -> CSVCell {
        switch key {
        case "status": return .text(status)
        case "probability": return .number(probability)
        case "threshold": return .number(threshold)
        case "classification": return .string(classification)
        case "urea_mM": return .number(ureaMM)
        case "creatinine_uM": return .number(creatinineUM)
        case "age_years": return .number(ageYears)
        case "sex": return .string(sex)
        case "equation_version": return .string(equationVersion)
        case "reason": return .string(reason)
        case "model": return .string(model)
        case "model_label": return .string(modelLabel)
        case "model_source": return .string(modelSource)
        case "auc": return .number(auc)
        default: return .empty
        }
    }
}

public enum CKDPrediction {
    public static func logistic(_ logit: Double) -> Double {
        logit >= 0 ? 1 / (1 + exp(-logit)) : exp(logit) / (1 + exp(logit))
    }

    public static func classifier(urea: Double?, creatinine: Double?, age: Double?, sex: String?) -> Prediction {
        guard let urea, let creatinine, let age, urea.isFinite, creatinine.isFinite, age.isFinite, age > 0,
              sex == "male" || sex == "female" else {
            return .notCalculated("Final urea, creatinine, age and sex are required.")
        }
        let male = sex == "male" ? 1.0 : 0.0
        let z = CKDEquations.classifierIntercept - CKDEquations.classifierUrea * urea
            - CKDEquations.classifierCreatinine * creatinine - CKDEquations.classifierAge * age
            + CKDEquations.classifierMale * male
        let p = z >= 0 ? exp(-z) / (1 + exp(-z)) : 1 / (1 + exp(z))
        return Prediction(
            status: "complete",
            probability: p,
            threshold: CKDEquations.classifierThreshold,
            classification: p >= CKDEquations.classifierThreshold ? "Predicted G3+" : "Predicted G1-2",
            ureaMM: urea,
            creatinineUM: creatinine,
            ageYears: age,
            sex: sex,
            equationVersion: CKDEquations.classifierVersion
        )
    }

    public static func singleClassifier(_ analyte: String, value: Double?, age: Double?, sex: String?) -> Prediction {
        guard let value, let age, value.isFinite, age.isFinite, age > 0, sex == "male" || sex == "female",
              let c = CKDEquations.singleClassifiers[analyte] else {
            return .notCalculated("Final \(analyte), age and sex are required.")
        }
        let male = sex == "male" ? 1.0 : 0.0
        let p = logistic(c.intercept + c.analyte * value + c.age * age + c.male * male)
        return Prediction(
            status: "complete",
            probability: p,
            threshold: c.threshold,
            classification: p >= c.threshold ? "Predicted G3+" : "Predicted G1-2",
            ureaMM: analyte == "urea" ? value : nil,
            creatinineUM: analyte == "creatinine" ? value : nil,
            ageYears: age,
            sex: sex,
            equationVersion: c.version
        )
    }

    public static func predict(urea: Double?, creatinine: Double?, age: Double?, sex: String?, choice: String?) -> Prediction {
        var available: [String] = []
        if urea != nil && creatinine != nil { available.append("full") }
        if creatinine != nil { available.append("creatinine") }
        if urea != nil { available.append("urea") }
        let model = choice ?? available.first ?? "full"
        var result = model == "full"
            ? classifier(urea: urea, creatinine: creatinine, age: age, sex: sex)
            : singleClassifier(model, value: model == "urea" ? urea : creatinine, age: age, sex: sex)
        if available.isEmpty && choice == nil {
            result.reason = "Final urea or creatinine, age and sex are required."
        }
        result.model = model
        result.modelLabel = CKDEquations.classifierLabels[model]
        result.modelSource = choice != nil ? "manual" : "automatic"
        result.availableModels = available
        result.auc = CKDEquations.singleClassifiers[model]?.auc
        return result
    }
}
