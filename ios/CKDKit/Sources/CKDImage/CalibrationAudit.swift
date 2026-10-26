import Foundation

public struct QCamColorCheckerPatchAudit: Codable {
    public let patchID: Int
    public let geometryOrientation: String
    public let patchOrder: String
    public let referencePosition: String?
    public let sampledPosition: String?
    public let gridX: Int
    public let gridY: Int
    public let polygon: QCamPolygon
    public let measuredMedian: QCamLab
    public let measuredMean: QCamLab?
    public let calibrationInputStatistic: String?
    public let correctedLab: QCamLab
    public let referenceLab: QCamLab
    public let correctedResidual: QCamLab
    public let deltaE: Double
    public let pixelCount: Int

    enum CodingKeys: String, CodingKey {
        case patchID = "patch_id"
        case geometryOrientation = "geometry_orientation"
        case patchOrder = "patch_order"
        case referencePosition = "reference_position"
        case sampledPosition = "sampled_position"
        case gridX = "grid_x"
        case gridY = "grid_y"
        case polygon
        case measuredMedian = "measured_median"
        case measuredMean = "measured_mean"
        case calibrationInputStatistic = "calibration_input_statistic"
        case correctedLab = "corrected_lab"
        case referenceLab = "reference_lab"
        case correctedResidual = "corrected_residual"
        case deltaE = "delta_e"
        case pixelCount = "pixel_count"
    }
}

struct QCamColorCheckerMeasuredPatch {
    public let flowerPosition: QCamFlowerPatchPosition?
    public let gridX: Int
    public let gridY: Int
    public let polygon: QCamPolygon
    public let median: QCamLab
    public let mean: QCamLab
    public let pixelCount: Int

    public static let empty = QCamColorCheckerMeasuredPatch(
        flowerPosition: nil,
        gridX: 0,
        gridY: 0,
        polygon: QCamPolygon(points: []),
        median: QCamLab(lStar: 0, aStar: 0, bStar: 0),
        mean: QCamLab(lStar: 0, aStar: 0, bStar: 0),
        pixelCount: 0
    )
}

enum QCamCalibrationPatchStatistic: String {
    case median
    case mean
}

enum QCamColorCheckerGeometryOrientation: String, CaseIterable {
    case landscape6x4 = "landscape_6x4"
    case portrait4x6 = "portrait_4x6"

    public var displayName: String {
        switch self {
        case .landscape6x4: return "landscape 6x4"
        case .portrait4x6: return "portrait 4x6"
        }
    }
}

