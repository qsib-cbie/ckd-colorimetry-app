import Foundation

public struct QCamCalibration {
    public static let maximumAcceptedRMSE = 12.0

    public let coefficients: [[Double]]
    public let rmse: Double
    public let orientationLabel: String
    public let patchOrderLabel: String
    public let patchAudits: [QCamColorCheckerPatchAudit]
    public let markerKind: QCamCalibrationMarkerKind
    public let referenceName: String
    public let referenceVersion: String
    public let orientationConfidenceMargin: Double?
    public let orientationCandidates: [QCamCalibrationOrientationCandidate]
    public let orientationWarning: String?

    public static func bestFitCalibrate(buffer: QCamRGBAImage, corners: [QCamPoint]) throws -> QCamCalibration {
        let orderedCorners = orderedCorners(corners)
        let candidates = [
            ("x+,y+", false, false),
            ("x-,y+", true, false),
            ("x+,y-", false, true),
            ("x-,y-", true, true),
        ]

        var best: QCamCalibration?
        for orientation in QCamColorCheckerGeometryOrientation.allCases {
            let measuredGrid = try measuredPatchGrid(buffer: buffer, corners: orderedCorners, orientation: orientation)
            for candidate in candidates {
                let measuredPatches = orderedMeasuredPatches(measuredGrid, reverseX: candidate.1, reverseY: candidate.2)
                let measured = measuredPatches.map(\.median)
                guard let coefficients = QCamMath.affineCoefficients(measured: measured, reference: QCamColorCheckerReference.labValues) else {
                    continue
                }
                let patchAudits = makePatchAudits(
                    measuredPatches: measuredPatches,
                    orientation: orientation,
                    patchOrder: candidate.0,
                    coefficients: coefficients
                )
                let calibration = QCamCalibration(
                    coefficients: coefficients,
                    rmse: rmse(patchAudits: patchAudits),
                    orientationLabel: orientation.displayName,
                    patchOrderLabel: candidate.0,
                    patchAudits: patchAudits,
                    markerKind: .standard24,
                    referenceName: QCamColorCheckerReference.name,
                    referenceVersion: QCamColorCheckerReference.version,
                    orientationConfidenceMargin: nil,
                    orientationCandidates: [],
                    orientationWarning: nil
                )
                if best == nil || calibration.rmse < best!.rmse {
                    best = calibration
                }
            }
        }

        guard let best else { throw QCamError.singularCalibration }
        guard best.rmse <= maximumAcceptedRMSE else {
            throw QCamError.colorCalibrationRMSETooHigh(best.rmse, maximumAcceptedRMSE)
        }
        return best
    }

    public static func calibrate(
        buffer: QCamRGBAImage,
        corners: [QCamPoint],
        markerKind: QCamCalibrationMarkerKind = .standard24
    ) throws -> QCamCalibration {
        switch markerKind {
        case .flower9:
            return try calibrateFlower9(buffer: buffer, corners: corners)
        case .standard24:
            return try calibrateStandard24(buffer: buffer, corners: corners)
        }
    }

    private static func calibrateStandard24(buffer: QCamRGBAImage, corners: [QCamPoint]) throws -> QCamCalibration {
        let orderedCorners = orderedCorners(corners)
        let orientation = defaultGeometryOrientation(corners: orderedCorners)
        let measuredGrid = try measuredPatchGrid(
            buffer: buffer,
            corners: orderedCorners,
            orientation: orientation,
            sampling: .boundaryInclusivePolygon
        )
        let (measuredPatches, patchOrder) = colorInferredMeasuredPatches(measuredGrid)
        let measured = measuredPatches.map(\.median)
        guard let coefficients = QCamMath.abAffineCoefficients(
            measured: measured,
            reference: QCamColorCheckerReference.labValues
        ) else {
            throw QCamError.singularCalibration
        }
        let patchAudits = makePatchAudits(
            measuredPatches: measuredPatches,
            orientation: orientation,
            patchOrder: patchOrder,
            coefficients: coefficients
        )
        let calibration = QCamCalibration(
            coefficients: coefficients,
            rmse: rmse(patchAudits: patchAudits),
            orientationLabel: orientation.displayName,
            patchOrderLabel: patchOrder,
            patchAudits: patchAudits,
            markerKind: .standard24,
            referenceName: QCamColorCheckerReference.name,
            referenceVersion: QCamColorCheckerReference.version,
            orientationConfidenceMargin: nil,
            orientationCandidates: [],
            orientationWarning: nil
        )
        guard calibration.rmse <= maximumAcceptedRMSE else {
            throw QCamError.colorCalibrationRMSETooHigh(calibration.rmse, maximumAcceptedRMSE)
        }
        return calibration
    }

    private static func calibrateFlower9(buffer: QCamRGBAImage, corners: [QCamPoint]) throws -> QCamCalibration {
        let definition = QCamCalibrationMarkerLibrary.flower9
        let polygons = QCamMarkerGeometry.flowerPatchPolygons(corners: corners)
        guard polygons.count == definition.patches.count else { throw QCamError.incompleteColorChecker }

        let physicalPatches = try polygons.enumerated().map { index, polygon in
            guard let position = definition.patches[index].flowerPosition else {
                throw QCamError.incompleteColorChecker
            }
            let stats = try buffer.labStats(for: polygon, sampling: .boundaryInclusivePolygon)
            return QCamColorCheckerMeasuredPatch(
                flowerPosition: position,
                gridX: position.gridCoordinate.column,
                gridY: position.gridCoordinate.row,
                polygon: polygon,
                median: stats.median,
                mean: stats.mean,
                pixelCount: stats.pixelCount
            )
        }
        let reference = definition.patches.map(\.referenceLab)
        let fit = try bestFlowerOrientation(measuredLabs: physicalPatches.map(\.median))
        let selectedIndices = fit.orientation.measuredIndicesInReferenceOrder()
        let measuredPatches = selectedIndices.map { physicalPatches[$0] }
        let patchAudits = makePatchAudits(
            measuredPatches: measuredPatches,
            geometryOrientation: "flower_center_and_eight_petals",
            patchOrder: fit.orientation.rawValue,
            coefficients: fit.coefficients,
            reference: reference,
            referencePositions: definition.patches.map { $0.flowerPosition?.rawValue },
            calibrationInputStatistic: .median
        )
        let selected = QCamCalibration(
            coefficients: fit.coefficients,
            rmse: rmse(patchAudits: patchAudits),
            orientationLabel: fit.orientation.rawValue,
            patchOrderLabel: fit.orientation.rawValue,
            patchAudits: patchAudits,
            markerKind: .flower9,
            referenceName: definition.referenceName,
            referenceVersion: definition.referenceVersion,
            orientationConfidenceMargin: fit.confidenceMargin,
            orientationCandidates: fit.candidates,
            orientationWarning: fit.warning
        )
        if let maximumAcceptedRMSE = definition.maximumAcceptedRMSE,
           selected.rmse > maximumAcceptedRMSE {
            throw QCamError.colorCalibrationRMSETooHigh(selected.rmse, maximumAcceptedRMSE)
        }
        return selected
    }

    public static func calibrateFlower9(
        buffer: QCamRGBAImage,
        manualPolygons: [QCamPolygon]
    ) throws -> QCamCalibration {
        let definition = QCamCalibrationMarkerLibrary.flower9
        guard manualPolygons.count == definition.patches.count else {
            throw QCamError.incompleteManualFlowerCalibration(manualPolygons.count)
        }

        let physicalPatches = try manualPolygons.map { polygon -> QCamColorCheckerMeasuredPatch in
            if let issue = QCamPolygonGeometry.polygonIssue(polygon) {
                throw QCamError.invalidCalibrationPatch(issue)
            }
            guard QCamPolygonGeometry.polygonIsInBounds(
                polygon,
                imageWidth: buffer.width,
                imageHeight: buffer.height
            ) else {
                throw QCamError.calibrationPatchOutsideImage
            }
            let stats = try buffer.labStats(for: polygon, sampling: .boundaryInclusivePolygon)
            return QCamColorCheckerMeasuredPatch(
                flowerPosition: nil,
                gridX: 0,
                gridY: 0,
                polygon: polygon.closed(),
                median: stats.median,
                mean: stats.mean,
                pixelCount: stats.pixelCount
            )
        }

        let fit = try bestManualFlowerOrientation(
            measuredLabs: physicalPatches.map(\.median),
            polygons: manualPolygons
        )
        let measuredPatches = fit.measuredIndicesInReferenceOrder.enumerated().map { referenceIndex, measuredIndex in
            let measured = physicalPatches[measuredIndex]
            let position = definition.patches[referenceIndex].flowerPosition
            return QCamColorCheckerMeasuredPatch(
                flowerPosition: position,
                gridX: position?.gridCoordinate.column ?? 0,
                gridY: position?.gridCoordinate.row ?? 0,
                polygon: measured.polygon,
                median: measured.median,
                mean: measured.mean,
                pixelCount: measured.pixelCount
            )
        }
        let reference = definition.patches.map(\.referenceLab)
        let patchAudits = makePatchAudits(
            measuredPatches: measuredPatches,
            geometryOrientation: "flower_manual_polygons",
            patchOrder: fit.orientationLabel,
            coefficients: fit.coefficients,
            reference: reference,
            referencePositions: definition.patches.map { $0.flowerPosition?.rawValue },
            calibrationInputStatistic: .median
        )
        return QCamCalibration(
            coefficients: fit.coefficients,
            rmse: rmse(patchAudits: patchAudits),
            orientationLabel: fit.orientationLabel,
            patchOrderLabel: fit.orientationLabel,
            patchAudits: patchAudits,
            markerKind: .flower9,
            referenceName: definition.referenceName,
            referenceVersion: definition.referenceVersion,
            orientationConfidenceMargin: fit.confidenceMargin,
            orientationCandidates: fit.candidates,
            orientationWarning: fit.warning
        )
    }

    public static func bestManualFlowerOrientation(
        measuredLabs: [QCamLab],
        polygons: [QCamPolygon]
    ) throws -> QCamManualFlowerOrientationFit {
        let definition = QCamCalibrationMarkerLibrary.flower9
        guard measuredLabs.count == definition.patches.count,
              polygons.count == definition.patches.count else {
            throw QCamError.incompleteManualFlowerCalibration(min(measuredLabs.count, polygons.count))
        }

        let centers = polygons.map(polygonCenter)
        let overallCenter = QCamPoint(
            x: centers.map(\.x).reduce(0, +) / Double(centers.count),
            y: centers.map(\.y).reduce(0, +) / Double(centers.count)
        )
        guard let centerIndex = centers.indices.min(by: {
            QCamMath.distance(centers[$0], overallCenter) < QCamMath.distance(centers[$1], overallCenter)
        }) else {
            throw QCamError.incompleteManualFlowerCalibration(polygons.count)
        }
        let ringIndices = centers.indices
            .filter { $0 != centerIndex }
            .sorted {
                atan2(centers[$0].y - centers[centerIndex].y, centers[$0].x - centers[centerIndex].x)
                    < atan2(centers[$1].y - centers[centerIndex].y, centers[$1].x - centers[centerIndex].x)
            }
        guard ringIndices.count == 8 else {
            throw QCamError.incompleteManualFlowerCalibration(polygons.count)
        }

        let reference = definition.patches.map(\.referenceLab)
        let referenceRingIndices = [1, 2, 5, 8, 7, 6, 3, 0]
        var candidates: [(label: String, indices: [Int], coefficients: [[Double]], rmse: Double)] = []
        for direction in [1, -1] {
            for shift in 0..<ringIndices.count {
                var indices = Array(repeating: centerIndex, count: definition.patches.count)
                indices[4] = centerIndex
                for (ringPosition, referenceIndex) in referenceRingIndices.enumerated() {
                    let measuredRingIndex = positiveModulo(
                        shift + direction * ringPosition,
                        ringIndices.count
                    )
                    indices[referenceIndex] = ringIndices[measuredRingIndex]
                }
                let measured = indices.map { measuredLabs[$0] }
                guard let coefficients = QCamMath.abAffineCoefficients(
                    measured: measured,
                    reference: reference
                ) else {
                    continue
                }
                let squaredError = zip(measured, reference).reduce(0.0) { partial, pair in
                    let corrected = apply(coefficients: coefficients, to: pair.0)
                    return partial
                        + pow(corrected.lStar - pair.1.lStar, 2)
                        + pow(corrected.aStar - pair.1.aStar, 2)
                        + pow(corrected.bStar - pair.1.bStar, 2)
                }
                let label = "manual_ring_shift_\(shift)_\(direction == 1 ? "clockwise" : "counterclockwise")"
                candidates.append((
                    label,
                    indices,
                    coefficients,
                    sqrt(squaredError / Double(reference.count * 3))
                ))
            }
        }

        let sorted = candidates.sorted { $0.rmse < $1.rmse }
        guard let best = sorted.first else { throw QCamError.singularCalibration }
        let margin = sorted.count > 1 ? sorted[1].rmse - best.rmse : nil
        return QCamManualFlowerOrientationFit(
            measuredIndicesInReferenceOrder: best.indices,
            orientationLabel: best.label,
            coefficients: best.coefficients,
            candidates: sorted.map {
                QCamCalibrationOrientationCandidate(orientation: $0.label, rmse: $0.rmse)
            },
            confidenceMargin: margin,
            warning: orientationWarning(
                confidenceMargin: margin,
                minimumAcceptedMargin: definition.minimumOrientationConfidenceMargin
            )
        )
    }

    private static func polygonCenter(_ polygon: QCamPolygon) -> QCamPoint {
        let points = polygon.withoutClosingPoint().points
        guard !points.isEmpty else { return QCamPoint(x: 0, y: 0) }
        return QCamPoint(
            x: points.map(\.x).reduce(0, +) / Double(points.count),
            y: points.map(\.y).reduce(0, +) / Double(points.count)
        )
    }

    private static func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let remainder = value % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }

    public static func bestFlowerOrientation(measuredLabs: [QCamLab]) throws -> QCamFlowerOrientationFit {
        let definition = QCamCalibrationMarkerLibrary.flower9
        guard measuredLabs.count == definition.patches.count else { throw QCamError.incompleteColorChecker }
        let reference = definition.patches.map(\.referenceLab)
        var fitted: [(orientation: QCamFlowerOrientation, coefficients: [[Double]], rmse: Double)] = []

        for orientation in QCamFlowerOrientation.allCases {
            let indices = orientation.measuredIndicesInReferenceOrder()
            let measured = indices.map { measuredLabs[$0] }
            guard let coefficients = QCamMath.abAffineCoefficients(measured: measured, reference: reference) else {
                continue
            }
            let squaredError = zip(measured, reference).reduce(0.0) { partial, pair in
                let corrected = apply(coefficients: coefficients, to: pair.0)
                return partial
                    + pow(corrected.lStar - pair.1.lStar, 2)
                    + pow(corrected.aStar - pair.1.aStar, 2)
                    + pow(corrected.bStar - pair.1.bStar, 2)
            }
            let candidateRMSE = sqrt(squaredError / Double(reference.count * 3))
            fitted.append((orientation, coefficients, candidateRMSE))
        }

        let sorted = fitted.sorted { $0.rmse < $1.rmse }
        guard let best = sorted.first else { throw QCamError.singularCalibration }
        let margin = sorted.count > 1 ? sorted[1].rmse - best.rmse : nil
        return QCamFlowerOrientationFit(
            orientation: best.orientation,
            coefficients: best.coefficients,
            candidates: sorted.map {
                QCamCalibrationOrientationCandidate(orientation: $0.orientation.rawValue, rmse: $0.rmse)
            },
            confidenceMargin: margin,
            warning: orientationWarning(
                confidenceMargin: margin,
                minimumAcceptedMargin: definition.minimumOrientationConfidenceMargin
            )
        )
    }

    public static func orderedCorners(_ corners: [QCamPoint]) -> [QCamPoint] {
        guard corners.count == 4 else { return corners }
        let center = QCamPoint(
            x: corners.map(\.x).reduce(0, +) / 4.0,
            y: corners.map(\.y).reduce(0, +) / 4.0
        )
        let cyclic = corners.sorted {
            atan2($0.y - center.y, $0.x - center.x)
                < atan2($1.y - center.y, $1.x - center.x)
        }
        return [cyclic[0], cyclic[1], cyclic[3], cyclic[2]]
    }

    public static func orientationWarning(
        confidenceMargin: Double?,
        minimumAcceptedMargin: Double? = nil
    ) -> String? {
        guard let minimumAcceptedMargin else { return nil }
        guard let confidenceMargin else {
            return "Flower marker orientation confidence could not be calculated."
        }
        guard confidenceMargin < minimumAcceptedMargin else { return nil }
        return "Flower marker orientation is ambiguous because the two best fits are separated by only \(String(format: "%.3f", confidenceMargin)) RMSE."
    }

    public func apply(to lab: QCamLab) -> QCamLab {
        QCamCalibration.apply(coefficients: coefficients, to: lab)
    }

    public static func flattenedPatchPolygons(
        corners: [QCamPoint],
        markerKind: QCamCalibrationMarkerKind = .standard24
    ) -> [QCamPolygon] {
        guard corners.count == 4 else { return [] }
        if markerKind == .flower9 {
            return QCamMarkerGeometry.flowerPatchPolygons(corners: corners)
        }
        let orderedCorners = orderedCorners(corners)
        return colorCheckerPatchPolygons(
            corners: orderedCorners,
            orientation: defaultGeometryOrientation(corners: orderedCorners)
        )
        .flatMap { $0 }
    }

    private static func apply(coefficients: [[Double]], to lab: QCamLab) -> QCamLab {
        let source = [lab.lStar, lab.aStar, lab.bStar, 1.0]
        return QCamLab(
            lStar: zip(source, coefficients).reduce(0) { $0 + $1.0 * $1.1[0] },
            aStar: zip(source, coefficients).reduce(0) { $0 + $1.0 * $1.1[1] },
            bStar: zip(source, coefficients).reduce(0) { $0 + $1.0 * $1.1[2] }
        )
    }

    private static func measuredPatchGrid(
        buffer: QCamRGBAImage,
        corners: [QCamPoint],
        orientation: QCamColorCheckerGeometryOrientation,
        sampling: QCamPolygonSampling = .centerContainment
    ) throws -> [[QCamColorCheckerMeasuredPatch]] {
        let patches = colorCheckerPatchPolygons(corners: corners, orientation: orientation)
        var measuredGrid = Array(
            repeating: Array(repeating: QCamColorCheckerMeasuredPatch.empty, count: 4),
            count: 6
        )

        for x in 0..<6 {
            for y in 0..<4 {
                let stats = try buffer.labStats(for: patches[x][y], sampling: sampling)
                measuredGrid[x][y] = QCamColorCheckerMeasuredPatch(
                    flowerPosition: nil,
                    gridX: x,
                    gridY: y,
                    polygon: patches[x][y],
                    median: stats.median,
                    mean: stats.mean,
                    pixelCount: stats.pixelCount
                )
            }
        }
        return measuredGrid
    }

    private static func defaultGeometryOrientation(corners: [QCamPoint]) -> QCamColorCheckerGeometryOrientation {
        guard corners.count == 4 else { return .landscape6x4 }
        let topWidth = QCamMath.distance(corners[0], corners[1])
        let bottomWidth = QCamMath.distance(corners[2], corners[3])
        let leftHeight = QCamMath.distance(corners[0], corners[2])
        let rightHeight = QCamMath.distance(corners[1], corners[3])
        let width = (topWidth + bottomWidth) / 2.0
        let height = (leftHeight + rightHeight) / 2.0
        return width >= height ? .landscape6x4 : .portrait4x6
    }

    private static func colorCheckerPatchPolygons(
        corners: [QCamPoint],
        orientation: QCamColorCheckerGeometryOrientation
    ) -> [[QCamPolygon]] {
        let squareNX = 6
        let squareNY = 4
        let aspectRatio = 1.5
        let borderFraction = 60.0
        let squareFraction = 7.5
        let spacingFraction = 30.0
        let rectFraction = 2.0

        let topLeft = corners[0]
        let topRight = corners[1]
        let bottomLeft = corners[2]
        let bottomRight = corners[3]

        func interpolate(_ u: Double, _ v: Double) -> QCamPoint {
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

        let squareSizeU = 1.0 / (squareFraction * rectFraction)
        let squareSizeV = squareSizeU * aspectRatio
        let startU = 1.0 / borderFraction + 1.0 / (squareFraction / (1.0 - 1.0 / rectFraction) * 2.0)
        let startV = startU * aspectRatio
        let stepU = 1.0 / squareFraction + 1.0 / spacingFraction
        let stepV = stepU * aspectRatio

        var polygons = Array(repeating: Array(repeating: QCamPolygon(points: []), count: squareNY), count: squareNX)
        for x in 0..<squareNX {
            for y in 0..<squareNY {
                let patchOrigin: (u: Double, v: Double)
                let patchSize: (u: Double, v: Double)
                switch orientation {
                case .landscape6x4:
                    patchOrigin = (
                        u: startU + Double(x) * stepU,
                        v: startV + Double(y) * stepV
                    )
                    patchSize = (u: squareSizeU, v: squareSizeV)
                case .portrait4x6:
                    patchOrigin = (
                        u: startV + Double(y) * stepV,
                        v: startU + Double(x) * stepU
                    )
                    patchSize = (u: squareSizeV, v: squareSizeU)
                }
                polygons[x][y] = QCamPolygon(points: [
                    interpolate(patchOrigin.u, patchOrigin.v),
                    interpolate(patchOrigin.u + patchSize.u, patchOrigin.v),
                    interpolate(patchOrigin.u + patchSize.u, patchOrigin.v + patchSize.v),
                    interpolate(patchOrigin.u, patchOrigin.v + patchSize.v),
                    interpolate(patchOrigin.u, patchOrigin.v),
                ])
            }
        }
        return polygons
    }

    private static func orderedMeasuredPatches(
        _ grid: [[QCamColorCheckerMeasuredPatch]],
        reverseX: Bool,
        reverseY: Bool
    ) -> [QCamColorCheckerMeasuredPatch] {
        let xValues = reverseX ? Array((0..<6).reversed()) : Array(0..<6)
        let yValues = reverseY ? Array((0..<4).reversed()) : Array(0..<4)
        var values: [QCamColorCheckerMeasuredPatch] = []
        for x in xValues {
            for y in yValues {
                values.append(grid[x][y])
            }
        }
        return values
    }

    private static func colorInferredMeasuredPatches(
        _ grid: [[QCamColorCheckerMeasuredPatch]]
    ) -> (patches: [QCamColorCheckerMeasuredPatch], patchOrder: String) {
        let candidates: [(xDirection: Int, yDirection: Int, patch: QCamColorCheckerMeasuredPatch)] = [
            (-1, -1, grid[0][0]),
            (1, -1, grid[5][0]),
            (-1, 1, grid[0][3]),
            (1, 1, grid[5][3]),
        ]
        let selected = candidates.min { lhs, rhs in
            QCamMath.blackness(lhs.patch.median) < QCamMath.blackness(rhs.patch.median)
        } ?? candidates[0]
        let xValues = selected.xDirection == 1 ? Array(0..<6) : Array((0..<6).reversed())
        let yValues = selected.yDirection == 1 ? Array(0..<4) : Array((0..<4).reversed())
        var values: [QCamColorCheckerMeasuredPatch] = []
        for x in xValues {
            for y in yValues {
                values.append(grid[x][y])
            }
        }
        let patchOrder = "x\(selected.xDirection == 1 ? "+" : "-"),y\(selected.yDirection == 1 ? "+" : "-")"
        return (values, patchOrder)
    }

    private static func makePatchAudits(
        measuredPatches: [QCamColorCheckerMeasuredPatch],
        orientation: QCamColorCheckerGeometryOrientation,
        patchOrder: String,
        coefficients: [[Double]]
    ) -> [QCamColorCheckerPatchAudit] {
        makePatchAudits(
            measuredPatches: measuredPatches,
            geometryOrientation: orientation.rawValue,
            patchOrder: patchOrder,
            coefficients: coefficients,
            reference: QCamColorCheckerReference.labValues,
            calibrationInputStatistic: .median
        )
    }

    private static func makePatchAudits(
        measuredPatches: [QCamColorCheckerMeasuredPatch],
        geometryOrientation: String,
        patchOrder: String,
        coefficients: [[Double]],
        reference: [QCamLab],
        referencePositions: [String?]? = nil,
        calibrationInputStatistic: QCamCalibrationPatchStatistic
    ) -> [QCamColorCheckerPatchAudit] {
        measuredPatches.enumerated().map { index, measuredPatch in
            let referenceLab = reference[index]
            let referencePosition: String?
            if let referencePositions, referencePositions.indices.contains(index) {
                referencePosition = referencePositions[index]
            } else {
                referencePosition = nil
            }
            let calibrationInput = calibrationInputStatistic == .mean
                ? measuredPatch.mean
                : measuredPatch.median
            let correctedLab = apply(coefficients: coefficients, to: calibrationInput)
            let residual = QCamLab(
                lStar: correctedLab.lStar - referenceLab.lStar,
                aStar: correctedLab.aStar - referenceLab.aStar,
                bStar: correctedLab.bStar - referenceLab.bStar
            )
            return QCamColorCheckerPatchAudit(
                patchID: index + 1,
                geometryOrientation: geometryOrientation,
                patchOrder: patchOrder,
                referencePosition: referencePosition,
                sampledPosition: measuredPatch.flowerPosition?.rawValue,
                gridX: measuredPatch.gridX,
                gridY: measuredPatch.gridY,
                polygon: measuredPatch.polygon,
                measuredMedian: measuredPatch.median,
                measuredMean: measuredPatch.mean,
                calibrationInputStatistic: calibrationInputStatistic.rawValue,
                correctedLab: correctedLab,
                referenceLab: referenceLab,
                correctedResidual: residual,
                deltaE: sqrt(pow(residual.lStar, 2) + pow(residual.aStar, 2) + pow(residual.bStar, 2)),
                pixelCount: measuredPatch.pixelCount
            )
        }
    }

    private static func rmse(patchAudits: [QCamColorCheckerPatchAudit]) -> Double {
        var squaredError = 0.0
        for patchAudit in patchAudits {
            squaredError += pow(patchAudit.correctedResidual.lStar, 2)
            squaredError += pow(patchAudit.correctedResidual.aStar, 2)
            squaredError += pow(patchAudit.correctedResidual.bStar, 2)
        }
        return sqrt(squaredError / Double(patchAudits.count * 3))
    }
}

public enum QCamColorCheckerReference {
    public static let name = "X-Rite ColorChecker 24-patch CIELAB"
    public static let version = "legacy_colorCheckerConstants_CC_REF_COLORS_v1"
    public static let patchDescriptors: [(code: String, colorName: String)] = [
        ("A1", "brown"),
        ("A2", "orange"),
        ("A3", "blue"),
        ("A4", "white"),
        ("B1", "peach"),
        ("B2", "medium blue"),
        ("B3", "green"),
        ("B4", "very light gray"),
        ("C1", "light blue"),
        ("C2", "light red"),
        ("C3", "red"),
        ("C4", "med-light gray"),
        ("D1", "forest green"),
        ("D2", "purple"),
        ("D3", "yellow"),
        ("D4", "med-dark gray"),
        ("E1", "fuschia"),
        ("E2", "light green"),
        ("E3", "pinkish-purple"),
        ("E4", "dark gray"),
        ("F1", "turquoise"),
        ("F2", "light orange"),
        ("F3", "aqua"),
        ("F4", "black"),
    ]
    public static let labValues: [QCamLab] = [
        QCamLab(lStar: 37.54, aStar: 14.37, bStar: 14.92),
        QCamLab(lStar: 62.73, aStar: 35.83, bStar: 56.5),
        QCamLab(lStar: 28.37, aStar: 15.42, bStar: -49.8),
        QCamLab(lStar: 95.19, aStar: -1.03, bStar: 2.93),
        QCamLab(lStar: 64.66, aStar: 19.27, bStar: 17.5),
        QCamLab(lStar: 39.43, aStar: 10.75, bStar: -45.17),
        QCamLab(lStar: 54.38, aStar: -39.72, bStar: 32.27),
        QCamLab(lStar: 81.29, aStar: -0.57, bStar: 0.44),
        QCamLab(lStar: 49.32, aStar: -3.82, bStar: -22.54),
        QCamLab(lStar: 50.57, aStar: 48.64, bStar: 16.67),
        QCamLab(lStar: 42.43, aStar: 51.05, bStar: 28.62),
        QCamLab(lStar: 66.89, aStar: -0.75, bStar: -0.06),
        QCamLab(lStar: 43.46, aStar: -12.74, bStar: 22.72),
        QCamLab(lStar: 30.1, aStar: 22.54, bStar: -20.87),
        QCamLab(lStar: 81.8, aStar: 2.67, bStar: 80.41),
        QCamLab(lStar: 50.76, aStar: -0.13, bStar: 0.14),
        QCamLab(lStar: 54.94, aStar: 9.61, bStar: -24.79),
        QCamLab(lStar: 71.77, aStar: -24.13, bStar: 58.19),
        QCamLab(lStar: 50.63, aStar: 51.28, bStar: -14.12),
        QCamLab(lStar: 35.63, aStar: -0.46, bStar: -0.48),
        QCamLab(lStar: 70.48, aStar: -32.26, bStar: -0.37),
        QCamLab(lStar: 71.51, aStar: 18.24, bStar: 67.37),
        QCamLab(lStar: 49.57, aStar: -29.71, bStar: -28.32),
        QCamLab(lStar: 20.64, aStar: 0.07, bStar: -0.46),
    ]

}
