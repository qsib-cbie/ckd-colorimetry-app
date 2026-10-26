import Foundation

public struct QCamLab: Codable, Hashable, Sendable {
    public let lStar: Double
    public let aStar: Double
    public let bStar: Double

    public init(lStar: Double, aStar: Double, bStar: Double) {
        self.lStar = lStar
        self.aStar = aStar
        self.bStar = bStar
    }

    enum CodingKeys: String, CodingKey {
        case lStar = "l_star"
        case aStar = "a_star"
        case bStar = "b_star"
    }
}

public struct QCamLabStats: Sendable {
    public let median: QCamLab
    public let mean: QCamLab
    public let standardDeviation: QCamLab
    public let pixelCount: Int
}

public struct QCamRGBMean: Codable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum QCamPolygonSampling: Sendable {
    case centerContainment
    case boundaryInclusivePolygon
}

public struct QCamRGBAImage: Sendable {
    public let width: Int
    public let height: Int
    public let data: Data

    public init(width: Int, height: Int, data: Data) {
        self.width = width
        self.height = height
        self.data = data
    }

    public func rgbMean(for polygon: QCamPolygon, sampling: QCamPolygonSampling = .centerContainment) throws -> QCamRGBMean {
        var rSum = 0.0
        var gSum = 0.0
        var bSum = 0.0
        var count = 0.0

        try visitPixels(in: polygon, sampling: sampling) { x, y in
            let index = pixelIndex(x: x, y: y)
            rSum += Double(data[index])
            gSum += Double(data[index + 1])
            bSum += Double(data[index + 2])
            count += 1
        }

        guard count > 0 else { throw QCamError.emptyPolygon }
        return QCamRGBMean(
            red: rSum / count,
            green: gSum / count,
            blue: bSum / count
        )
    }

    public func labStats(for polygon: QCamPolygon, sampling: QCamPolygonSampling = .centerContainment) throws -> QCamLabStats {
        try stats(for: polygon, sampling: sampling) { $0 }
    }

    public func calibratedLabStats(
        for polygon: QCamPolygon,
        calibration: QCamCalibration,
        sampling: QCamPolygonSampling = .centerContainment
    ) throws -> QCamLabStats {
        try stats(for: polygon, sampling: sampling) { calibration.apply(to: $0) }
    }

    public func stats(
        for polygon: QCamPolygon,
        sampling: QCamPolygonSampling,
        transform: (QCamLab) -> QCamLab
    ) throws -> QCamLabStats {
        var lValues: [Double] = []
        var aValues: [Double] = []
        var bValues: [Double] = []
        lValues.reserveCapacity(4096)
        aValues.reserveCapacity(4096)
        bValues.reserveCapacity(4096)

        try visitPixels(in: polygon, sampling: sampling) { x, y in
            let lab = transform(labAt(x: x, y: y))
            lValues.append(lab.lStar)
            aValues.append(lab.aStar)
            bValues.append(lab.bStar)
        }

        guard !lValues.isEmpty else { throw QCamError.emptyPolygon }
        return QCamLabStats(
            median: QCamLab(
                lStar: QCamMath.median(lValues),
                aStar: QCamMath.median(aValues),
                bStar: QCamMath.median(bValues)
            ),
            mean: QCamLab(
                lStar: QCamMath.mean(lValues),
                aStar: QCamMath.mean(aValues),
                bStar: QCamMath.mean(bValues)
            ),
            standardDeviation: QCamLab(
                lStar: QCamMath.standardDeviation(lValues),
                aStar: QCamMath.standardDeviation(aValues),
                bStar: QCamMath.standardDeviation(bValues)
            ),
            pixelCount: lValues.count
        )
    }

    private func labAt(x: Int, y: Int) -> QCamLab {
        let index = pixelIndex(x: x, y: y)
        return QCamMath.rgbToLab(
            red: Double(data[index]) / 255.0,
            green: Double(data[index + 1]) / 255.0,
            blue: Double(data[index + 2]) / 255.0
        )
    }

    private func pixelIndex(x: Int, y: Int) -> Int {
        (y * width + x) * 4
    }

    private func visitPixels(
        in polygon: QCamPolygon,
        sampling: QCamPolygonSampling,
        _ visit: (Int, Int) -> Void
    ) throws {
        let points = polygon.points
        guard points.count >= 3 else { throw QCamError.emptyPolygon }
        let minX = max(0, Int(floor(points.map(\.x).min() ?? 0)))
        let maxX = min(width - 1, Int(ceil(points.map(\.x).max() ?? 0)))
        let minY = max(0, Int(floor(points.map(\.y).min() ?? 0)))
        let maxY = min(height - 1, Int(ceil(points.map(\.y).max() ?? 0)))
        guard minX <= maxX, minY <= maxY else { throw QCamError.emptyPolygon }

        for y in minY...maxY {
            for x in minX...maxX where includesPixel(x: x, y: y, points: points, sampling: sampling) {
                visit(x, y)
            }
        }
    }

    private func includesPixel(
        x: Int,
        y: Int,
        points: [QCamPoint],
        sampling: QCamPolygonSampling
    ) -> Bool {
        switch sampling {
        case .centerContainment:
            return QCamMath.polygonContains(points: points, x: Double(x) + 0.5, y: Double(y) + 0.5)
        case .boundaryInclusivePolygon:
            return QCamMath.polygonContainsIncludingBoundary(points: points, x: Double(x), y: Double(y))
        }
    }
}
