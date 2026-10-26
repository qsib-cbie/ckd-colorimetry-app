import Foundation

public enum QCamCalibrationMarkerKind: String, Codable, CaseIterable, Identifiable {
    case flower9 = "flower_9"
    case standard24 = "standard_24"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .flower9: return "Flower 9"
        case .standard24: return "Standard 24"
        }
    }
}

public enum QCamCalibrationMode: String, Codable, CaseIterable, Identifiable {
    case standard24Grid = "standard_24_grid"
    case flower9 = "flower_9"
    case flower9Manual = "flower_9_manual"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard24Grid: return "Rectangular Grid"
        case .flower9: return "Flower"
        case .flower9Manual: return "Flower Manual"
        }
    }

    public var markerKind: QCamCalibrationMarkerKind {
        switch self {
        case .standard24Grid:
            return .standard24
        case .flower9, .flower9Manual:
            return .flower9
        }
    }

    public var usesManualPatchPolygons: Bool {
        self == .flower9Manual
    }

    public static func defaultMode(for markerKind: QCamCalibrationMarkerKind) -> QCamCalibrationMode {
        markerKind == .flower9 ? .flower9 : .standard24Grid
    }
}

public struct QCamNormalizedPoint: Codable, Hashable {
    public let u: Double
    public let v: Double
}

public struct QCamNormalizedRect: Codable, Hashable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public enum QCamFlowerPatchPosition: String, Codable, CaseIterable {
    case northWest = "north_west"
    case north
    case northEast = "north_east"
    case west
    case center
    case east
    case southWest = "south_west"
    case south
    case southEast = "south_east"

    public var gridCoordinate: (row: Int, column: Int) {
        switch self {
        case .northWest: return (0, 0)
        case .north: return (0, 1)
        case .northEast: return (0, 2)
        case .west: return (1, 0)
        case .center: return (1, 1)
        case .east: return (1, 2)
        case .southWest: return (2, 0)
        case .south: return (2, 1)
        case .southEast: return (2, 2)
        }
    }

    public var normalizedCenter: QCamNormalizedPoint {
        switch self {
        case .northWest: return QCamNormalizedPoint(u: 0.30, v: 0.30)
        case .north: return QCamNormalizedPoint(u: 0.50, v: 0.18)
        case .northEast: return QCamNormalizedPoint(u: 0.70, v: 0.30)
        case .west: return QCamNormalizedPoint(u: 0.18, v: 0.50)
        case .center: return QCamNormalizedPoint(u: 0.50, v: 0.50)
        case .east: return QCamNormalizedPoint(u: 0.82, v: 0.50)
        case .southWest: return QCamNormalizedPoint(u: 0.30, v: 0.70)
        case .south: return QCamNormalizedPoint(u: 0.50, v: 0.82)
        case .southEast: return QCamNormalizedPoint(u: 0.70, v: 0.70)
        }
    }

    public var usesDiagonalSamplingPolygon: Bool {
        switch self {
        case .northWest, .northEast, .southWest, .southEast:
            return true
        case .north, .west, .center, .east, .south:
            return false
        }
    }

    public static func position(row: Int, column: Int) -> QCamFlowerPatchPosition? {
        allCases.first { $0.gridCoordinate == (row, column) }
    }
}

public struct QCamMarkerPatchDefinition {
    public let id: Int
    public let name: String
    public let referenceLab: QCamLab
    public let flowerPosition: QCamFlowerPatchPosition?
    public let samplingPolygon: [QCamNormalizedPoint]
}

public struct QCamCalibrationMarkerDefinition {
    public let kind: QCamCalibrationMarkerKind
    public let referenceName: String
    public let referenceVersion: String
    public let rows: Int
    public let columns: Int
    public let patches: [QCamMarkerPatchDefinition]
    public let maximumAcceptedRMSE: Double?
    public let minimumOrientationConfidenceMargin: Double?
}

public struct QCamFlowerReferenceTransform {
    public let lStarSlope: Double
    public let lStarIntercept: Double
    public let aStarSlope: Double
    public let aStarIntercept: Double
    public let bStarSlope: Double
    public let bStarIntercept: Double

    public func apply(to standardLab: QCamLab) -> QCamLab {
        QCamLab(
            lStar: lStarSlope * standardLab.lStar + lStarIntercept,
            aStar: aStarSlope * standardLab.aStar + aStarIntercept,
            bStar: bStarSlope * standardLab.bStar + bStarIntercept
        )
    }
}

public struct QCamCalibrationOrientationCandidate: Codable, Equatable {
    public let orientation: String
    public let rmse: Double
}

public struct QCamFlowerOrientationFit {
    public let orientation: QCamFlowerOrientation
    public let coefficients: [[Double]]
    public let candidates: [QCamCalibrationOrientationCandidate]
    public let confidenceMargin: Double?
    public let warning: String?
}

public struct QCamManualFlowerOrientationFit {
    public let measuredIndicesInReferenceOrder: [Int]
    public let orientationLabel: String
    public let coefficients: [[Double]]
    public let candidates: [QCamCalibrationOrientationCandidate]
    public let confidenceMargin: Double?
    public let warning: String?
}

public enum QCamFlowerOrientation: String, Codable, CaseIterable {
    case upright
    case rotate90
    case rotate180
    case rotate270
    case mirrorHorizontal = "mirror_horizontal"
    case mirrorVertical = "mirror_vertical"
    case mirrorMainDiagonal = "mirror_main_diagonal"
    case mirrorAntiDiagonal = "mirror_anti_diagonal"

    public func measuredIndicesInReferenceOrder() -> [Int] {
        let positions = QCamFlowerPatchPosition.allCases
        let indexByPosition = Dictionary(uniqueKeysWithValues: positions.enumerated().map { ($0.element, $0.offset) })
        return positions.compactMap { referencePosition in
            indexByPosition[measuredPosition(for: referencePosition)]
        }
    }

    private func measuredPosition(for referencePosition: QCamFlowerPatchPosition) -> QCamFlowerPatchPosition {
        let coordinate = referencePosition.gridCoordinate
        let row = coordinate.row
        let column = coordinate.column
        let last = 2
        let measuredCoordinate: (row: Int, column: Int)
        switch self {
        case .upright:
            measuredCoordinate = (row, column)
        case .rotate90:
            measuredCoordinate = (column, last - row)
        case .rotate180:
            measuredCoordinate = (last - row, last - column)
        case .rotate270:
            measuredCoordinate = (last - column, row)
        case .mirrorHorizontal:
            measuredCoordinate = (row, last - column)
        case .mirrorVertical:
            measuredCoordinate = (last - row, column)
        case .mirrorMainDiagonal:
            measuredCoordinate = (column, row)
        case .mirrorAntiDiagonal:
            measuredCoordinate = (last - column, last - row)
        }
        return QCamFlowerPatchPosition.position(
            row: measuredCoordinate.row,
            column: measuredCoordinate.column
        ) ?? referencePosition
    }
}

public enum QCamCalibrationMarkerLibrary {
    public static let flowerReferenceTransform = QCamFlowerReferenceTransform(
        lStarSlope: 0.835,
        lStarIntercept: 9.881,
        aStarSlope: 0.868,
        aStarIntercept: -2.364,
        bStarSlope: 0.921,
        bStarIntercept: -2.633
    )

    public static let defaultKind: QCamCalibrationMarkerKind = .flower9

    public static func definition(for kind: QCamCalibrationMarkerKind) -> QCamCalibrationMarkerDefinition {
        switch kind {
        case .flower9:
            return flower9
        case .standard24:
            return standard24
        }
    }

    public static let standard24 = QCamCalibrationMarkerDefinition(
        kind: .standard24,
        referenceName: QCamColorCheckerReference.name,
        referenceVersion: QCamColorCheckerReference.version,
        rows: 4,
        columns: 6,
        patches: zip(QCamColorCheckerReference.patchDescriptors, QCamColorCheckerReference.labValues)
            .enumerated()
            .map { index, entry in
                QCamMarkerPatchDefinition(
                    id: index + 1,
                    name: "\(entry.0.code) \(entry.0.colorName)",
                    referenceLab: entry.1,
                    flowerPosition: nil,
                    samplingPolygon: []
                )
            },
        maximumAcceptedRMSE: QCamCalibration.maximumAcceptedRMSE,
        minimumOrientationConfidenceMargin: nil
    )

    public static let flower9 = QCamCalibrationMarkerDefinition(
        kind: .flower9,
        referenceName: "CKD printed flower marker 9-patch",
        referenceVersion: "flower9_printed_lab_regression_2026_07_21",
        rows: 3,
        columns: 3,
        patches: [
            flowerPatch(1, "Purple", standard24Index: 13, position: .northWest),
            flowerPatch(2, "White", standard24Index: 3, position: .north),
            flowerPatch(3, "Neutral 5", standard24Index: 15, position: .northEast),
            flowerPatch(4, "Moderate Red", standard24Index: 9, position: .west),
            flowerPatch(5, "Yellow", standard24Index: 14, position: .center),
            flowerPatch(6, "Blue", standard24Index: 2, position: .east),
            flowerPatch(7, "Orange", standard24Index: 1, position: .southWest),
            flowerPatch(8, "Orange Yellow", standard24Index: 21, position: .south),
            flowerPatch(9, "Green", standard24Index: 6, position: .southEast),
        ],
        maximumAcceptedRMSE: nil,
        minimumOrientationConfidenceMargin: nil
    )

    private static func flowerPatch(
        _ id: Int,
        _ name: String,
        standard24Index: Int,
        position: QCamFlowerPatchPosition
    ) -> QCamMarkerPatchDefinition {
        return QCamMarkerPatchDefinition(
            id: id,
            name: name,
            referenceLab: printedFlowerReferenceLab(
                from: QCamColorCheckerReference.labValues[standard24Index]
            ),
            flowerPosition: position,
            samplingPolygon: flowerSamplingPolygon(for: position)
        )
    }

    public static func printedFlowerReferenceLab(from standardLab: QCamLab) -> QCamLab {
        flowerReferenceTransform.apply(to: standardLab)
    }

    private static func flowerSamplingPolygon(for position: QCamFlowerPatchPosition) -> [QCamNormalizedPoint] {
        let center = position.normalizedCenter
        let halfSide = position == .center ? 0.075 : 0.065
        let rotation = position.usesDiagonalSamplingPolygon ? Double.pi / 4.0 : 0.0
        let cosine = cos(rotation)
        let sine = sin(rotation)

        return [
            (-halfSide, -halfSide),
            (halfSide, -halfSide),
            (halfSide, halfSide),
            (-halfSide, halfSide),
        ].map { localU, localV in
            QCamNormalizedPoint(
                u: center.u + localU * cosine - localV * sine,
                v: center.v + localU * sine + localV * cosine
            )
        }
    }
}

public enum QCamMarkerGeometry {
    public static func flowerPatchPolygons(corners: [QCamPoint]) -> [QCamPolygon] {
        let ordered = QCamCalibration.orderedCorners(corners)
        guard ordered.count == 4 else { return [] }
        return QCamCalibrationMarkerLibrary.flower9.patches.map { patch in
            polygon(for: patch.samplingPolygon, corners: ordered)
        }
    }

    public static func polygon(for points: [QCamNormalizedPoint], corners: [QCamPoint]) -> QCamPolygon {
        QCamPolygon(points: points.map {
            point(u: $0.u, v: $0.v, corners: corners)
        }).closed()
    }

    public static func polygon(for rect: QCamNormalizedRect, corners: [QCamPoint]) -> QCamPolygon {
        polygon(
            for: [
                QCamNormalizedPoint(u: rect.x, v: rect.y),
                QCamNormalizedPoint(u: rect.x + rect.width, v: rect.y),
                QCamNormalizedPoint(u: rect.x + rect.width, v: rect.y + rect.height),
                QCamNormalizedPoint(u: rect.x, v: rect.y + rect.height),
            ],
            corners: corners
        )
    }

    public static func point(u: Double, v: Double, corners: [QCamPoint]) -> QCamPoint {
        guard corners.count == 4 else { return QCamPoint(x: 0, y: 0) }
        let topLeft = corners[0]
        let topRight = corners[1]
        let bottomLeft = corners[2]
        let bottomRight = corners[3]
        let top = QCamPoint(
            x: topLeft.x + (topRight.x - topLeft.x) * u,
            y: topLeft.y + (topRight.y - topLeft.y) * u
        )
        let bottom = QCamPoint(
            x: bottomLeft.x + (bottomRight.x - bottomLeft.x) * u,
            y: bottomLeft.y + (bottomRight.y - bottomLeft.y) * u
        )
        return QCamPoint(
            x: top.x + (bottom.x - top.x) * v,
            y: top.y + (bottom.y - top.y) * v
        )
    }
}
