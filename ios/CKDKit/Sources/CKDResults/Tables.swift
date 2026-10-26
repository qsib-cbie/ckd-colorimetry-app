import Foundation

public struct AnalysisIdentity: Codable, Sendable {
    public let analysisID: String
    public let analysisTitle: String
    public let sourceFilename: String

    public init(analysisID: String, analysisTitle: String, sourceFilename: String) {
        self.analysisID = analysisID
        self.analysisTitle = analysisTitle
        self.sourceFilename = sourceFilename
    }

    enum CodingKeys: String, CodingKey {
        case analysisID = "analysis_id"
        case analysisTitle = "analysis_title"
        case sourceFilename = "source_filename"
    }

    static let fields = ["analysis_id", "analysis_title", "source_filename"]
    var cells: [CSVCell] { [.text(analysisID), .text(analysisTitle), .text(sourceFilename)] }
}

public enum CKDTables {
    static let reservoirFields = "reservoir_id,reservoir_label,analyte,roi_ids,roi_count,minimum_roi_count,maximum_roi_count,reservoir_completeness,average_l_star,average_a_star,average_b_star,calculated_value,unit,equation_version,calculation_status,review_status,included_in_summary,message_severity,exclusion_reason,messages".components(separatedBy: ",")
    static let summaryFields = "analyte,included_reservoir_ids,excluded_reservoir_ids,final_value,unit,duplicate_count_used,aggregation_method,status,messages".components(separatedBy: ",")
    static let predictionFields = "urea_mM,creatinine_uM,age_years,sex,male_indicator,equation_version,probability,threshold,classification,status,message".components(separatedBy: ",")
    static let roiResultFields = ("reservoir_id,condition,replicate,biomarker,roi_id,roi_label,value,unit,value_sd,pixel_low,pixel_high,"
        + "reservoir_value,reservoir_sd,sd_basis,reservoir_n_rois,reservoir_included,review_status,calculation_status,"
        + "equation_version,urea_ph_model,urea_calibration,analyte_final_value,analyte_final_sd,analyte_n_reservoirs,"
        + "pixel_count,raw_l_star,raw_a_star,raw_b_star,raw_mean_l_star,raw_mean_a_star,raw_mean_b_star,pixel_sd_l_star,"
        + "pixel_sd_a_star,pixel_sd_b_star,calibrated_l_star,calibrated_a_star,calibrated_b_star,calibrated_mean_l_star,"
        + "calibrated_mean_a_star,calibrated_mean_b_star,outside_calibration,warnings").components(separatedBy: ",")
    static let reservoirResultFields = ("reservoir_id,condition,replicate,biomarker,roi_ids,n_rois,value,unit,sd,sd_basis,roi_min,roi_max,"
        + "average_l_star,average_a_star,average_b_star,calculation_status,review_status,included_in_average,"
        + "exclusion_reason,equation_version,urea_ph_model,urea_calibration,analyte_final_value,analyte_final_sd,"
        + "analyte_n_reservoirs,warnings").components(separatedBy: ",")
    static let analyteResultFields = ("analyte,final_value,unit,sd,sd_basis,n_included,included_reservoir_ids,included_values,included_conditions,"
        + "included_replicates,min,max,aggregation,excluded_reservoir_ids,needs_review_reservoir_ids,urea_calibration,"
        + "urea_ph_model,urea_ph_model_source,note").components(separatedBy: ",")
    static let predictionDetailFields = ("status,model,model_label,model_source,available_models,urea_mM,creatinine_uM,age_years,sex,probability,"
        + "threshold,auc,classification,equation_version,urea_calibration,urea_ph_model,reason").components(separatedBy: ",")

    public static func export(_ results: ConcentrationResults, identity: AnalysisIdentity?) -> [String: String] {
        let reservoirs = reservoirTable(results)
        var tables: [String: String] = [
            "results.csv": roiTable(results, identity: identity),
            "05_reservoirs.csv": render(reservoirFields, reservoirs.rows, identity),
            "06_analytes.csv": render(summaryFields, summaryRows(results), identity),
            "07_prediction.csv": render(predictionFields, [predictionRow(results)], identity),
            "08_notes.csv": render(["code", "category", "severity", "message"], notes(results, reservoirNotes: reservoirs.notes), identity),
        ]
        tables["09_roi_results.csv"] = render(roiResultFields, roiResultRows(results), identity)
        tables["10_reservoir_results.csv"] = render(reservoirResultFields, reservoirResultRows(results), identity)
        tables["11_analyte_results.csv"] = render(analyteResultFields, analyteResultRows(results), identity)
        tables["12_prediction_details.csv"] = render(predictionDetailFields, [predictionDetailRow(results)], identity)
        return tables
    }

    private static func render(_ fields: [String], _ rows: [[CSVCell]], _ identity: AnalysisIdentity?) -> String {
        guard let identity else { return CSVText.make(fields: fields, rows: rows) }
        return CSVText.make(fields: AnalysisIdentity.fields + fields, rows: rows.map { identity.cells + $0 })
    }

    private static func roiTable(_ results: ConcentrationResults, identity: AnalysisIdentity?) -> String {
        guard let first = results.rois.first, case .object(let pairs) = first.json else { return "" }
        let fields = pairs.map(\.0)
        let rows = results.rois.map { roi -> [CSVCell] in
            fields.map { field in
                guard let value = roi.json[field] else { return .empty }
                switch value {
                case .null: return .empty
                case .int(let number): return .int(number)
                case .double(let number): return .double(number)
                case .string(let text): return .text(text)
                default: return .json(value)
                }
            }
        }
        return render(fields, rows, identity)
    }

    private static func biomarkerName(_ reservoir: ReservoirResult?) -> String {
        guard let reservoir else { return "" }
        if reservoir.reservoir.analyte == "custom" {
            return reservoir.reservoir.customName.isEmpty ? "Custom" : reservoir.reservoir.customName
        }
        return reservoir.reservoir.analyte ?? ""
    }

    private static func joined<T>(_ values: [T], _ format: (T) -> String) -> String {
        values.map(format).joined(separator: ";")
    }

    private static func severity(_ result: ReservoirResult) -> String {
        result.calculation.calculationStatus == "invalid_domain" ? "error" : result.calculation.warnings.isEmpty ? "info" : "warning"
    }

    private static func reservoirTable(_ results: ConcentrationResults) -> (rows: [[CSVCell]], notes: [[CSVCell]]) {
        var rows: [[CSVCell]] = []
        var notes: [[CSVCell]] = []
        for r in results.reservoirs {
            let level = severity(r)
            let messages = r.calculation.warnings + [
                "Reservoir LAB used the arithmetic mean of \(r.reservoir.roiIDs.count) ROI calibrated median(s).",
                "Review status: \(r.reviewStatus).",
            ]
            let label = !r.reservoir.customName.isEmpty && r.analyte == "custom"
                ? "Reservoir \(r.id): \(r.reservoir.customName)" : "Reservoir \(r.id)"
            rows.append([
                .int(r.id), .text(label), .string(r.reservoir.analyte), .text(joined(r.reservoir.roiIDs) { String($0) }),
                .int(r.reservoir.roiIDs.count), .int(1), .text(""), .text("valid"),
            ] + r.averageLab.map(CSVCell.double) + [
                .number(r.value), .text(r.calculation.unit), .text(r.calculation.equationVersion),
                .text(r.calculation.calculationStatus), .text(r.reviewStatus), .text(r.isIncluded ? "true" : "false"),
                .text(level), .text(r.reservoir.reason), .text(messages.joined(separator: " | ")),
            ])
            notes += messages.enumerated().map { index, message in
                [.text("reservoir_\(r.id)_\(index + 1)"), .text("result"), .text(level), .text(message)]
            }
        }
        return (rows, notes)
    }

    private static func summaryRows(_ results: ConcentrationResults) -> [[CSVCell]] {
        results.summaries.map { s in
            let n = s.includedIDs.count
            let excluded = results.reservoirs.filter { $0.analyte == s.analyte && $0.reviewStatus == "excluded" }.map(\.id)
            return [
                .text(s.analyte), .text(joined(s.includedIDs) { String($0) }), .text(joined(excluded) { String($0) }),
                .number(s.value), .text(s.unit), .int(n),
                .text(n > 1 ? "arithmetic_mean_of_complete_reservoir_concentrations" : n > 0 ? "single_complete_reservoir" : "none"),
                .text(s.value != nil ? "complete" : "incomplete"), .text(s.note),
            ]
        }
    }

    private static func predictionRow(_ results: ConcentrationResults) -> [CSVCell] {
        let p = results.prediction
        return predictionFields.map { field in
            switch field {
            case "male_indicator": return p.isComplete ? .int(p.sex == "male" ? 1 : 0) : .empty
            case "message": return .text(p.reason ?? "")
            default: return p.field(field)
            }
        }
    }

    private static func notes(_ results: ConcentrationResults, reservoirNotes: [[CSVCell]]) -> [[CSVCell]] {
        var notes = reservoirNotes
        let labels = Dictionary(results.rois.map { ($0.id, $0.displayLabel) }, uniquingKeysWith: { _, last in last })
        for flag in results.outsideCalibration {
            let label = labels[flag.roiID] ?? String(flag.roiID)
            notes.append([.text("roi_outside_calibration_range"), .text("calibration"), .text("warning"),
                          .text("\(label) color is outside the calibration patch range (\(flag.channels.joined(separator: ", "))).")])
        }
        if results.ureaCalibration == "ab" {
            notes.append([.text("urea_calibration_ab"), .text("calculation"), .text("info"),
                          .text("Urea used the \(CKDEquations.ureaCalibrations["ab"]!.label) calibration.")])
        }
        if let model = results.prediction.model, model != "full" || results.prediction.modelSource == "manual" {
            let auc = results.prediction.auc.map { ", AUC " + PythonFormat.float($0) } ?? ""
            notes.append([.text("prediction_model"), .text("prediction"), .text("info"),
                          .text("Prediction used the \(CKDEquations.classifierLabels[model]!) model "
                                + "(\(results.prediction.modelSource ?? "None") choice\(auc)).")])
        }
        if results.ureaPHModel.source == "manual" {
            notes.append([.text("urea_ph_model_manual"), .text("calculation"), .text("info"),
                          .text("Urea used the manually selected \(results.ureaPHModel.selected ?? "None") model.")])
        }
        notes.append([.text("research_validation_pending"), .text("validation"), .text("info"),
                      .text("Research configuration pending assay and classifier validation.")])
        return notes
    }

    private static func ureaContext(_ results: ConcentrationResults, _ reservoir: ReservoirResult?) -> [CSVCell] {
        guard let reservoir, reservoir.analyte == "urea" else {
            return [.string(reservoir?.calculation.ureaPHModel), .empty]
        }
        return [.string(reservoir.calculation.ureaPHModel), .text(results.ureaCalibration ?? "lab")]
    }

    private static func analyteContext(_ results: ConcentrationResults, _ reservoir: ReservoirResult) -> [CSVCell] {
        let summary = results.summary(reservoir.analyte)
        return [.number(summary?.value), .number(summary?.sd), .int(summary?.includedIDs.count ?? 0)]
    }

    private static func roiResultRows(_ results: ConcentrationResults) -> [[CSVCell]] {
        var owners: [Int: ReservoirResult] = [:]
        for reservoir in results.reservoirs {
            for roiID in reservoir.reservoir.roiIDs { owners[roiID] = reservoir }
        }
        let flags = Dictionary(results.outsideCalibration.map { ($0.roiID, $0.channels.joined(separator: ";")) },
                               uniquingKeysWith: { _, last in last })
        return results.rois.map { roi in
            let reservoir = owners[roi.id]
            var own: PixelSpread?
            var reservoirSD: Double?
            var sdBasis: String?
            if case .standard(let spread)? = reservoir?.uncertainty {
                own = spread.rois.first { $0.roiID == roi.id }
                reservoirSD = spread.sd
                sdBasis = spread.sdBasis
            }
            let triple = { (values: [Double]?) -> [CSVCell] in
                values.map { $0.map(CSVCell.double) } ?? [.empty, .empty, .empty]
            }
            var row: [CSVCell] = [
                .whole(reservoir?.id), .string(reservoir?.reservoir.condition), .string(reservoir?.reservoir.replicate),
                .text(biomarkerName(reservoir)), .int(roi.id), .string(roi.label), .number(own?.value),
                .string(reservoir?.calculation.unit), .number(own?.pixelSD), .number(own?.pixelLow), .number(own?.pixelHigh),
                .number(reservoir?.value), .number(reservoirSD), .string(sdBasis),
                .whole(reservoir.map { $0.reservoir.roiIDs.count }.flatMap { $0 == 0 ? nil : $0 }),
                .string(reservoir.map { $0.isIncluded ? "true" : "false" }), .string(reservoir?.reviewStatus),
                .string(reservoir?.calculation.calculationStatus), .string(reservoir?.calculation.equationVersion),
            ]
            row += ureaContext(results, reservoir)
            row += reservoir.map { analyteContext(results, $0) } ?? [.empty, .empty, .empty]
            row.append(.whole(roi.pixelCount))
            row += triple(roi.median) + triple(roi.mean) + triple(roi.standardDeviation) + triple(roi.calibratedMedian)
                + triple(roi.calibratedMean)
            row.append(.string(flags[roi.id]))
            row.append(.text((reservoir?.calculation.warnings ?? []).joined(separator: ";")))
            return row
        }
    }

    private static func reservoirResultRows(_ results: ConcentrationResults) -> [[CSVCell]] {
        results.reservoirs.map { r in
            var sd: Double?
            var basis: String?
            var low: Double?
            var high: Double?
            if case .standard(let spread) = r.uncertainty {
                sd = spread.sd
                basis = spread.sdBasis
                low = spread.roiMin
                high = spread.roiMax
            }
            return [
                .int(r.id), .text(r.reservoir.condition), .text(r.reservoir.replicate), .text(biomarkerName(r)),
                .text(joined(r.reservoir.roiIDs) { String($0) }), .int(r.reservoir.roiIDs.count), .number(r.value),
                .text(r.calculation.unit), .number(sd), .string(basis), .number(low), .number(high),
            ] + r.averageLab.map(CSVCell.double) + [
                .text(r.calculation.calculationStatus), .text(r.reviewStatus), .text(r.isIncluded ? "true" : "false"),
                .text(r.reservoir.reason), .text(r.calculation.equationVersion),
            ] + ureaContext(results, r) + analyteContext(results, r) + [.text(r.calculation.warnings.joined(separator: ";"))]
        }
    }

    private static func analyteResultRows(_ results: ConcentrationResults) -> [[CSVCell]] {
        results.summaries.map { s in
            let reservoirs = results.reservoirs.filter { $0.analyte == s.analyte }
            let urea: [CSVCell] = s.analyte == "urea"
                ? [.text(results.ureaCalibration ?? "lab"), .string(results.ureaPHModel.selected), .string(results.ureaPHModel.source)]
                : [.empty, .empty, .empty]
            return [
                .text(s.analyte), .number(s.value), .text(s.unit), .number(s.sd), .string(s.sdBasis), .int(s.includedIDs.count),
                .text(joined(s.includedIDs) { String($0) }), .text(joined(s.values) { PythonFormat.float($0.value) }),
                .text(joined(s.values) { $0.condition }), .text(joined(s.values) { $0.replicate }),
                .number(s.minimum), .number(s.maximum),
                .text(s.values.count > 1 ? "mean" : s.values.isEmpty ? "none" : "single"),
                .text(joined(reservoirs.filter { $0.reviewStatus == "excluded" }.map(\.id)) { String($0) }),
                .text(joined(reservoirs.filter { $0.reviewStatus == "needs_review" }.map(\.id)) { String($0) }),
            ] + urea + [.text(s.note)]
        }
    }

    private static func predictionDetailRow(_ results: ConcentrationResults) -> [CSVCell] {
        let p = results.prediction
        return [
            p.field("status"), p.field("model"), p.field("model_label"), p.field("model_source"),
            .text((p.availableModels ?? []).joined(separator: ";")), p.field("urea_mM"), p.field("creatinine_uM"),
            p.field("age_years"), p.field("sex"), p.field("probability"), p.field("threshold"), p.field("auc"),
            p.field("classification"), p.field("equation_version"), .text(results.ureaCalibration ?? "lab"),
            .string(results.ureaPHModel.selected), p.field("reason"),
        ]
    }
}
