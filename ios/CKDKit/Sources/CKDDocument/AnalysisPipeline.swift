import CKDImage
import CKDResults
import Foundation

public struct LabStats: Sendable {
    public let median: [Double]
    public let mean: [Double]
    public let standardDeviation: [Double]
    public let pixelCount: Int
}

public enum AnalysisPipeline {
    public static let maximumPixels = 50_000_000

    public static func labStats(_ image: QCamRGBAImage, _ points: [QCamPoint]) throws -> LabStats {
        let polygon = QCamPolygon(points: try PolygonRules.validate(points, width: image.width, height: image.height))
        let stats: QCamLabStats
        do {
            stats = try image.labStats(for: polygon, sampling: .boundaryInclusivePolygon)
        } catch QCamError.emptyPolygon {
            throw DocumentError("The polygon contains no image pixels.")
        }
        func lab(_ value: QCamLab) -> [Double] { [value.lStar, value.aStar, value.bStar] }
        return LabStats(median: lab(stats.median), mean: lab(stats.mean), standardDeviation: lab(stats.standardDeviation),
                        pixelCount: stats.pixelCount)
    }

    static func rasterBlock(_ meta: [(String, JSONValue)], artifact: String, image: QCamRGBAImage) -> JSONValue {
        .object(meta + [
            ("array", .string(".cache/\(artifact).npy")), ("preview", .string(".cache/\(artifact).png")),
            ("rgba8888_sha256", .string(Digest.sha256(image.data))),
        ])
    }

    static func renderMeta(cameraWhiteBalance: [Double], whiteBalance: [Double]?, brightness: Double,
                           image: QCamRGBAImage) -> [(String, JSONValue)] {
        [
            ("camera_whitebalance", .array(cameraWhiteBalance.map(JSONValue.double))),
            ("white_balance", whiteBalance.map { .array($0.map(JSONValue.double)) } ?? .null),
            ("brightness", .double(brightness)), ("width", .int(image.width)), ("height", .int(image.height)),
            ("demosaic", .string("VNG")), ("output_color", .string("raw")), ("bits", .int(8)), ("auto_bright", .bool(false)),
        ]
    }

    public static func render(_ document: inout AnalysisDocument, folder: AnalysisFolder) throws -> QCamRGBAImage {
        let rendered = try QCamRawImport.render(url: try folder.verifyOriginal(document))
        let image = rendered.image
        guard image.width * image.height <= maximumPixels else {
            throw DocumentError("CKD Colorimetry supports images up to 50 megapixels.")
        }
        let meta = renderMeta(cameraWhiteBalance: rendered.cameraWhiteBalance, whiteBalance: nil, brightness: 1.0, image: image)
        document.set("render", rasterBlock(meta, artifact: "r\(document.revision)-render", image: image))
        document.setSource(width: image.width, height: image.height)
        for key in ["white_balance", "calibration", "results", "export"] { document.set(key, nil) }
        return image
    }

    public static func whiteBalance(_ document: inout AnalysisDocument, folder: AnalysisFolder,
                                    initial: QCamRGBAImage) throws -> QCamRGBAImage {
        guard let render = document["render"],
              let camera = render["camera_whitebalance"]?.arrayValues?.compactMap(\.doubleValue) else {
            throw DocumentError("Render the RAW image before white balance.")
        }
        let points = try PolygonRules.validate(document.draft.whiteBalance, width: initial.width, height: initial.height)
        let polygon = QCamPolygon(points: points)
        let mean = try initial.rgbMean(for: polygon, sampling: .boundaryInclusivePolygon)
        try checkPatch(mean)
        guard sqrt(camera.reduce(0) { $0 + $1 * $1 } / Double(camera.count)) > 0 else {
            throw DocumentError("Camera white-balance metadata is invalid.")
        }
        var firstPassChecked = true
        let balanced = try QCamWhiteBalancePipeline.render(
            url: try folder.verifyOriginal(document), initialMean: mean, cameraWhiteBalance: camera, polygon: polygon,
            afterFirstPass: { image in
                if let firstMean = try? image.rgbMean(for: polygon, sampling: .boundaryInclusivePolygon) {
                    firstPassChecked = (try? checkPatch(firstMean)) != nil
                }
            }
        )
        guard firstPassChecked else {
            throw DocumentError("White-balance patch is black or invalid. Select a neutral illuminated area.")
        }
        let image = balanced.image
        let meta = renderMeta(cameraWhiteBalance: camera, whiteBalance: balanced.explicitWhiteBalance,
                              brightness: balanced.brightness, image: image) + [
            ("first_pass_white_balance", .array(balanced.firstPassWhiteBalance.map(JSONValue.double))),
            ("first_pass_mean_rgb", .array([balanced.firstPassMean.red, balanced.firstPassMean.green, balanced.firstPassMean.blue]
                .map(JSONValue.double))),
        ]
        document.set("white_balance", rasterBlock(meta, artifact: "r\(document.revision)-white_balance", image: image))
        for key in ["calibration", "results", "export"] { document.set(key, nil) }
        return image
    }

    private static func checkPatch(_ mean: QCamRGBMean) throws {
        let values = [mean.red, mean.green, mean.blue]
        guard values.min()! > 0, values.allSatisfy(\.isFinite) else {
            throw DocumentError("White-balance patch is black or invalid. Select a neutral illuminated area.")
        }
    }

    public static func calibrate(_ document: inout AnalysisDocument, image: QCamRGBAImage) throws {
        document.set("calibration", try MacCalibration.calibrate(image: image, draft: document.draft))
        document.set("results", nil)
        document.set("export", nil)
    }

    public static func analyze(_ document: inout AnalysisDocument, image: QCamRGBAImage) throws {
        guard let calibration = document.calibrationSummary, calibration.coefficients != nil else {
            throw DocumentError("Calibrate before analysis.")
        }
        let rois = try document.draft.rois.map { roi -> ROIMeasurement in
            let stats = try labStats(image, roi.points)
            return ROIMeasurement(id: roi.id, label: roi.label, median: stats.median, mean: stats.mean,
                                  standardDeviation: stats.standardDeviation, pixelCount: stats.pixelCount,
                                  calibratedMedian: calibration.apply(stats.median)!, calibratedMean: calibration.apply(stats.mean)!)
        }
        let results = CKDConcentrations.compute(draft: document.draft.resultsDraft, rois: rois, calibration: calibration)
        let ranges: JSONValue = .object(CKDEquations.analytes.map { name in
            let range = CKDEquations.ranges[name]!
            return (name, .array([.double(range.minimum), .double(range.maximum)]))
        })
        document.set("results", .object([("schema_name", .string("ckd_results")), ("schema_version", .int(1))]
            + (results.json.objectPairs ?? []) + [
                ("versions", CKDVersions.current), ("calculated_at", .string(Clock.now())), ("review_ranges", ranges),
                ("scientific_status", .string("research_configuration_pending_validation")),
            ]))
        document.set("export", nil)
    }

    public static func refreshResults(_ document: inout AnalysisDocument) {
        guard var results = document["results"] else { return }
        let refreshed = CKDConcentrations.compute(draft: document.draft.resultsDraft, rois: document.roiMeasurements,
                                                  calibration: document.calibrationSummary)
        for (key, value) in refreshed.json.objectPairs ?? [] where key != "rois" {
            results = results.setting(key, value)
        }
        document.set("results", results)
    }

    public static func apply(_ incoming: Draft, to document: inout AnalysisDocument, imported: Bool = false,
                             history: (() -> [AnalysisDocument])? = nil) throws {
        var draft = incoming
        try draft.normalize()
        try validateGeometry(draft, document)
        let requested = draft
        let old = document.draft
        let whiteBalanceChanged = imported || old.whiteBalance != draft.whiteBalance
        let calibrationChanged = whiteBalanceChanged || old.mode != draft.mode || old.corners != draft.corners
            || old.manualPatches != draft.manualPatches
        let geometryChanged = calibrationChanged || old.rois != draft.rois || assignments(old) != assignments(draft)
        if geometryChanged, !imported, let history,
           let restored = history().first(where: { $0.draft.json == requested.json && $0.sourceSHA256 == document.sourceSHA256 }) {
            for key in ["render", "white_balance", "calibration", "results"] { document.set(key, restored[key]) }
            document.set("export", nil)
            try document.replaceDraft(requested)
            return
        }
        let previousReviews = Dictionary(old.reservoirs.map { ($0.id, $0.review) }, uniquingKeysWith: { _, last in last })
        let ureaInputsChanged = old.ureaPHModel != draft.ureaPHModel || old.ureaCalibration != draft.ureaCalibration
        if geometryChanged {
            for index in draft.reservoirs.indices {
                draft.reservoirs[index].review = "needs_review"
                draft.reservoirs[index].reason = ""
            }
        } else if ureaInputsChanged || draft.reservoirs.contains(where: { $0.analyte == "ph" && $0.review != previousReviews[$0.id] }) {
            for index in draft.reservoirs.indices where draft.reservoirs[index].analyte == "urea" {
                draft.reservoirs[index].review = "needs_review"
                draft.reservoirs[index].reason = ""
            }
        }
        let resultInputsChanged = ureaInputsChanged || old.age != draft.age || old.sex != draft.sex
            || old.classifierModel != draft.classifierModel || !sameReservoirs(old.reservoirs, draft.reservoirs)
        if whiteBalanceChanged { document.set("white_balance", nil) }
        if calibrationChanged { document.set("calibration", nil) }
        if geometryChanged {
            document.set("results", nil)
        } else if document["results"] != nil && resultInputsChanged {
            if document.resultsAffectedByVersion {
                throw DocumentError("These results were calculated with a different version. Open Differences and recompute before changing reviews.")
            }
            try document.replaceDraft(draft)
            refreshResults(&document)
        }
        if imported || old.json != draft.json { document.set("export", nil) }
        try document.replaceDraft(draft)
    }

    static func validateGeometry(_ draft: Draft, _ document: AnalysisDocument) throws {
        guard let width = document.width, let height = document.height else {
            throw DocumentError("Render the RAW image before editing geometry.")
        }
        var polygons = draft.rois.map { ($0.label, $0.points) }
        polygons += draft.manualPatches.enumerated().map { ("Calibration patch \($0.offset + 1)", $0.element) }
        if !draft.whiteBalance.isEmpty { polygons.append(("White-balance area", draft.whiteBalance)) }
        if !draft.corners.isEmpty {
            let ordered = try MacCalibration.orderCorners(draft.corners)
            polygons.append(("Marker corners", [ordered[0], ordered[1], ordered[3], ordered[2]]))
        }
        for (label, points) in polygons {
            do {
                _ = try PolygonRules.validate(points, width: width, height: height)
            } catch let error as DocumentError {
                throw DocumentError("\(label): \(error.message)")
            }
        }
    }

    private static func assignments(_ draft: Draft) -> [Int: String] {
        var result: [Int: String] = [:]
        for reservoir in draft.reservoirs where reservoir.analyte != nil || !reservoir.roiIDs.isEmpty {
            result[reservoir.id] = "\(reservoir.analyte ?? "")|\(reservoir.roiIDs)"
        }
        return result
    }

    private static func sameReservoirs(_ a: [ReservoirDraft], _ b: [ReservoirDraft]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in
            x.id == y.id && x.analyte == y.analyte && x.customName == y.customName && x.condition == y.condition
                && x.replicate == y.replicate && x.roiIDs == y.roiIDs && x.review == y.review && x.reason == y.reason
        }
    }
}

public struct RecomputeImages: Sendable {
    public let initial: QCamRGBAImage?
    public let balanced: QCamRGBAImage?
}

public extension AnalysisPipeline {
    static func recompute(_ document: inout AnalysisDocument, folder: AnalysisFolder) throws -> RecomputeImages {
        guard let previous = document["results"] else { throw DocumentError("Analyze before recomputing.") }
        let comparison = CKDVersions.compare(previous["versions"])
        var images = RecomputeImages(initial: nil, balanced: nil)
        if comparison.needsRemeasure {
            let hadBalance = document["white_balance"] != nil
            let initial = try render(&document, folder: folder)
            let balanced = hadBalance ? try whiteBalance(&document, folder: folder, initial: initial) : initial
            try calibrate(&document, image: balanced)
            try analyze(&document, image: balanced)
            images = RecomputeImages(initial: initial, balanced: hadBalance ? balanced : nil)
        } else {
            refreshResults(&document)
            if var results = document["results"] {
                results = results.setting("versions", CKDVersions.current).setting("calculated_at", .string(Clock.now()))
                document.set("results", results)
            }
        }
        if try resetChangedReviews(&document, previous: previous) {
            refreshResults(&document)
        }
        document.set("export", nil)
        return images
    }

    static func sameValue(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a == b || abs(a - b) <= max(1e-9 * max(abs(a), abs(b)), 1e-12)
    }

    private static func resetChangedReviews(_ document: inout AnalysisDocument, previous: JSONValue) throws -> Bool {
        var before: [Int: (Double?, String)] = [:]
        for reservoir in previous["reservoirs"]?.arrayValues ?? [] {
            if let id = reservoir["id"]?.intValue {
                before[id] = (reservoir["value"]?.doubleValue, reservoir["calculation_status"]?.stringValue ?? "")
            }
        }
        var draft = document.draft
        var changed = false
        for reservoir in document["results"]?["reservoirs"]?.arrayValues ?? [] {
            guard let id = reservoir["id"]?.intValue, let old = before[id] else { continue }
            let same = sameValue(old.0, reservoir["value"]?.doubleValue) && old.1 == reservoir["calculation_status"]?.stringValue
            if !same, let index = draft.reservoirs.firstIndex(where: { $0.id == id }), draft.reservoirs[index].review != "needs_review" {
                draft.reservoirs[index].review = "needs_review"
                draft.reservoirs[index].reason = ""
                changed = true
            }
        }
        if changed { try document.replaceDraft(draft) }
        return changed
    }
}
