import CKDImage
import CKDResults
import Foundation

public enum MeasurementTables {
    static func fixed(_ value: Double?) -> String {
        value.map { String(format: "%.6f", $0) } ?? ""
    }

    static func labFields(_ prefix: String) -> [String] {
        ["median", "mean", "std"].flatMap { kind in ["l", "a", "b"].map { "\(prefix)_\($0)_star_\(kind)" } }
    }

    static func polygonText(_ points: [QCamPoint]) -> String {
        points.map { "\(fixed($0.x)):\(fixed($0.y))" }.joined(separator: ";")
    }

    static func cells(_ values: [Double]?) -> [CSVCell] {
        values.map { $0.map { .text(fixed($0)) } } ?? [.text(""), .text(""), .text("")]
    }

    static func calibratedSpread(_ image: QCamRGBAImage, _ points: [QCamPoint], _ calibration: CalibrationSummary) throws -> [Double] {
        let polygon = QCamPolygon(points: try PolygonRules.validate(points, width: image.width, height: image.height))
        let stats = try image.stats(for: polygon, sampling: .boundaryInclusivePolygon) { lab in
            let value = calibration.apply([lab.lStar, lab.aStar, lab.bStar])!
            return QCamLab(lStar: value[0], aStar: value[1], bStar: value[2])
        }
        return [stats.standardDeviation.lStar, stats.standardDeviation.aStar, stats.standardDeviation.bStar]
    }

    static func render(_ fields: [String], _ rows: [[CSVCell]], _ identity: AnalysisIdentity?) -> String {
        guard let identity else { return CSVText.make(fields: fields, rows: rows) }
        let prefix: [CSVCell] = [.text(identity.analysisID), .text(identity.analysisTitle), .text(identity.sourceFilename)]
        return CSVText.make(fields: ["analysis_id", "analysis_title", "source_filename"] + fields, rows: rows.map { prefix + $0 })
    }

    public static func patchMeasurements(_ image: QCamRGBAImage, calibration block: JSONValue,
                                         identity: AnalysisIdentity?) throws -> String {
        let fields = ["patch_id", "geometry_orientation", "patch_order", "reference_position", "sampled_position",
                      "grid_x", "grid_y", "polygon_points", "pixel_count"] + labFields("raw") + labFields("calibrated")
            + ["reference_l_star", "reference_a_star", "reference_b_star", "corrected_residual_l_star",
               "corrected_residual_a_star", "corrected_residual_b_star", "delta_e"]
        func matrix(_ key: String) -> [[Double]] { block[key]?.arrayValues?.map { $0.arrayValues?.compactMap(\.doubleValue) ?? [] } ?? [] }
        let calibration = CalibrationSummary(coefficients: matrix("coefficients"), rmse: block["rmse"]?.doubleValue,
                                             referenceLab: matrix("reference_lab"))
        let patches = (block["patches"]?.arrayValues ?? []).map { patch in
            (patch.arrayValues ?? []).map { QCamPoint(x: $0["x"]?.doubleValue ?? .nan, y: $0["y"]?.doubleValue ?? .nan) }
        }
        let deltaE = block["delta_e"]?.arrayValues?.compactMap(\.doubleValue) ?? []
        let mode = block["mode"]?.stringValue ?? ""
        let orientation = block["orientation"]?.stringValue ?? ""
        let rows = try (block["sample_order"]?.arrayValues ?? []).compactMap(\.intValue).enumerated().map { position, index -> [CSVCell] in
            let points = patches[index]
            let stats = try AnalysisPipeline.labStats(image, points)
            let median = calibration.apply(stats.median)!
            let reference = calibration.referenceLab![position]
            let grid: [CSVCell] = mode == "flower_9" ? [.int(index % 3), .int(index / 3)]
                : mode == "standard_24_grid" ? [.int(index / 4), .int(index % 4)] : [.text(""), .text("")]
            var row: [CSVCell] = [.int(position + 1), .text(orientation), .int(index + 1), .int(position + 1), .int(index + 1)]
            row += grid + [.text(polygonText(points)), .int(stats.pixelCount)]
            row += (stats.median + stats.mean + stats.standardDeviation).map { .text(fixed($0)) }
            row += cells(median) + cells(calibration.apply(stats.mean)) + cells(try calibratedSpread(image, points, calibration))
            row += cells(reference) + cells(zip(median, reference).map { $0 - $1 }) + [.text(fixed(deltaE[position]))]
            return row
        }
        return render(fields, rows, identity)
    }

    public static func roiMeasurements(_ image: QCamRGBAImage, document: AnalysisDocument,
                                       identity: AnalysisIdentity?) throws -> String {
        let fields = ["roi_id", "roi_label", "polygon_points", "pixel_count"] + labFields("raw") + labFields("calibrated")
        let points = Dictionary(document.draft.rois.map { ($0.id, $0.points) }, uniquingKeysWith: { _, last in last })
        guard let calibration = document.calibrationSummary else { return render(fields, [], identity) }
        let rows = try document.roiMeasurements.map { roi -> [CSVCell] in
            guard let polygon = points[roi.id] else { throw DocumentError("ROI \(roi.id) is missing from the draft.") }
            var row: [CSVCell] = [.int(roi.id), .string(roi.label), .text(polygonText(polygon)), .whole(roi.pixelCount)]
            row += ((roi.median ?? []) + (roi.mean ?? []) + (roi.standardDeviation ?? [])).map { .text(fixed($0)) }
            row += cells(roi.calibratedMedian) + cells(roi.calibratedMean) + cells(try calibratedSpread(image, polygon, calibration))
            return row
        }
        return render(fields, rows, identity)
    }
}
