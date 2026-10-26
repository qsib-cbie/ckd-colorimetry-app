import Foundation

public struct PixelSpread: Sendable {
    public let roiID: Int
    public let value: Double?
    public let pixelLow: Double?
    public let pixelHigh: Double?
    public let pixelSD: Double?
}

public struct StandardUncertainty: Sendable {
    public let nROIs: Int
    public let roiSD: Double?
    public let roiMin: Double?
    public let roiMax: Double?
    public let sd: Double?
    public let sdBasis: String?
    public let rois: [PixelSpread]
}

public struct CustomSpread: Sendable {
    public let roiID: Int
    public let lab: [Double]
    public let pixelSD: [Double]?
}

public struct CustomUncertainty: Sendable {
    public let nROIs: Int
    public let labSD: [Double]?
    public let rois: [CustomSpread]
}

public enum ReservoirUncertainty: Sendable {
    case none
    case standard(StandardUncertainty)
    case custom(CustomUncertainty)

    var json: JSONValue {
        switch self {
        case .none:
            return .null
        case .standard(let u):
            return .object([
                ("n_rois", .int(u.nROIs)), ("roi_sd", .number(u.roiSD)), ("roi_min", .number(u.roiMin)),
                ("roi_max", .number(u.roiMax)), ("sd", .number(u.sd)), ("sd_basis", .text(u.sdBasis)),
                ("rois", .array(u.rois.map {
                    .object([("roi_id", .int($0.roiID)), ("value", .number($0.value)), ("pixel_low", .number($0.pixelLow)),
                             ("pixel_high", .number($0.pixelHigh)), ("pixel_sd", .number($0.pixelSD))])
                })),
            ])
        case .custom(let u):
            return .object([
                ("n_rois", .int(u.nROIs)), ("lab_sd", .numbers(u.labSD)),
                ("rois", .array(u.rois.map {
                    .object([("roi_id", .int($0.roiID)), ("lab", .numbers($0.lab)), ("pixel_sd", .numbers($0.pixelSD))])
                })),
            ])
        }
    }
}

public struct ReservoirResult: Sendable {
    public var reservoir: ReservoirDraft
    public var calculation: Calculation
    public var averageLab: [Double]
    public var reviewStatus: String
    public var uncertainty: ReservoirUncertainty

    public var id: Int { reservoir.id }
    public var analyte: String { reservoir.analyte ?? "" }
    public var value: Double? { calculation.value }

    public var isIncluded: Bool {
        if reviewStatus == "included" && calculation.calculationStatus == "invalid_domain" { return calculation.value != nil }
        return calculation.calculationStatus == "valid" && (reviewStatus == "included" || reviewStatus == "automatically_included")
    }

    var json: JSONValue {
        .object(reservoir.json + [
            ("value", .number(calculation.value)), ("calculation_status", .string(calculation.calculationStatus)),
            ("warnings", .array(calculation.warnings.map(JSONValue.string))),
            ("urea_ph_model", .text(calculation.ureaPHModel)), ("unit", .string(calculation.unit)),
            ("equation_version", .string(calculation.equationVersion)), ("average_lab", .numbers(averageLab)),
            ("review_status", .string(reviewStatus)), ("uncertainty", uncertainty.json),
        ])
    }
}

public struct SummaryValue: Sendable {
    public let reservoirID: Int
    public let value: Double
    public let condition: String
    public let replicate: String
}

public struct AnalyteSummary: Sendable {
    public let analyte: String
    public let value: Double?
    public let sd: Double?
    public let sdBasis: String?
    public let unit: String
    public let includedIDs: [Int]
    public let values: [SummaryValue]
    public let minimum: Double?
    public let maximum: Double?
    public let note: String

    var json: JSONValue {
        .object([
            ("value", .number(value)), ("sd", .number(sd)), ("sd_basis", .text(sdBasis)), ("unit", .string(unit)),
            ("included_ids", .array(includedIDs.map(JSONValue.int))),
            ("values", .array(values.map {
                .object([("reservoir_id", .int($0.reservoirID)), ("value", .double($0.value)),
                         ("condition", .string($0.condition)), ("replicate", .string($0.replicate))])
            })),
            ("min", .number(minimum)), ("max", .number(maximum)), ("note", .string(note)),
        ])
    }
}

public struct UreaModelChoice: Sendable {
    public let source: String?
    public let selected: String?
    public let nearest: String?
}

public struct CalibrationFlag: Sendable {
    public let roiID: Int
    public let channels: [String]
}

public struct ConcentrationResults: Sendable {
    public var rois: [ROIMeasurement]
    public var reservoirs: [ReservoirResult]
    public var summaries: [AnalyteSummary]
    public var phReadyForUrea: Bool
    public var outsideCalibration: [CalibrationFlag]
    public var ureaCalibration: String?
    public var ureaPHModel: UreaModelChoice
    public var prediction: Prediction

    public func summary(_ analyte: String) -> AnalyteSummary? {
        summaries.first { $0.analyte == analyte }
    }

    public var json: JSONValue {
        var pairs: [(String, JSONValue)] = [
            ("rois", .array(rois.map(\.json))),
            ("reservoirs", .array(reservoirs.map(\.json))),
            ("summaries", .object(summaries.map { ($0.analyte, $0.json) })),
            ("ph_ready_for_urea", .bool(phReadyForUrea)),
            ("outside_calibration", .array(outsideCalibration.map {
                .object([("roi_id", .int($0.roiID)), ("channels", .array($0.channels.map(JSONValue.string)))])
            })),
        ]
        if let ureaCalibration { pairs.append(("urea_calibration", .string(ureaCalibration))) }
        pairs += [
            ("urea_ph_model", .object([("source", .text(ureaPHModel.source)), ("selected", .text(ureaPHModel.selected)),
                                       ("nearest", .text(ureaPHModel.nearest))])),
            ("prediction", prediction.json),
        ]
        return .object(pairs)
    }
}

public enum CKDConcentrations {
    private struct Measurement {
        let roi: ROIMeasurement
        let outside: [String]
    }

    public static func compute(draft: ResultsDraft, rois: [ROIMeasurement], calibration: CalibrationSummary?) -> ConcentrationResults {
        let manual = draft.ureaPHModel
        let ureaCalibration = draft.ureaCalibration.isEmpty ? "lab" : draft.ureaCalibration
        let flags = calibrationFlags(rois, calibration: calibration)
        let outside = Dictionary(flags.map { ($0.roiID, $0.channels) }, uniquingKeysWith: { _, last in last })
        let measurements = Dictionary(rois.map { ($0.id, Measurement(roi: $0, outside: outside[$0.id] ?? [])) },
                                      uniquingKeysWith: { _, last in last })
        var eligible = draft.reservoirs.filter { $0.analyte != nil && !$0.roiIDs.isEmpty }
        if rois.isEmpty || (draft.mode == "standard_24_grid" && eligible.isEmpty) {
            return ConcentrationResults(
                rois: rois, reservoirs: [], summaries: [], phReadyForUrea: false, outsideCalibration: flags,
                ureaCalibration: nil,
                ureaPHModel: UreaModelChoice(source: manual != nil ? "manual" : nil, selected: manual, nearest: nil),
                prediction: CKDPrediction.classifier(urea: nil, creatinine: nil, age: draft.age, sex: draft.sex)
            )
        }
        let custom = eligible.filter { $0.analyte == "custom" }.map { customResult($0, measurements) }
        eligible = eligible.filter { $0.analyte != "custom" }
        let phResults = eligible.filter { $0.analyte == "ph" }.map { reservoirResult($0, measurements) }
        let included = phResults.filter(\.isIncluded).compactMap(\.value)
        let validPH = phResults.filter { $0.calculation.calculationStatus == "valid" }
        let phReviewComplete = !validPH.isEmpty && validPH.allSatisfy { $0.reviewStatus != "needs_review" }
        let finalPH = !included.isEmpty && phReviewComplete ? mean(included) : nil
        let provisionalPH = validPH.isEmpty ? nil : mean(validPH.compactMap(\.value))
        var results = phResults + eligible.filter { $0.analyte != "ph" }.map { reservoir -> ReservoirResult in
            if reservoir.analyte == "creatinine" {
                return reservoirResult(reservoir, measurements)
            }
            return reservoirResult(
                reservoir, measurements,
                ph: phReviewComplete ? finalPH : provisionalPH,
                provisional: manual == nil && !phReviewComplete && provisionalPH != nil,
                manualModel: manual,
                ureaCalibration: ureaCalibration
            )
        }
        let coefficients = calibration?.coefficients
        results = results.map { result in
            var updated = result
            updated.uncertainty = reservoirUncertainty(result, measurements, calibration: coefficients == nil ? nil : calibration,
                                                       ureaCalibration: ureaCalibration)
            return updated
        } + custom

        let summaries = CKDEquations.analytes.map { analyte -> AnalyteSummary in
            let chosen = results.filter { $0.analyte == analyte && $0.isIncluded }
            let spread = summarySpread(chosen)
            let values = chosen.compactMap(\.value)
            return AnalyteSummary(
                analyte: analyte,
                value: chosen.isEmpty ? nil : mean(values),
                sd: spread.sd,
                sdBasis: spread.basis,
                unit: CKDEquations.units[analyte]!,
                includedIDs: chosen.map(\.id),
                values: chosen.map {
                    SummaryValue(reservoirID: $0.id, value: $0.value!, condition: $0.reservoir.condition,
                                 replicate: $0.reservoir.replicate)
                },
                minimum: values.min(),
                maximum: values.max(),
                note: chosen.count == 1 ? "One included reservoir; no duplicate redundancy." : ""
            )
        }
        let reference = finalPH ?? provisionalPH
        let source: String? = manual != nil ? "manual" : finalPH != nil ? "measured" : provisionalPH != nil ? "provisional" : nil
        return ConcentrationResults(
            rois: rois,
            reservoirs: results.enumerated().sorted { ($0.element.id, $0.offset) < ($1.element.id, $1.offset) }.map(\.element),
            summaries: summaries,
            phReadyForUrea: finalPH != nil,
            outsideCalibration: flags,
            ureaCalibration: ureaCalibration,
            ureaPHModel: UreaModelChoice(source: source, selected: manual ?? CKDEquations.ureaModel(reference),
                                         nearest: CKDEquations.ureaModel(reference)),
            prediction: CKDPrediction.predict(
                urea: summaries[1].value, creatinine: summaries[2].value, age: draft.age, sex: draft.sex,
                choice: draft.classifierModel
            )
        )
    }

    public static func calibrationFlags(_ rois: [ROIMeasurement], calibration: CalibrationSummary?) -> [CalibrationFlag] {
        guard let reference = calibration?.referenceLab, !reference.isEmpty else { return [] }
        let margin = calibration?.rmse ?? 0.0
        let names = ["L", "a", "b"]
        let lows = (0..<3).map { channel in reference.map { $0[channel] }.min()! }
        let highs = (0..<3).map { channel in reference.map { $0[channel] }.max()! }
        return rois.compactMap { roi in
            let channels = (0..<3).filter { channel in
                let value = roi.calibratedMedian[channel]
                return !(lows[channel] - margin <= value && value <= highs[channel] + margin)
            }.map { names[$0] }
            return channels.isEmpty ? nil : CalibrationFlag(roiID: roi.id, channels: channels)
        }
    }

    private static func reservoirResult(
        _ reservoir: ReservoirDraft,
        _ measurements: [Int: Measurement],
        ph: Double? = nil,
        provisional: Bool = false,
        manualModel: String? = nil,
        ureaCalibration: String = "lab"
    ) -> ReservoirResult {
        let lab = channelMean(reservoir.roiIDs.map { measurements[$0]!.roi.calibratedMedian })
        var calculation = CKDEquations.calculate(reservoir.analyte!, lab: lab, ph: ph, manualModel: manualModel,
                                                 ureaCalibration: ureaCalibration)
        for roiID in reservoir.roiIDs {
            let measurement = measurements[roiID]!
            if !measurement.outside.isEmpty {
                calculation.warnings.append(
                    "\(measurement.roi.displayLabel) color is outside the calibration patch range "
                        + "(\(measurement.outside.joined(separator: ", "))); the calibration extrapolates."
                )
            }
        }
        if provisional && calculation.calculationStatus == "valid" {
            calculation.calculationStatus = "provisional_input"
            calculation.warnings.append("Urea uses provisional pH until eligible pH reviews are resolved.")
        }
        let status = calculation.calculationStatus
        let review: String
        if status == "invalid_domain" && reservoir.review == "included" && calculation.value != nil {
            calculation.warnings = calculation.warnings.map { $0 == CKDEquations.invalidDomain ? CKDEquations.invalidIncluded : $0 }
            review = "included"
        } else if status == "invalid_domain" {
            review = "mathematically_invalid"
        } else if reservoir.review == "excluded" {
            review = "excluded"
        } else if status != "valid" {
            review = "needs_review"
        } else if reservoir.review == "included" {
            review = "included"
        } else if !calculation.warnings.isEmpty {
            review = "needs_review"
        } else {
            review = "automatically_included"
        }
        return ReservoirResult(reservoir: reservoir, calculation: calculation, averageLab: lab, reviewStatus: review,
                               uncertainty: .none)
    }

    private static func roiValue(_ analyte: String, lab: [Double], model: String?, ureaCalibration: String) -> Double? {
        let result = CKDEquations.calculate(analyte, lab: lab, ph: nil, manualModel: model, ureaCalibration: ureaCalibration)
        return result.calculationStatus == "valid" ? result.value : nil
    }

    private static func reservoirUncertainty(
        _ result: ReservoirResult,
        _ measurements: [Int: Measurement],
        calibration: CalibrationSummary?,
        ureaCalibration: String
    ) -> ReservoirUncertainty {
        let analyte = result.analyte
        let model = result.calculation.ureaPHModel
        if analyte == "urea" && model == nil {
            return .none
        }
        let rois = result.reservoir.roiIDs.map { roiID -> PixelSpread in
            let roi = measurements[roiID]!.roi
            var spread: [Double] = []
            if let calibration, let median = roi.median, let sd = roi.standardDeviation {
                for sign in [-1.0, 1.0] {
                    let shifted = zip(median, sd).map { $0 + sign * $1 }
                    if let lab = calibration.apply(shifted),
                       let value = roiValue(analyte, lab: lab, model: model, ureaCalibration: ureaCalibration) {
                        spread.append(value)
                    }
                }
            }
            let value = roiValue(analyte, lab: roi.calibratedMedian, model: model, ureaCalibration: ureaCalibration)
            return PixelSpread(
                roiID: roiID,
                value: value,
                pixelLow: spread.min(),
                pixelHigh: spread.max(),
                pixelSD: !spread.isEmpty && value != nil ? mean(spread.map { abs($0 - value!) }) : nil
            )
        }
        let values = rois.compactMap(\.value)
        let roiSD = values.count > 1 ? sampleSD(values) : nil
        let single = rois.count == 1 ? rois[0].pixelSD : nil
        return .standard(StandardUncertainty(
            nROIs: rois.count,
            roiSD: roiSD,
            roiMin: values.min(),
            roiMax: values.max(),
            sd: roiSD ?? single,
            sdBasis: roiSD != nil ? "rois" : single != nil ? "pixel" : nil,
            rois: rois
        ))
    }

    private static func summarySpread(_ chosen: [ReservoirResult]) -> (sd: Double?, basis: String?) {
        let values = chosen.compactMap(\.value)
        if values.count > 1 {
            return (sampleSD(values), "reservoirs")
        }
        if let first = chosen.first, case .standard(let spread) = first.uncertainty {
            return (spread.sd, spread.sdBasis)
        }
        return (nil, nil)
    }

    private static func customResult(_ reservoir: ReservoirDraft, _ measurements: [Int: Measurement]) -> ReservoirResult {
        let labs = reservoir.roiIDs.map { measurements[$0]!.roi.calibratedMedian }
        let warnings = reservoir.roiIDs.compactMap { roiID -> String? in
            let measurement = measurements[roiID]!
            guard !measurement.outside.isEmpty else { return nil }
            return "\(measurement.roi.displayLabel) color is outside the calibration patch range "
                + "(\(measurement.outside.joined(separator: ", ")))."
        }
        let labSD = labs.count > 1 ? (0..<3).map { channel in sampleSD(labs.map { $0[channel] }) } : nil
        return ReservoirResult(
            reservoir: reservoir,
            calculation: Calculation(value: nil, calculationStatus: "no_equation", warnings: warnings, ureaPHModel: nil,
                                     unit: "", equationVersion: ""),
            averageLab: channelMean(labs),
            reviewStatus: "not_applicable",
            uncertainty: .custom(CustomUncertainty(
                nROIs: labs.count,
                labSD: labSD,
                rois: reservoir.roiIDs.map {
                    CustomSpread(roiID: $0, lab: measurements[$0]!.roi.calibratedMedian,
                                 pixelSD: measurements[$0]!.roi.standardDeviation)
                }
            ))
        )
    }

    static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    static func sampleSD(_ values: [Double]) -> Double {
        let average = mean(values)
        return sqrt(values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(values.count - 1))
    }

    static func channelMean(_ labs: [[Double]]) -> [Double] {
        (0..<3).map { channel in labs.reduce(0.0) { $0 + $1[channel] } / Double(labs.count) }
    }
}
