import CKDImage
import CKDResults
import Foundation

public struct CalibrationFit: Sendable {
    public var coefficients: [[Double]]
    public var rmse: Double
    public var deltaE: [Double]
    public var measuredLab: [[Double]]
    public var referenceLab: [[Double]]
    public var orientation = ""
    public var sampleOrder: [Int] = []
}

public enum MacCalibration {
    public static let standardLab: [[Double]] = [
        [37.54, 14.37, 14.92], [62.73, 35.83, 56.5], [28.37, 15.42, -49.8], [95.19, -1.03, 2.93],
        [64.66, 19.27, 17.5], [39.43, 10.75, -45.17], [54.38, -39.72, 32.27], [81.29, -0.57, 0.44],
        [49.32, -3.82, -22.54], [50.57, 48.64, 16.67], [42.43, 51.05, 28.62], [66.89, -0.75, -0.06],
        [43.46, -12.74, 22.72], [30.1, 22.54, -20.87], [81.8, 2.67, 80.41], [50.76, -0.13, 0.14],
        [54.94, 9.61, -24.79], [71.77, -24.13, 58.19], [50.63, 51.28, -14.12], [35.63, -0.46, -0.48],
        [70.48, -32.26, -0.37], [71.51, 18.24, 67.37], [49.57, -29.71, -28.32], [20.64, 0.07, -0.46],
    ]
    public static let flowerLab: [[Double]] = [13, 3, 15, 9, 14, 2, 1, 21, 6].map { index in
        let scale = [0.835, 0.868, 0.921]
        let offset = [9.881, -2.364, -2.633]
        return (0..<3).map { standardLab[index][$0] * scale[$0] + offset[$0] }
    }
    public static let standard24MaxRMSE = 12.0

    public static func orderCorners(_ points: [QCamPoint]) throws -> [QCamPoint] {
        var p = points
        if p.count > 1, p.first == p.last { p.removeLast() }
        guard p.count == 4 else { throw DocumentError("Place exactly four marker corners.") }
        let cx = p.map(\.x).reduce(0, +) / 4
        let cy = p.map(\.y).reduce(0, +) / 4
        let cyclic = p.sorted { atan2($0.y - cy, $0.x - cx) < atan2($1.y - cy, $1.x - cx) }
        let signs = (0..<4).map { i -> Double in
            let a = cyclic[i], b = cyclic[(i + 1) % 4], c = cyclic[(i + 2) % 4]
            return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        guard signs.min()! > 0 else { throw DocumentError("Marker corners must form a convex quadrilateral.") }
        return [cyclic[0], cyclic[1], cyclic[3], cyclic[2]]
    }

    static func mapPatch(_ c: [QCamPoint], _ uv: [(Double, Double)]) -> [QCamPoint] {
        uv.map { u, v in
            let a = (1 - u) * (1 - v), b = u * (1 - v), d = (1 - u) * v, e = u * v
            return QCamPoint(x: a * c[0].x + b * c[1].x + d * c[2].x + e * c[3].x,
                             y: a * c[0].y + b * c[1].y + d * c[2].y + e * c[3].y)
        }
    }

    public static func markerPolygons(mode: String, corners: [QCamPoint]) throws -> [[QCamPoint]] {
        let c = try orderCorners(corners)
        if mode == "flower_9" {
            let centers = [(0.30, 0.30), (0.5, 0.18), (0.7, 0.3), (0.18, 0.5), (0.5, 0.5),
                           (0.82, 0.5), (0.3, 0.7), (0.5, 0.82), (0.7, 0.7)]
            return centers.enumerated().map { i, center in
                let s = i == 4 ? 0.075 : 0.065
                var offset = [(-s, -s), (s, -s), (s, s), (-s, s)]
                if [0, 2, 6, 8].contains(i) {
                    let t = Double.pi / 4
                    offset = offset.map { x, y in (x * cos(t) + y * -sin(t), x * sin(t) + y * cos(t)) }
                }
                return mapPatch(c, offset.map { ($0.0 + center.0, $0.1 + center.1) })
            }
        }
        func norm(_ a: QCamPoint, _ b: QCamPoint) -> Double { sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)) }
        let landscape = norm(c[1], c[0]) + norm(c[3], c[2]) >= norm(c[2], c[0]) + norm(c[3], c[1])
        var patches: [[QCamPoint]] = []
        for x in 0..<6 {
            for y in 0..<4 {
                let u = 0.05 + Double(x) / 6, v = 0.075 + Double(y) / 4
                var uv = [(u, v), (u + 1.0 / 15, v), (u + 1.0 / 15, v + 0.1), (u, v + 0.1)]
                if !landscape { uv = uv.map { ($0.1, $0.0) } }
                patches.append(mapPatch(c, uv))
            }
        }
        return patches
    }

    public static func fit(samples: [[Double]], reference: [[Double]]) throws -> CalibrationFit {
        let n = samples.count
        guard let l = leastSquares(samples.map { [$0[0], 1] }, reference.map { [$0[0]] }),
              let ab = leastSquares(samples.map { [$0[1], $0[2], 1] }, reference.map { [$0[1], $0[2]] }) else {
            throw DocumentError("Calibration is degenerate. Select the correct color patches.")
        }
        var coefficients = Array(repeating: [0.0, 0.0, 0.0], count: 4)
        coefficients[0][0] = l[0][0]
        coefficients[3][0] = l[1][0]
        for row in 0..<3 {
            coefficients[row + 1][1] = ab[row][0]
            coefficients[row + 1][2] = ab[row][1]
        }
        let summary = CalibrationSummary(coefficients: coefficients, rmse: nil, referenceLab: nil)
        let corrected = samples.map { summary.apply($0)! }
        var squared = 0.0
        var deltaE: [Double] = []
        for (row, target) in zip(corrected, reference) {
            let d = (0..<3).map { row[$0] - target[$0] }
            squared += d.reduce(0) { $0 + $1 * $1 }
            deltaE.append(sqrt(d.reduce(0) { $0 + $1 * $1 }))
        }
        return CalibrationFit(coefficients: coefficients, rmse: sqrt(squared / Double(3 * n)), deltaE: deltaE,
                              measuredLab: samples, referenceLab: reference)
    }

    static func candidates(samples: [[Double]], mode: String, patches: [[QCamPoint]]) -> [(String, [Int])] {
        if mode == "standard_24_grid" {
            let options = [(-1, -1, 0), (1, -1, 20), (-1, 1, 3), (1, 1, 23)]
            let chosen = options.min { a, b in darkness(samples[a.2]) < darkness(samples[b.2]) }!
            let xs = chosen.0 == 1 ? Array(0..<6) : Array((0..<6).reversed())
            let ys = chosen.1 == 1 ? Array(0..<4) : Array((0..<4).reversed())
            return [("dark_corner_order", xs.flatMap { x in ys.map { x * 4 + $0 } })]
        }
        if mode == "flower_9_manual" {
            let centers = patches.map { patch -> (Double, Double) in
                var p = patch
                if p.count > 1, p.first == p.last { p.removeLast() }
                return (p.map(\.x).reduce(0, +) / Double(p.count), p.map(\.y).reduce(0, +) / Double(p.count))
            }
            let mx = centers.map(\.0).reduce(0, +) / Double(centers.count)
            let my = centers.map(\.1).reduce(0, +) / Double(centers.count)
            let center = centers.indices.min { i, j in
                hypot(centers[i].0 - mx, centers[i].1 - my) < hypot(centers[j].0 - mx, centers[j].1 - my)
            }!
            let ring = centers.indices.filter { $0 != center }.sorted { i, j in
                atan2(centers[i].1 - centers[center].1, centers[i].0 - centers[center].0)
                    < atan2(centers[j].1 - centers[center].1, centers[j].0 - centers[center].0)
            }
            let referenceRing = [1, 2, 5, 8, 7, 6, 3, 0]
            var result: [(String, [Int])] = []
            for direction in [1, -1] {
                for shift in 0..<8 {
                    var order = Array(repeating: 0, count: 9)
                    order[4] = center
                    for (position, reference) in referenceRing.enumerated() {
                        order[reference] = ring[((shift + direction * position) % 8 + 8) % 8]
                    }
                    result.append(("ring_\(direction)_\(shift)", order))
                }
            }
            return result
        }
        let names = ["upright", "rotate90", "rotate180", "rotate270", "mirror_horizontal", "mirror_vertical",
                     "mirror_main_diagonal", "mirror_anti_diagonal"]
        var orders = Array(repeating: [Int](), count: 8)
        for r in 0..<3 {
            for c in 0..<3 {
                let coords = [(r, c), (c, 2 - r), (2 - r, 2 - c), (2 - c, r), (r, 2 - c), (2 - r, c), (c, r), (2 - c, 2 - r)]
                for (index, coordinate) in coords.enumerated() {
                    orders[index].append(coordinate.0 * 3 + coordinate.1)
                }
            }
        }
        return Array(zip(names, orders))
    }

    private static func darkness(_ lab: [Double]) -> Double {
        lab[0] * ceil(sqrt(lab[1] * lab[1] + lab[2] * lab[2]))
    }

    public static func calibrate(image: QCamRGBAImage, draft: Draft) throws -> JSONValue {
        let mode = draft.mode
        let patches = mode == "flower_9_manual" ? draft.manualPatches : try markerPolygons(mode: mode, corners: draft.corners)
        let expected = mode == "standard_24_grid" ? 24 : 9
        guard patches.count == expected else { throw DocumentError("Draw exactly \(expected) calibration patches.") }
        let samples = try patches.map { try AnalysisPipeline.labStats(image, $0).median }
        let reference = expected == 24 ? standardLab : flowerLab
        var fits: [CalibrationFit] = []
        for (name, order) in candidates(samples: samples, mode: mode, patches: patches) {
            var fit = try fit(samples: order.map { samples[$0] }, reference: reference)
            fit.orientation = name
            fit.sampleOrder = order
            fits.append(fit)
        }
        let ranked = fits.enumerated().sorted { ($0.element.rmse, $0.offset) < ($1.element.rmse, $1.offset) }.map(\.element)
        let best = ranked[0]
        if expected == 24 && best.rmse > standard24MaxRMSE {
            throw DocumentError("Standard 24 calibration RMSE \(String(format: "%.2f", best.rmse)) exceeds 12. Check the marker corners.")
        }
        func matrix(_ rows: [[Double]]) -> JSONValue { .array(rows.map { .array($0.map(JSONValue.double)) }) }
        return .object([
            ("coefficients", matrix(best.coefficients)), ("rmse", .double(best.rmse)),
            ("delta_e", .array(best.deltaE.map(JSONValue.double))), ("measured_lab", matrix(best.measuredLab)),
            ("reference_lab", matrix(best.referenceLab)), ("orientation", .string(best.orientation)),
            ("sample_order", .array(best.sampleOrder.map(JSONValue.int))),
            ("confidence", ranked.count > 1 ? .double(ranked[1].rmse - best.rmse) : .null),
            ("patches", .array(patches.map { patch in .array(patch.map { .object([("x", .double($0.x)), ("y", .double($0.y))]) }) })),
            ("mode", .string(mode)),
            ("reference_version", .string(expected == 24 ? "standard_24" : CKDEquations.flowerVersion)),
        ])
    }

    static func leastSquares(_ a: [[Double]], _ b: [[Double]]) -> [[Double]]? {
        let rows = a.count, columns = a.first?.count ?? 0, outputs = b.first?.count ?? 0
        guard rows >= columns, columns > 0 else { return nil }
        var q = a
        var rhs = b
        var diagonal = Array(repeating: 0.0, count: columns)
        let scale = a.flatMap { $0 }.map(abs).max() ?? 0
        for k in 0..<columns {
            var norm = 0.0
            for i in k..<rows { norm += q[i][k] * q[i][k] }
            norm = sqrt(norm)
            guard norm > 1e-12 * max(1, scale) * Double(rows) else { return nil }
            let alpha = q[k][k] > 0 ? -norm : norm
            var v = Array(repeating: 0.0, count: rows)
            for i in k..<rows { v[i] = q[i][k] }
            v[k] -= alpha
            let vv = (k..<rows).reduce(0.0) { $0 + v[$1] * v[$1] }
            if vv > 0 {
                for j in k..<columns {
                    let dot = (k..<rows).reduce(0.0) { $0 + v[$1] * q[$1][j] }
                    for i in k..<rows { q[i][j] -= 2 * dot / vv * v[i] }
                }
                for j in 0..<outputs {
                    let dot = (k..<rows).reduce(0.0) { $0 + v[$1] * rhs[$1][j] }
                    for i in k..<rows { rhs[i][j] -= 2 * dot / vv * v[i] }
                }
            }
            diagonal[k] = q[k][k]
        }
        var x = Array(repeating: Array(repeating: 0.0, count: outputs), count: columns)
        for j in 0..<outputs {
            for k in stride(from: columns - 1, through: 0, by: -1) {
                var sum = rhs[k][j]
                for m in (k + 1)..<max(k + 1, columns) where m < columns { sum -= q[k][m] * x[m][j] }
                x[k][j] = sum / diagonal[k]
            }
        }
        return x
    }
}
