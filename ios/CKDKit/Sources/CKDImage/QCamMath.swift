import Foundation

public enum QCamMath {
    public static func rgbToLab(red: Double, green: Double, blue: Double) -> QCamLab {
        func linearize(_ value: Double) -> Double {
            value > 0.04045 ? pow((value + 0.055) / 1.055, 2.4) : value / 12.92
        }

        let r = linearize(red)
        let g = linearize(green)
        let b = linearize(blue)

        let x = (0.412453 * r + 0.357580 * g + 0.180423 * b) / 0.95047
        let y = (0.212671 * r + 0.715160 * g + 0.072169 * b) / 1.0
        let z = (0.019334 * r + 0.119193 * g + 0.950227 * b) / 1.08883

        func labPivot(_ value: Double) -> Double {
            value > 0.008856 ? cbrt(value) : 7.787 * value + 16.0 / 116.0
        }

        let fx = labPivot(x)
        let fy = labPivot(y)
        let fz = labPivot(z)
        return QCamLab(
            lStar: 116.0 * fy - 16.0,
            aStar: 500.0 * (fx - fy),
            bStar: 200.0 * (fy - fz)
        )
    }

    public static func affineCoefficients(measured: [QCamLab], reference: [QCamLab]) -> [[Double]]? {
        guard measured.count == reference.count, measured.count >= 4 else { return nil }
        var ata = Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
        var atb = Array(repeating: Array(repeating: 0.0, count: 3), count: 4)

        for (measuredLab, referenceLab) in zip(measured, reference) {
            let x = [measuredLab.lStar, measuredLab.aStar, measuredLab.bStar, 1.0]
            let y = [referenceLab.lStar, referenceLab.aStar, referenceLab.bStar]
            for row in 0..<4 {
                for col in 0..<4 {
                    ata[row][col] += x[row] * x[col]
                }
                for channel in 0..<3 {
                    atb[row][channel] += x[row] * y[channel]
                }
            }
        }

        return solve(ata: ata, atb: atb)
    }

    public static func abAffineCoefficients(measured: [QCamLab], reference: [QCamLab]) -> [[Double]]? {
        guard measured.count == reference.count, measured.count >= 4 else { return nil }
        guard let lFit = linearFit(
            x: measured.map(\.lStar),
            y: reference.map(\.lStar)
        ) else {
            return nil
        }

        var ata = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        var atb = Array(repeating: Array(repeating: 0.0, count: 2), count: 3)
        for (measuredLab, referenceLab) in zip(measured, reference) {
            let x = [measuredLab.aStar, measuredLab.bStar, 1.0]
            let y = [referenceLab.aStar, referenceLab.bStar]
            for row in 0..<3 {
                for col in 0..<3 {
                    ata[row][col] += x[row] * x[col]
                }
                for channel in 0..<2 {
                    atb[row][channel] += x[row] * y[channel]
                }
            }
        }
        guard let abCoefficients = solve(ata: ata, atb: atb), abCoefficients.count == 3 else {
            return nil
        }

        return [
            [lFit.slope, 0.0, 0.0],
            [0.0, abCoefficients[0][0], abCoefficients[0][1]],
            [0.0, abCoefficients[1][0], abCoefficients[1][1]],
            [lFit.intercept, abCoefficients[2][0], abCoefficients[2][1]],
        ]
    }

    public static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        if sorted.count % 2 == 0 {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
        }
        return sorted[sorted.count / 2]
    }

    public static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    public static func standardDeviation(_ values: [Double]) -> Double {
        let avg = mean(values)
        return sqrt(values.reduce(0) { $0 + pow($1 - avg, 2) } / Double(values.count))
    }

    public static func distance(_ lhs: QCamPoint, _ rhs: QCamPoint) -> Double {
        sqrt(pow(lhs.x - rhs.x, 2) + pow(lhs.y - rhs.y, 2))
    }

    public static func blackness(_ lab: QCamLab) -> Double {
        lab.lStar * ceil(sqrt(pow(lab.aStar, 2) + pow(lab.bStar, 2)))
    }

    public static func polygonContains(points: [QCamPoint], x: Double, y: Double) -> Bool {
        var isInside = false
        var j = points.count - 1
        for i in points.indices {
            let pi = points[i]
            let pj = points[j]
            let intersects = ((pi.y > y) != (pj.y > y)) &&
                (x < (pj.x - pi.x) * (y - pi.y) / (pj.y - pi.y) + pi.x)
            if intersects {
                isInside.toggle()
            }
            j = i
        }
        return isInside
    }

    public static func polygonContainsIncludingBoundary(points: [QCamPoint], x: Double, y: Double) -> Bool {
        guard points.count >= 3 else { return false }
        for index in points.indices {
            let nextIndex = points.index(after: index) == points.endIndex ? points.startIndex : points.index(after: index)
            if pointIsOnSegment(pointX: x, pointY: y, start: points[index], end: points[nextIndex]) {
                return true
            }
        }
        return polygonContains(points: points, x: x, y: y)
    }

    private static func linearFit(x: [Double], y: [Double]) -> (slope: Double, intercept: Double)? {
        guard x.count == y.count, x.count >= 2 else { return nil }
        let meanX = mean(x)
        let meanY = mean(y)
        var numerator = 0.0
        var denominator = 0.0
        for (xValue, yValue) in zip(x, y) {
            numerator += (xValue - meanX) * (yValue - meanY)
            denominator += pow(xValue - meanX, 2)
        }
        guard abs(denominator) > 1e-12 else { return nil }
        let slope = numerator / denominator
        return (slope, meanY - slope * meanX)
    }

    private static func pointIsOnSegment(
        pointX: Double,
        pointY: Double,
        start: QCamPoint,
        end: QCamPoint
    ) -> Bool {
        let epsilon = 1e-9
        let cross = (pointX - start.x) * (end.y - start.y) - (pointY - start.y) * (end.x - start.x)
        guard abs(cross) <= epsilon else { return false }
        return pointX >= min(start.x, end.x) - epsilon &&
            pointX <= max(start.x, end.x) + epsilon &&
            pointY >= min(start.y, end.y) - epsilon &&
            pointY <= max(start.y, end.y) + epsilon
    }

    private static func solve(ata: [[Double]], atb: [[Double]]) -> [[Double]]? {
        let size = ata.count
        guard size > 0,
              atb.count == size,
              ata.allSatisfy({ $0.count == size }),
              let rhsCount = atb.first?.count,
              atb.allSatisfy({ $0.count == rhsCount }) else {
            return nil
        }

        var matrix = Array(repeating: Array(repeating: 0.0, count: size + rhsCount), count: size)
        for row in 0..<size {
            for col in 0..<size {
                matrix[row][col] = ata[row][col]
            }
            for col in 0..<rhsCount {
                matrix[row][col + size] = atb[row][col]
            }
        }

        for pivot in 0..<size {
            var maxRow = pivot
            var maxValue = abs(matrix[pivot][pivot])
            for row in pivot..<size where abs(matrix[row][pivot]) > maxValue {
                maxValue = abs(matrix[row][pivot])
                maxRow = row
            }
            guard maxValue > 1e-12 else { return nil }
            if maxRow != pivot {
                matrix.swapAt(pivot, maxRow)
            }

            let pivotValue = matrix[pivot][pivot]
            for col in pivot..<(size + rhsCount) {
                matrix[pivot][col] /= pivotValue
            }

            for row in 0..<size where row != pivot {
                let factor = matrix[row][pivot]
                for col in pivot..<(size + rhsCount) {
                    matrix[row][col] -= factor * matrix[pivot][col]
                }
            }
        }

        return (0..<size).map { row in
            (0..<rhsCount).map { col in matrix[row][col + size] }
        }
    }
}
