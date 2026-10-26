import Foundation

public extension ConcentrationResults {
    init(stored json: JSONValue) {
        func numbers(_ value: JSONValue?) -> [Double]? { value?.arrayValues?.compactMap(\.doubleValue) }
        func text(_ value: JSONValue?) -> String? { value?.stringValue }

        rois = (json["rois"]?.arrayValues ?? []).compactMap { roi in
            guard let id = roi["id"]?.intValue else { return nil }
            return ROIMeasurement(id: id, label: text(roi["label"]), median: numbers(roi["median"]), mean: numbers(roi["mean"]),
                                  standardDeviation: numbers(roi["standard_deviation"]), pixelCount: roi["pixel_count"]?.intValue,
                                  calibratedMedian: numbers(roi["calibrated_median"]) ?? [], calibratedMean: numbers(roi["calibrated_mean"]))
        }
        reservoirs = (json["reservoirs"]?.arrayValues ?? []).compactMap { r in
            guard let id = r["id"]?.intValue else { return nil }
            let reservoir = ReservoirDraft(
                id: id, analyte: text(r["analyte"]), customName: text(r["custom_name"]) ?? "",
                condition: text(r["condition"]) ?? "", replicate: text(r["replicate"]) ?? "",
                roiIDs: r["roi_ids"]?.arrayValues?.compactMap(\.intValue) ?? [], review: text(r["review"]) ?? "needs_review",
                reason: text(r["reason"]) ?? ""
            )
            let calculation = Calculation(
                value: r["value"]?.doubleValue, calculationStatus: text(r["calculation_status"]) ?? "",
                warnings: r["warnings"]?.arrayValues?.compactMap(\.stringValue) ?? [], ureaPHModel: text(r["urea_ph_model"]),
                unit: text(r["unit"]) ?? "", equationVersion: text(r["equation_version"]) ?? ""
            )
            return ReservoirResult(reservoir: reservoir, calculation: calculation, averageLab: numbers(r["average_lab"]) ?? [],
                                   reviewStatus: text(r["review_status"]) ?? "", uncertainty: Self.uncertainty(r["uncertainty"]))
        }
        summaries = (json["summaries"]?.objectPairs ?? []).map { analyte, s in
            AnalyteSummary(
                analyte: analyte, value: s["value"]?.doubleValue, sd: s["sd"]?.doubleValue, sdBasis: text(s["sd_basis"]),
                unit: text(s["unit"]) ?? "", includedIDs: s["included_ids"]?.arrayValues?.compactMap(\.intValue) ?? [],
                values: (s["values"]?.arrayValues ?? []).compactMap { v in
                    guard let id = v["reservoir_id"]?.intValue, let value = v["value"]?.doubleValue else { return nil }
                    return SummaryValue(reservoirID: id, value: value, condition: text(v["condition"]) ?? "",
                                        replicate: text(v["replicate"]) ?? "")
                },
                minimum: s["min"]?.doubleValue, maximum: s["max"]?.doubleValue, note: text(s["note"]) ?? ""
            )
        }
        phReadyForUrea = { if case .bool(let value)? = json["ph_ready_for_urea"] { return value } else { return false } }()
        outsideCalibration = (json["outside_calibration"]?.arrayValues ?? []).compactMap { flag in
            guard let id = flag["roi_id"]?.intValue else { return nil }
            return CalibrationFlag(roiID: id, channels: flag["channels"]?.arrayValues?.compactMap(\.stringValue) ?? [])
        }
        ureaCalibration = text(json["urea_calibration"])
        let model = json["urea_ph_model"]
        ureaPHModel = UreaModelChoice(source: text(model?["source"]), selected: text(model?["selected"]), nearest: text(model?["nearest"]))
        let p = json["prediction"]
        prediction = Prediction(
            status: text(p?["status"]) ?? "not_calculated", probability: p?["probability"]?.doubleValue,
            threshold: p?["threshold"]?.doubleValue, classification: text(p?["classification"]),
            ureaMM: p?["urea_mM"]?.doubleValue, creatinineUM: p?["creatinine_uM"]?.doubleValue,
            ageYears: p?["age_years"]?.doubleValue, sex: text(p?["sex"]), equationVersion: text(p?["equation_version"]),
            reason: text(p?["reason"]), model: text(p?["model"]), modelLabel: text(p?["model_label"]),
            modelSource: text(p?["model_source"]),
            availableModels: p?["available_models"]?.arrayValues?.compactMap(\.stringValue), auc: p?["auc"]?.doubleValue
        )
    }

    private static func uncertainty(_ value: JSONValue?) -> ReservoirUncertainty {
        guard let value, !value.isNull else { return .none }
        func numbers(_ value: JSONValue?) -> [Double]? { value?.arrayValues?.compactMap(\.doubleValue) }
        let count = value["n_rois"]?.intValue ?? 0
        if value["lab_sd"] != nil {
            return .custom(CustomUncertainty(nROIs: count, labSD: numbers(value["lab_sd"]), rois: (value["rois"]?.arrayValues ?? []).compactMap { roi in
                guard let id = roi["roi_id"]?.intValue else { return nil }
                return CustomSpread(roiID: id, lab: numbers(roi["lab"]) ?? [], pixelSD: numbers(roi["pixel_sd"]))
            }))
        }
        return .standard(StandardUncertainty(
            nROIs: count, roiSD: value["roi_sd"]?.doubleValue, roiMin: value["roi_min"]?.doubleValue,
            roiMax: value["roi_max"]?.doubleValue, sd: value["sd"]?.doubleValue, sdBasis: value["sd_basis"]?.stringValue,
            rois: (value["rois"]?.arrayValues ?? []).compactMap { roi in
                guard let id = roi["roi_id"]?.intValue else { return nil }
                return PixelSpread(roiID: id, value: roi["value"]?.doubleValue, pixelLow: roi["pixel_low"]?.doubleValue,
                                   pixelHigh: roi["pixel_high"]?.doubleValue, pixelSD: roi["pixel_sd"]?.doubleValue)
            }
        ))
    }
}
