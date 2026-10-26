import Foundation

public struct QCamPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct QCamPolygon: Codable, Hashable, Sendable {
    public var points: [QCamPoint]

    public init(points: [QCamPoint]) {
        self.points = points
    }

    public func closed() -> QCamPolygon {
        guard let first = points.first, points.last != first else { return self }
        return QCamPolygon(points: points + [first])
    }

    public func withoutClosingPoint() -> QCamPolygon {
        guard let first = points.first, points.last == first else { return self }
        return QCamPolygon(points: Array(points.dropLast()))
    }

    public var center: QCamPoint {
        let uniquePoints: [QCamPoint]
        if let first = points.first, points.last == first {
            uniquePoints = Array(points.dropLast())
        } else {
            uniquePoints = points
        }
        guard !uniquePoints.isEmpty else { return QCamPoint(x: 0, y: 0) }
        let x = uniquePoints.reduce(0) { $0 + $1.x } / Double(uniquePoints.count)
        let y = uniquePoints.reduce(0) { $0 + $1.y } / Double(uniquePoints.count)
        return QCamPoint(x: x, y: y)
    }
}

public struct QCamImageDimensions: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct QCamROI: Codable, Identifiable, Sendable {
    public let id: Int
    public let label: String
    public let polygon: QCamPolygon

    public init(id: Int, label: String, polygon: QCamPolygon) {
        self.id = id
        self.label = label
        self.polygon = polygon
    }

    enum CodingKeys: String, CodingKey {
        case id = "roi_id"
        case label = "roi_label"
        case polygon
    }
}

public enum QCamROIPolygonIssue: Equatable, Sendable {
    case collapsed
    case duplicatePoint
    case zeroArea
    case selfIntersecting

    public var message: String {
        switch self {
        case .collapsed:
            return "has fewer than three distinct points"
        case .duplicatePoint:
            return "contains a duplicate point"
        case .zeroArea:
            return "has zero area"
        case .selfIntersecting:
            return "crosses itself"
        }
    }
}

public enum QCamPolygonGeometry {
    public static func polygonIssue(_ polygon: QCamPolygon) -> QCamROIPolygonIssue? {
        let points = polygonPointsWithoutClosingDuplicate(polygon)
        guard points.count >= 3 else { return .collapsed }

        let distinctPoints = Set(points)
        guard distinctPoints.count >= 3 else { return .collapsed }
        guard distinctPoints.count == points.count else { return .duplicatePoint }

        if polygonSelfIntersects(points) {
            return .selfIntersecting
        }
        if polygonHasZeroArea(points) {
            return .zeroArea
        }
        return nil
    }

    public static func polygonIsInBounds(
        _ polygon: QCamPolygon,
        imageWidth: Int,
        imageHeight: Int
    ) -> Bool {
        guard imageWidth > 0, imageHeight > 0 else { return false }
        let maxX = Double(imageWidth - 1)
        let maxY = Double(imageHeight - 1)
        let points = polygonPointsWithoutClosingDuplicate(polygon)
        return points.count >= 3 && points.allSatisfy { point in
            point.x.isFinite
                && point.y.isFinite
                && point.x >= 0
                && point.y >= 0
                && point.x <= maxX
                && point.y <= maxY
        }
    }

    public static func polygonPointsWithoutClosingDuplicate(_ polygon: QCamPolygon) -> [QCamPoint] {
        guard polygon.points.count > 1,
              polygon.points.first == polygon.points.last else {
            return polygon.points
        }
        return Array(polygon.points.dropLast())
    }

    private static func polygonHasZeroArea(_ points: [QCamPoint]) -> Bool {
        let twiceSignedArea = points.indices.reduce(0.0) { area, index in
            let next = points[(index + 1) % points.count]
            return area + points[index].x * next.y - next.x * points[index].y
        }
        return abs(twiceSignedArea) <= geometryEpsilon
    }

    private static func polygonSelfIntersects(_ points: [QCamPoint]) -> Bool {
        guard points.count >= 4 else { return false }

        for firstIndex in points.indices {
            let firstNextIndex = (firstIndex + 1) % points.count
            for secondIndex in points.indices where secondIndex > firstIndex {
                let secondNextIndex = (secondIndex + 1) % points.count
                let edgesAreAdjacent = firstNextIndex == secondIndex || secondNextIndex == firstIndex
                guard !edgesAreAdjacent else { continue }

                if segmentsIntersect(
                    points[firstIndex],
                    points[firstNextIndex],
                    points[secondIndex],
                    points[secondNextIndex]
                ) {
                    return true
                }
            }
        }
        return false
    }

    private static func segmentsIntersect(
        _ firstStart: QCamPoint,
        _ firstEnd: QCamPoint,
        _ secondStart: QCamPoint,
        _ secondEnd: QCamPoint
    ) -> Bool {
        let firstSideStart = crossProduct(firstStart, firstEnd, secondStart)
        let firstSideEnd = crossProduct(firstStart, firstEnd, secondEnd)
        let secondSideStart = crossProduct(secondStart, secondEnd, firstStart)
        let secondSideEnd = crossProduct(secondStart, secondEnd, firstEnd)

        if approximatelyZero(firstSideStart), point(secondStart, liesOn: firstStart, firstEnd) { return true }
        if approximatelyZero(firstSideEnd), point(secondEnd, liesOn: firstStart, firstEnd) { return true }
        if approximatelyZero(secondSideStart), point(firstStart, liesOn: secondStart, secondEnd) { return true }
        if approximatelyZero(secondSideEnd), point(firstEnd, liesOn: secondStart, secondEnd) { return true }

        return valuesHaveOppositeSigns(firstSideStart, firstSideEnd)
            && valuesHaveOppositeSigns(secondSideStart, secondSideEnd)
    }

    private static func crossProduct(_ start: QCamPoint, _ end: QCamPoint, _ point: QCamPoint) -> Double {
        (end.x - start.x) * (point.y - start.y)
            - (end.y - start.y) * (point.x - start.x)
    }

    private static func point(_ point: QCamPoint, liesOn start: QCamPoint, _ end: QCamPoint) -> Bool {
        point.x >= min(start.x, end.x) - geometryEpsilon
            && point.x <= max(start.x, end.x) + geometryEpsilon
            && point.y >= min(start.y, end.y) - geometryEpsilon
            && point.y <= max(start.y, end.y) + geometryEpsilon
    }

    private static func valuesHaveOppositeSigns(_ lhs: Double, _ rhs: Double) -> Bool {
        (lhs > geometryEpsilon && rhs < -geometryEpsilon)
            || (lhs < -geometryEpsilon && rhs > geometryEpsilon)
    }

    private static func approximatelyZero(_ value: Double) -> Bool {
        abs(value) <= geometryEpsilon
    }

    private static let geometryEpsilon = 1e-9
}
