import CKDDocument
import CKDImage
import CKDResults
import CoreGraphics
import os
import SwiftUI
import UIKit

enum Step: Int, CaseIterable, Identifiable {
    case image, whiteBalance, calibration, reservoirs, results

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .image: return "Image"
        case .whiteBalance: return "White balance"
        case .calibration: return "Calibration"
        case .reservoirs: return "Reservoirs"
        case .results: return "Results"
        }
    }
}

enum JobAction: String {
    case render, whiteBalance, calibrate, analyze, recompute, export

    var label: String {
        switch self {
        case .render: return "Rendering the RAW image"
        case .whiteBalance: return "Applying white balance"
        case .calibrate: return "Calibrating"
        case .analyze: return "Measuring ROIs"
        case .recompute: return "Recomputing with this version"
        case .export: return "Building the export ZIP"
        }
    }
}

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

enum Travel {
    case undo, redo
}

struct PendingEdit: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let document: AnalysisDocument
    var travel: Travel?
    var step: Step?
}

struct PrimaryAction {
    let title: String
    let action: JobAction
    let enabled: Bool
    let hint: String?
}

@MainActor
@Observable
final class AnalysisModel {
    let folder: AnalysisFolder
    let rasters: RasterStore
    private(set) var document: AnalysisDocument
    private(set) var preview: CGImage?
    private(set) var working: QCamRGBAImage?
    private(set) var workingIsBalanced = false
    var step: Step
    private(set) var job: JobAction?
    var error: String?
    var notice: String?
    var pendingEdit: PendingEdit?
    var shared: SharedFile?
    var activeReservoirID: Int?
    var tool: DrawingTool = .none
    var sketch: [QCamPoint] = []
    var selectedShape: String?
    var showingDifferences = false
    var showingRuns = false
    private(set) var rasterMismatch = false
    private(set) var past: [Draft] = []
    private(set) var future: [Draft] = []
    private var loadedArray: String?
    static let undoLimit = 50
    static let keepsScreenAwake = ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("CKD_UI_TEST_") }

    init(url: URL, rasters: RasterStore) throws {
        let folder = AnalysisFolder(url: url)
        let loaded = try folder.load()
        self.folder = folder
        self.rasters = rasters
        document = loaded
        step = loaded["results"] != nil ? .results : loaded["calibration"] != nil ? .reservoirs
            : loaded["white_balance"] != nil ? .calibration : loaded["render"] != nil ? .whiteBalance : .image
        activeReservoirID = loaded.draft.reservoirs.first?.id
    }

    var draft: Draft { document.draft }
    var hasRender: Bool { document["render"] != nil }
    var busy: Bool { job != nil }
    var imageSize: CGSize { CGSize(width: document.width ?? 1, height: document.height ?? 1) }

    var results: ConcentrationResults? {
        document["results"].map { ConcentrationResults(stored: $0) }
    }

    var activeReservoir: ReservoirDraft? {
        draft.reservoirs.first { $0.id == activeReservoirID }
    }

    var reviewsLocked: Bool { document.resultsAffectedByVersion }
    var canUndo: Bool { !busy && (tool.isDrawing ? !sketch.isEmpty : !past.isEmpty) }
    var canRedo: Bool { !busy && !tool.isDrawing && !future.isEmpty }
    private var displayedBlock: String { document["white_balance"] != nil ? "white_balance" : "render" }

    var primaryAction: PrimaryAction? {
        switch step {
        case .image:
            return PrimaryAction(title: hasRender ? "Render again" : "Render RAW", action: .render, enabled: true, hint: nil)
        case .whiteBalance:
            return PrimaryAction(title: "Apply white balance", action: .whiteBalance, enabled: hasRender && draft.whiteBalance.count >= 3,
                                 hint: draft.whiteBalance.isEmpty ? "Draw a neutral area first." : nil)
        case .calibration:
            let ready = draft.mode == "flower_9_manual" ? draft.manualPatches.count == 9 : draft.corners.count == 4
            return PrimaryAction(title: "Calibrate", action: .calibrate, enabled: hasRender && ready,
                                 hint: ready ? nil : "Place the marker first.")
        case .reservoirs:
            let calibrated = document["calibration"] != nil
            return PrimaryAction(title: "Analyze", action: .analyze, enabled: calibrated && !draft.rois.isEmpty,
                                 hint: calibrated ? (draft.rois.isEmpty ? "Draw at least one ROI." : nil) : "Calibrate before analysis.")
        case .results:
            return nil
        }
    }

    var availableTools: [DrawingTool] {
        guard preview != nil, !busy, tool == .none else { return [] }
        switch step {
        case .whiteBalance:
            return [.rectangle, .polygon]
        case .calibration:
            if draft.mode == "flower_9_manual" {
                return draft.manualPatches.count < 9 ? [.rectangle, .polygon] : []
            }
            return [.rectangle, .corners]
        case .reservoirs:
            return activeReservoir == nil || draft.rois.count >= Draft.maximumROIs ? [] : [.rectangle, .polygon]
        default:
            return []
        }
    }

    func runPrimary() async {
        guard let primary = primaryAction, primary.enabled, tool == .none else { return }
        await run(primary.action)
    }

    func start(_ kind: DrawingTool) {
        guard availableTools.contains(kind) else { return }
        tool = kind
        selectedShape = nil
    }

    var keepsDrawing: Bool {
        switch step {
        case .calibration: return draft.mode == "flower_9_manual" && draft.manualPatches.count < 9
        case .reservoirs: return activeReservoir != nil && draft.rois.count < Draft.maximumROIs
        default: return false
        }
    }

    func loadImage() async {
        guard hasRender, working == nil else { return }
        let document = self.document, folder = self.folder, rasters = self.rasters
        do {
            let raster = try await Task.detached(priority: .userInitiated) {
                try rasters.image(document, folder: folder, balanced: true)
            }.value
            let block = document["white_balance"] != nil ? "white_balance" : "render"
            install(rasters.cached(document, block: block) ?? raster.image, block: block, array: document[block]?["array"]?.stringValue)
            rasterMismatch = !raster.matchesSavedHash
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func install(_ image: QCamRGBAImage, block: String, array: String?) {
        working = image
        workingIsBalanced = block == "white_balance"
        loadedArray = array
        preview = PreviewRenderer.make(image, longSide: 4096)
    }

    private func refreshImageIfNeeded() {
        guard hasRender, document[displayedBlock]?["array"]?.stringValue != loadedArray else { return }
        working = nil
        loadedArray = nil
        Task { await loadImage() }
    }

    static func availableMemory() -> Int {
        if let value = ProcessInfo.processInfo.environment["CKD_UI_TEST_AVAILABLE_MEMORY_MB"], let megabytes = Int(value) {
            return megabytes * 1_048_576
        }
        return Int(os_proc_available_memory())
    }

    private func memoryShortfall(for action: JobAction) -> String? {
        let holdsImage: Bool
        switch action {
        case .render, .whiteBalance:
            holdsImage = false
        case .recompute:
            guard document.versionComparison?.needsRemeasure == true else { return nil }
            holdsImage = true
        default:
            return nil
        }
        guard let original = try? folder.originalURL(document),
              let needed = try? MemoryBudget.required(for: original, holdsImage: holdsImage) else { return nil }
        do {
            try MemoryBudget.check(required: needed, available: Self.availableMemory())
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func run(_ action: JobAction) async {
        guard job == nil else { return }
        if let shortfall = memoryShortfall(for: action) {
            error = shortfall
            return
        }
        job = action
        error = nil
        notice = nil
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            job = nil
            UIApplication.shared.isIdleTimerDisabled = Self.keepsScreenAwake
        }
        let document = self.document, folder = self.folder, rasters = self.rasters
        let rendering = [.render, .whiteBalance, .recompute].contains(action)
        if rendering { self.working = nil }
        let working = rendering ? nil : self.working, workingIsBalanced = self.workingIsBalanced
        do {
            let (updated, image) = try await Task.detached(priority: .userInitiated) { () throws -> (AnalysisDocument, QCamRGBAImage?) in
                var updated = document
                func current(balanced: Bool) throws -> QCamRGBAImage {
                    let wanted = balanced && document["white_balance"] != nil
                    if let working, workingIsBalanced == wanted { return working }
                    return try rasters.image(document, folder: folder, balanced: wanted).image
                }
                switch action {
                case .render:
                    let image = try AnalysisPipeline.render(&updated, folder: folder)
                    try rasters.save(image, document: updated, block: "render")
                    return (updated, image)
                case .whiteBalance:
                    let image = try AnalysisPipeline.whiteBalance(&updated, folder: folder, initial: try current(balanced: false))
                    try rasters.save(image, document: updated, block: "white_balance")
                    return (updated, image)
                case .calibrate:
                    try AnalysisPipeline.calibrate(&updated, image: try current(balanced: true))
                    return (updated, nil)
                case .analyze:
                    try AnalysisPipeline.analyze(&updated, image: try current(balanced: true))
                    try RunHistory.record(updated, previous: document["results"], in: folder)
                    return (updated, nil)
                case .recompute:
                    let images = try AnalysisPipeline.recompute(&updated, folder: folder)
                    if let initial = images.initial { try rasters.save(initial, document: updated, block: "render") }
                    if let balanced = images.balanced { try rasters.save(balanced, document: updated, block: "white_balance") }
                    try RunHistory.record(updated, previous: document["results"], in: folder)
                    return (updated, images.balanced ?? images.initial)
                case .export:
                    return (updated, nil)
                }
            }.value
            save(updated)
            if let image {
                let block = displayedBlock
                install(rasters.cached(self.document, block: block) ?? image, block: block, array: self.document[block]?["array"]?.stringValue)
            }
            rasters.prune(self.document)
            switch action {
            case .render: step = .whiteBalance
            case .whiteBalance: step = .calibration
            case .calibrate: step = .reservoirs
            case .analyze, .recompute: step = .results
            case .export: break
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func export(includeDebugImages: Bool) async {
        guard job == nil, document["results"] != nil else { return }
        job = .export
        error = nil
        defer { job = nil }
        let document = self.document, folder = self.folder, rasters = self.rasters
        let working = self.working, workingIsBalanced = self.workingIsBalanced
        do {
            let url = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                let balanced = document["white_balance"] != nil
                let image = working != nil && workingIsBalanced == balanced
                    ? working! : try rasters.image(document, folder: folder, balanced: true).image
                let initial = includeDebugImages ? (balanced ? try rasters.image(document, folder: folder, balanced: false).image : image) : nil
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports")
                try? FileManager.default.removeItem(at: directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(AnalysisFolder.exportFilename(title: document.draft.title))
                try ExportArchive.write(document, folder: folder, image: image, initial: initial, to: url)
                return url
            }.value
            notice = "Export ready: \(url.lastPathComponent)"
            shared = SharedFile(url: url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func exportCoordinates() {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports")
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = AnalysisFolder.exportFilename(title: draft.title).replacingOccurrences(of: ".zip", with: "_coordinates.json")
            let url = directory.appendingPathComponent(name)
            try Data(CoordinatePackage.export(document).prettyJSON().utf8).write(to: url)
            shared = SharedFile(url: url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func runSnapshots() -> [RunHistory.Snapshot] {
        RunHistory.list(folder)
    }

    private func save(_ updated: AnalysisDocument) {
        do {
            document = try folder.save(updated, expectedRevision: document.revision)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func edit(_ change: (inout Draft) -> Void) {
        var next = draft
        change(&next)
        propose(next)
    }

    func propose(_ next: Draft, imported: Bool = false, title: String = "Change this analysis?", travel: Travel? = nil,
                 confirm: String? = nil, then step: Step? = nil) {
        var updated = document
        let folder = self.folder
        do {
            try AnalysisPipeline.apply(next, to: &updated, imported: imported, history: { folder.history() })
        } catch {
            self.error = error.localizedDescription
            return
        }
        let lost = [("white_balance", "white balance"), ("calibration", "calibration"), ("results", "results")]
            .filter { document[$0.0] != nil && updated[$0.0] == nil }.map(\.1)
        if let confirm {
            pendingEdit = PendingEdit(title: title, message: confirm, document: updated, travel: travel, step: step)
            return
        }
        if !lost.isEmpty {
            let list = lost.count == 1 ? lost[0] : lost.dropLast().joined(separator: ", ") + " and " + lost.last!
            pendingEdit = PendingEdit(title: title, message: "This clears the \(list). You can undo it afterwards.",
                                      document: updated, travel: travel, step: step)
            return
        }
        commit(updated, travel: travel)
        if let step { self.step = step }
    }

    func commit(_ updated: AnalysisDocument, travel: Travel? = nil) {
        let previous = draft, revision = document.revision
        let restored = [("white_balance", "white balance"), ("calibration", "calibration"), ("results", "results")]
            .filter { document[$0.0] == nil && updated[$0.0] != nil }.map(\.1)
        save(updated)
        guard document.revision != revision else { return }
        if previous.json != draft.json {
            switch travel {
            case .undo:
                past.removeLast()
                future.append(previous)
            case .redo:
                future.removeLast()
                past.append(previous)
            case nil:
                past.append(previous)
                if past.count > Self.undoLimit { past.removeFirst() }
                future.removeAll()
            }
        }
        if !restored.isEmpty {
            notice = "Restored the saved \(restored.joined(separator: ", ")) for this version."
        }
        if activeReservoir == nil { activeReservoirID = draft.reservoirs.first?.id }
        if let selectedShape, !canvasShapes.contains(where: { $0.id == selectedShape && $0.editable }) { self.selectedShape = nil }
        refreshImageIfNeeded()
    }

    func undo() {
        if tool.isDrawing {
            if !sketch.isEmpty { sketch.removeLast() }
            return
        }
        guard !busy, let previous = past.last else { return }
        propose(previous, title: "Undo this change?", travel: .undo)
    }

    func redo() {
        guard !busy, !tool.isDrawing, let next = future.last else { return }
        propose(next, title: "Redo this change?", travel: .redo)
    }

    func editShape(_ id: String, points: [QCamPoint]) {
        var next = draft
        if id == "wb" {
            next.whiteBalance = points
        } else if id == "corners" {
            next.corners = points
        } else if id.hasPrefix("patch"), let index = Int(id.dropFirst(5)), next.manualPatches.indices.contains(index) {
            next.manualPatches[index] = points
        } else if id.hasPrefix("roi"), let roi = Int(id.dropFirst(3)), let index = next.rois.firstIndex(where: { $0.id == roi }) {
            next.rois[index].points = points
        } else {
            return
        }
        propose(next, title: "Move this point?")
    }

    var selectedShapeLabel: String? {
        guard let selectedShape, let shape = canvasShapes.first(where: { $0.id == selectedShape }) else { return nil }
        return "\(shape.label ?? shape.id) selected"
    }

    func importCoordinates(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let package = try JSONValue.parse(Data(contentsOf: url))
            let next = try CoordinatePackage.importDraft(package, into: document)
            propose(next, imported: true, title: "Import coordinates?")
            activeReservoirID = draft.reservoirs.first?.id
            step = .whiteBalance
            notice = "Coordinates imported. Apply white balance, then calibrate and analyze."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func addROI(_ points: [QCamPoint]) {
        guard let reservoirID = activeReservoirID else {
            error = "Add a reservoir before drawing ROIs."
            return
        }
        edit { draft in
            let used = Set(draft.rois.map(\.id))
            let id = (1...).first { !used.contains($0) }!
            draft.rois.append(DraftROI(id: id, label: "ROI \(id)", points: points))
            if let index = draft.reservoirs.firstIndex(where: { $0.id == reservoirID }) {
                draft.reservoirs[index].roiIDs.append(id)
            }
        }
    }

    func removeROI(_ id: Int) {
        edit { draft in
            draft.rois.removeAll { $0.id == id }
            for index in draft.reservoirs.indices { draft.reservoirs[index].roiIDs.removeAll { $0 == id } }
        }
    }

    func addReservoir() {
        let used = Set(draft.reservoirs.map(\.id))
        guard let id = (1...Draft.maximumReservoirs).first(where: { !used.contains($0) }) else { return }
        edit { draft in
            draft.reservoirs.append(ReservoirDraft(id: id))
            draft.reservoirs.sort { $0.id < $1.id }
        }
        activeReservoirID = id
    }

    var clearsLastReservoir: Bool { draft.mode != "standard_24_grid" && draft.reservoirs.count <= 1 }

    func removeReservoir(_ id: Int) {
        let keep = clearsLastReservoir
        edit { draft in
            guard let reservoir = draft.reservoirs.first(where: { $0.id == id }) else { return }
            draft.rois.removeAll { reservoir.roiIDs.contains($0.id) }
            if keep {
                draft.reservoirs = draft.reservoirs.map { $0.id == id ? ReservoirDraft(id: id) : $0 }
            } else {
                draft.reservoirs.removeAll { $0.id == id }
            }
        }
        if activeReservoirID == id && !keep { activeReservoirID = draft.reservoirs.first?.id }
    }

    func nextReservoir() {
        let ids = draft.reservoirs.map(\.id)
        guard step == .reservoirs, !ids.isEmpty else { return }
        activeReservoirID = ids[((ids.firstIndex { $0 == activeReservoirID } ?? -1) + 1) % ids.count]
    }

    private static let laterShapesNote = "Reservoirs keep their analytes and notes. You can undo it afterwards."

    private func withoutROIs(_ draft: inout Draft) {
        draft.rois = []
        for index in draft.reservoirs.indices { draft.reservoirs[index].roiIDs = [] }
    }

    func setWhiteBalance(_ points: [QCamPoint]) {
        var next = draft
        let later = !next.corners.isEmpty || !next.manualPatches.isEmpty || !next.rois.isEmpty
        next.whiteBalance = points
        if later {
            next.corners = []
            next.manualPatches = []
            withoutROIs(&next)
        }
        propose(next, title: points.isEmpty ? "Clear the white-balance area?" : "Redraw the white-balance area?",
                confirm: later ? "This also deletes the marker corners, the calibration patches and all ROIs, and clears "
                    + "white balance, calibration and results. \(Self.laterShapesNote)" : nil)
    }

    func setCorners(_ points: [QCamPoint]) {
        var next = draft
        let later = !next.rois.isEmpty
        next.corners = points
        if later { withoutROIs(&next) }
        propose(next, title: points.isEmpty ? "Clear the marker boundary?" : "Redraw the marker boundary?",
                confirm: later ? "This also deletes all ROIs and clears the calibration and results. \(Self.laterShapesNote)" : nil)
        if points.count == 4 { selectedShape = "corners" }
    }

    func removeLastPatch() {
        var next = draft
        guard !next.manualPatches.isEmpty else { return }
        next.manualPatches.removeLast()
        let later = !next.rois.isEmpty
        if later { withoutROIs(&next) }
        propose(next, title: "Remove the last patch?",
                confirm: later ? "This also deletes all ROIs and clears the calibration and results. \(Self.laterShapesNote)" : nil)
    }

    func changeMode(_ mode: String) {
        guard mode != draft.mode else { return }
        var next = draft
        let existing = !next.corners.isEmpty || !next.manualPatches.isEmpty || !next.rois.isEmpty
            || next.reservoirs.contains { $0.analyte != nil }
        next.mode = mode
        next.corners = []
        next.manualPatches = []
        next.rois = []
        next.reservoirs = (1...6).map { ReservoirDraft(id: $0) }
        propose(next, title: "Change the marker type?",
                confirm: existing ? "This deletes the marker corners, calibration patches, all ROIs and reservoir assignments, "
                    + "and clears the calibration and results. You can undo it afterwards." : nil)
        activeReservoirID = draft.reservoirs.first?.id
    }

    func resetAnalysis() {
        propose(Draft.newAnalysis(title: draft.title), title: "Reset this analysis?",
                confirm: "This deletes the white-balance area, marker corners, calibration patches, all ROIs, reservoirs and "
                    + "notes, age, sex and model choices, and clears white balance, calibration and results. The original "
                    + "image and the analysis name are kept. Use Undo right away if you change your mind.",
                then: .whiteBalance)
    }

    var isBlank: Bool {
        draft.json == Draft.newAnalysis(title: draft.title).json && document["white_balance"] == nil
            && document["calibration"] == nil && document["results"] == nil
    }

    func updateReservoir(_ id: Int, _ change: (inout ReservoirDraft) -> Void) {
        edit { draft in
            if let index = draft.reservoirs.firstIndex(where: { $0.id == id }) { change(&draft.reservoirs[index]) }
        }
    }

    func assignAnalyte(_ analyte: String?, to id: Int) {
        updateReservoir(id) { $0.analyte = analyte }
    }

    var canvasShapes: [CanvasShape] {
        var shapes: [CanvasShape] = []
        if !draft.whiteBalance.isEmpty {
            shapes.append(CanvasShape(id: "wb", points: draft.whiteBalance, color: .blue, label: "WB", emphasized: step == .whiteBalance,
                                      editable: !busy && step == .whiteBalance))
        }
        if draft.mode == "flower_9_manual" {
            for (index, patch) in draft.manualPatches.enumerated() {
                shapes.append(CanvasShape(id: "patch\(index)", points: patch, color: .yellow, label: "\(index + 1)",
                                          emphasized: step == .calibration, editable: !busy && step == .calibration))
            }
        } else if !draft.corners.isEmpty {
            shapes.append(CanvasShape(id: "corners", points: draft.corners, color: .yellow, label: "Marker",
                                      emphasized: step == .calibration, editable: !busy && step == .calibration && draft.corners.count == 4,
                                      closed: draft.corners.count == 4, ordered: false,
                                      guides: draft.corners.count == 4 ? draft.mode : nil))
        }
        let active = Set(activeReservoir?.roiIDs ?? [])
        for roi in draft.rois {
            shapes.append(CanvasShape(id: "roi\(roi.id)", points: roi.points, color: active.contains(roi.id) ? .pink : .green,
                                      label: roi.label, emphasized: step == .reservoirs && active.contains(roi.id),
                                      editable: !busy && step == .reservoirs))
        }
        return shapes
    }
}

enum AnalyteName {
    static func label(_ analyte: String?) -> String {
        switch analyte {
        case "ph": return "pH"
        case "urea": return "Urea"
        case "creatinine": return "Creatinine"
        case "custom": return "Custom"
        default: return "None"
        }
    }

    static func unit(_ unit: String) -> String {
        unit == "uM" ? "µM" : unit
    }
}

enum PreviewRenderer {
    static func make(_ image: QCamRGBAImage, longSide: Int) -> CGImage? {
        let scale = min(1, Double(longSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let provider = CGDataProvider(data: image.data as CFData),
              let source = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: image.width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: info) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
