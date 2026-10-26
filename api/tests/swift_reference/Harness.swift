// JSON/file adapter only. Numerical algorithms are extracted unchanged from QDAQ.
import Foundation

func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
}

func decode<T: Decodable>(_ value: Any, as type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
}

func image(_ input: [String: Any]) throws -> QCamRGBAImage {
    QCamRGBAImage(width: input["width"] as! Int, height: input["height"] as! Int,
        data: try Data(contentsOf: URL(fileURLWithPath: input["rgba_path"] as! String)))
}

func scalar(_ result: QCamScalarCalculation) -> [String: Any] {
    ["value": result.value as Any? ?? NSNull(), "status": result.status.rawValue,
     "equation_version": result.equationVersion, "warnings": result.warnings,
     "model": result.ureaPHModel?.rawValue as Any? ?? NSNull()]
}

func number(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return n.doubleValue }
    switch value as? String {
    case "nan": return Double.nan
    case "inf": return Double.infinity
    case "-inf": return -Double.infinity
    default: return nil
    }
}

func lab(_ values: [Any]) -> QCamLab {
    QCamLab(lStar: number(values[0])!, aStar: number(values[1])!, bStar: number(values[2])!)
}

func concentration(_ input: [String: Any], rois: [QCamROIResult]) throws -> [String: Any] {
    let reservoirs = try decode(input["reservoirs"] ?? [], as: [QCamReservoir].self)
    let rebuilt = ReferenceReviewState(reservoirs: reservoirs, results: rois,
        marker: input["mode"] as? String == "standard_24_grid" ? .standard24 : .flower9,
        age: number(input["age"]), sex: QCamSex(rawValue: input["sex"] as? String ?? ""))
    rebuilt.rebuildReservoirResults()
    let results = rebuilt.reservoirResults
    let summaries = rebuilt.analyteSummaries
    let classification = rebuilt.classification
    let notes = QCamConcentrationPipeline.analysisNotes(reservoirResults: results,
        summaries: summaries, classification: classification)
    let data = try QCamConcentrationExport.resultsJSON(analysisID: "swift-core-reference",
        analysisTimestamp: "fixed-reference", sourceImageFilename: input["filename"] as? String ?? "unit",
        roiResults: rois, reservoirResults: results, analyteSummaries: summaries,
        analysisNotes: notes, classification: classification, analysisConfig: SweatCKDCAMAnalysisConfig())
    return ["results": try JSONSerialization.jsonObject(with: data),
        "csv": ["05_reservoir_results.csv": QCamConcentrationExport.reservoirResultsCSV(for: results),
                "06_analyte_summary.csv": QCamConcentrationExport.analyteSummaryCSV(for: summaries),
                "07_prediction.csv": QCamConcentrationExport.predictionCSV(for: classification, summaries: summaries)]]
}

func run(_ input: [String: Any]) throws -> [String: Any] {
    switch input["action"] as! String {
    case "wb":
        let buffer = try image(input)
        let polygon = try decode(input["polygon"]!, as: QCamPolygon.self)
        let mean = try buffer.rgbMean(for: polygon, sampling: .boundaryInclusivePolygon)
        return ["mean": try object(mean), "multipliers": try QCamRawWhiteBalance.explicitWhiteBalanceScale(
            measuredRGB: mean, currentImageWhiteBalance: input["wb"] as! [Double]),
            "brightness": QCamRawWhiteBalance.brightnessScale(afterFirstPass: mean)]
    case "pipeline":
        let buffer = try image(input)
        let mode = input["mode"] as! String
        let corners = try decode(input["corners"] ?? [], as: [QCamPoint].self)
        let calibration: QCamCalibration
        if mode == "flower_9_manual" {
            calibration = try QCamCalibration.calibrateFlower9(buffer: buffer,
                manualPolygons: decode(input["manual"]!, as: [QCamPolygon].self))
        } else {
            calibration = try QCamCalibration.calibrate(buffer: buffer, corners: corners,
                markerKind: mode == "standard_24_grid" ? .standard24 : .flower9)
        }
        let rois = try QCamAnalysisPipeline.analyzeROIs(image: buffer, calibration: calibration,
            rois: decode(input["rois"]!, as: [QCamROI].self))
        var output = try concentration(input, rois: rois)
        output["calibration"] = ["coefficients": calibration.coefficients, "rmse": calibration.rmse,
            "orientation": calibration.orientationLabel, "patch_order": calibration.patchOrderLabel,
            "patches": try object(calibration.patchAudits), "reference_version": calibration.referenceVersion,
            "confidence": calibration.orientationConfidenceMargin as Any? ?? NSNull()]
        return output
    case "units":
        var output: [String: Any] = [:]
        output["equations"] = (input["equations"] as! [[String: Any]]).map { item -> [String: Any] in
            let value = lab(item["lab"] as! [Any])
            let result: QCamScalarCalculation
            switch item["analyte"] as! String {
            case "ph": result = QCamConcentrationPipeline.calculatePH(lab: value)
            case "urea": result = QCamConcentrationPipeline.calculateUrea(lab: value, ph: number(item["ph"]))
            default: result = QCamConcentrationPipeline.calculateCreatinine(lab: value)
            }
            return ["input": item, "expected": scalar(result)]
        }
        output["fits"] = (input["fits"] as! [[String: Any]]).map { item -> [String: Any] in
            let measured = (item["measured"] as! [[Any]]).map(lab)
            let reference = (item["reference"] as! [[Any]]).map(lab)
            return ["input": item, "coefficients": QCamMath.abAffineCoefficients(
                measured: measured, reference: reference) as Any? ?? NSNull()]
        }
        output["sampling"] = try (input["sampling"] as! [[String: Any]]).map { item -> [String: Any] in
            let rgb = item["rgb"] as! [[Int]]
            let bytes = rgb.flatMap { $0.map { UInt8($0) } + [UInt8(255)] }
            let buffer = QCamRGBAImage(width: item["width"] as! Int, height: item["height"] as! Int, data: bytes)
            let polygon = try decode(item["polygon"]!, as: QCamPolygon.self)
            let stats = try buffer.labStats(for: polygon, sampling: .boundaryInclusivePolygon)
            let mean = try buffer.rgbMean(for: polygon, sampling: .boundaryInclusivePolygon)
            return ["input": item, "expected": ["median": try object(stats.median), "mean": try object(stats.mean),
                "standard_deviation": try object(stats.standardDeviation), "pixel_count": stats.pixelCount,
                "rgb_mean": try object(mean)]]
        }
        output["reservoirs"] = try (input["reservoirs"] as! [[String: Any]]).map { item -> [String: Any] in
            let rois = try decode(item["roi_results"]!, as: [QCamROIResult].self)
            return ["input": item, "expected": try concentration(item, rois: rois)]
        }
        output["classifiers"] = try (input["classifiers"] as! [[String: Any]]).map { item -> [String: Any] in
            let summaries = [QCamAnalyte.urea, .creatinine].map { a in
                QCamAnalyteSummary(analyte: a, includedReservoirIDs: [], excludedReservoirIDs: [],
                    finalValue: number(item[a.rawValue]), unit: a.unit, warnings: [])
            }
            let result = QCamConcentrationPipeline.classify(summaries: summaries,
                ageYears: number(item["age"])!, sex: QCamSex(rawValue: item["sex"] as! String)!)
            return ["input": item, "expected": try object(result)]
        }
        return output
    default: fatalError("Unknown reference action")
    }
}

let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: Any]
let output = try run(input)
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted]))
