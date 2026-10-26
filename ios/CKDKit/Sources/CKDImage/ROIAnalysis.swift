import Foundation

public struct QCamROIResult: Codable, Identifiable, Sendable {
    public let roiID: Int
    public let roiLabel: String
    public let polygon: QCamPolygon
    public let rawMedian: QCamLab
    public let rawMean: QCamLab
    public let rawStandardDeviation: QCamLab
    public let calibratedMedian: QCamLab
    public let calibratedMean: QCamLab
    public let pixelCount: Int

    public var id: Int { roiID }

    enum CodingKeys: String, CodingKey {
        case roiID = "roi_id"
        case roiLabel = "roi_label"
        case polygon
        case rawMedian = "raw_median"
        case rawMean = "raw_mean"
        case rawStandardDeviation = "raw_standard_deviation"
        case calibratedMedian = "calibrated_median"
        case calibratedMean = "calibrated_mean"
        case pixelCount = "pixel_count"
    }
}

public enum QCamAnalysisPipeline {
    public static let roiSampling: QCamPolygonSampling = .boundaryInclusivePolygon

    public static func analyzeROIs(
        image: QCamRGBAImage,
        calibration: QCamCalibration,
        rois: [QCamROI]
    ) throws -> [QCamROIResult] {
        try rois.map { roi in
            try analyzeROI(image: image, calibration: calibration, roi: roi)
        }
    }

    public static func analyzeROI(
        image: QCamRGBAImage,
        calibration: QCamCalibration,
        roi: QCamROI
    ) throws -> QCamROIResult {
        let rawStats = try image.labStats(for: roi.polygon, sampling: roiSampling)
        return QCamROIResult(
            roiID: roi.id,
            roiLabel: roi.label,
            polygon: roi.polygon,
            rawMedian: rawStats.median,
            rawMean: rawStats.mean,
            rawStandardDeviation: rawStats.standardDeviation,
            calibratedMedian: calibration.apply(to: rawStats.median),
            calibratedMean: calibration.apply(to: rawStats.mean),
            pixelCount: rawStats.pixelCount
        )
    }
}
