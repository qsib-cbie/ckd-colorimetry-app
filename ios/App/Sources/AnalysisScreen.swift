import CKDDocument
import CKDImage
import SwiftUI
import UniformTypeIdentifiers

struct AnalysisScreen: View {
    @Environment(WorkspaceModel.self) private var workspace
    let url: URL
    @State private var model: AnalysisModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model {
                AnalysisContent(model: model)
            } else if let loadError {
                ContentUnavailableView("Cannot open this analysis", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            do {
                let opened = try AnalysisModel(url: url, rasters: workspace.rasters)
                model = opened
                if workspace.pendingRender == url {
                    workspace.pendingRender = nil
                    if !opened.hasRender {
                        await opened.run(.render)
                        return
                    }
                }
                await opened.loadImage()
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

struct AnalysisContent: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Bindable var model: AnalysisModel
    @State private var importingCoordinates = false
    @AppStorage("exportDebugImages") private var exportDebugImages = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Step", selection: $model.step) {
                ForEach(Step.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("steps")
            banners
            GeometryReader { geometry in
                if geometry.size.width >= 900 {
                    HStack(spacing: 0) {
                        canvas
                        Divider()
                        StepPanel(model: model).frame(width: model.step == .results ? 420 : 360)
                    }
                } else {
                    VStack(spacing: 0) {
                        canvas.frame(height: geometry.size.height * (model.step == .results ? 0.4 : 0.58))
                        Divider()
                        StepPanel(model: model)
                    }
                }
            }
        }
        .navigationTitle(model.draft.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                    .disabled(!model.canUndo)
                    .accessibilityIdentifier("analysis.undo")
                Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
                    .disabled(!model.canRedo)
                    .accessibilityIdentifier("analysis.redo")
                Menu {
                    Button("Export ZIP…", systemImage: "square.and.arrow.up") {
                        Task { await model.export(includeDebugImages: exportDebugImages) }
                    }
                    .disabled(model.document["results"] == nil || model.busy)
                    .accessibilityIdentifier("analysis.export")
                    Button("Export coordinates…", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { model.exportCoordinates() }
                        .disabled(!model.hasRender || model.busy)
                        .accessibilityIdentifier("analysis.exportCoordinates")
                    Button("Import coordinates…", systemImage: "square.and.arrow.down") { importingCoordinates = true }
                        .disabled(!model.hasRender || model.busy)
                    Divider()
                    Button("Differences", systemImage: "arrow.left.arrow.right") { model.showingDifferences = true }
                        .disabled(model.document["results"] == nil)
                        .accessibilityIdentifier("analysis.differences")
                    Button("Run history", systemImage: "clock") { model.showingRuns = true }
                        .accessibilityIdentifier("analysis.runs")
                    Divider()
                    Button("Reset analysis…", systemImage: "arrow.counterclockwise", role: .destructive) { model.resetAnalysis() }
                        .disabled(model.busy || model.isBlank)
                        .accessibilityIdentifier("analysis.reset")
                    if let json = ProcessInfo.processInfo.environment["CKD_UI_TEST_COORDINATES"] {
                        Button("Import test coordinates") {
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-coordinates.json")
                            try? Data(json.utf8).write(to: url)
                            model.importCoordinates(from: url)
                        }
                        .accessibilityIdentifier("test.importCoordinates")
                    }
                } label: {
                    Label("Analysis", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("analysis.menu")
            }
        }
        .fileImporter(isPresented: $importingCoordinates, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { model.importCoordinates(from: url) }
        }
        .confirmationDialog(model.pendingEdit?.title ?? "", isPresented: Binding(get: { model.pendingEdit != nil },
                                                                              set: { if !$0 { model.pendingEdit = nil } }),
                            titleVisibility: .visible, presenting: model.pendingEdit) { edit in
            Button("Continue", role: .destructive) {
                model.commit(edit.document, travel: edit.travel)
                if let step = edit.step { model.step = step }
            }
            Button("Cancel", role: .cancel) {}
        } message: { edit in
            Text(edit.message)
        }
        .sheet(item: $model.shared) { file in
            ShareSheet(url: file.url)
        }
        .sheet(isPresented: $model.showingDifferences) {
            DifferencesView(model: model)
        }
        .sheet(isPresented: $model.showingRuns) {
            RunHistoryView(model: model)
        }
        .focusedSceneValue(\.analysisModel, model)
        .onChange(of: model.step) { _, _ in
            model.tool = .none
            model.selectedShape = nil
        }
        .onChange(of: model.document.revision) { _, _ in workspace.refresh() }
    }

    private var canvas: some View {
        ZStack {
            if model.hasRender {
                ImageCanvas(image: model.preview, imageSize: model.imageSize, shapes: model.canvasShapes, tool: $model.tool,
                            points: $model.sketch, selected: $model.selectedShape, selectionLabel: model.selectedShapeLabel,
                            keepDrawing: { model.keepsDrawing }, onComplete: complete, onEdit: model.editShape)
                .overlay(alignment: .topLeading) { canvasTools }
                if model.preview == nil {
                    ProgressView("Preparing image…").tint(.white).foregroundStyle(.white)
                }
            } else {
                ContentUnavailableView("Render the RAW image", systemImage: "photo",
                                       description: Text("The original is rendered at full resolution with LibRaw."))
            }
        }
    }

    @ViewBuilder
    private var canvasTools: some View {
        let tools = model.availableTools
        if !tools.isEmpty {
            HStack(spacing: 8) {
                ForEach(tools, id: \.self) { kind in
                    Button { model.start(kind) } label: { Label(kind.title, systemImage: kind.icon) }
                        .accessibilityIdentifier("tool.\(kind.rawValue)")
                }
            }
            .buttonStyle(.bordered)
            .padding(8)
            .background(.regularMaterial, in: Capsule())
            .padding(10)
        }
    }

    private func complete(_ points: [QCamPoint]) {
        switch model.step {
        case .whiteBalance:
            model.setWhiteBalance(points)
        case .calibration:
            if model.draft.mode == "flower_9_manual" {
                model.edit { $0.manualPatches.append(points) }
            } else {
                model.setCorners(points)
            }
        case .reservoirs:
            model.addROI(points)
        default:
            break
        }
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 6) {
            if let job = model.job {
                Banner(text: "\(job.label)…", systemImage: "hourglass", tint: .blue, progress: true)
            }
            if let error = model.error {
                Banner(text: error, systemImage: "exclamationmark.triangle.fill", tint: .red) { model.error = nil }
            }
            if let notice = model.notice {
                Banner(text: notice, systemImage: "info.circle", tint: .teal) { model.notice = nil }
            }
            if let comparison = model.document.versionComparison, comparison.outdated || comparison.calculatedOn == "mac" {
                Banner(text: versionText(comparison), systemImage: "clock.arrow.circlepath", tint: .orange,
                       action: comparison.outdated ? ("Differences", { model.showingDifferences = true }) : nil)
            }
            if model.rasterMismatch {
                Banner(text: "The image rendered on this device differs from the one saved with this analysis. Values may differ slightly from the saved ones.",
                       systemImage: "exclamationmark.triangle", tint: .orange)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    func versionText(_ comparison: VersionComparison) -> String {
        let place = comparison.calculatedOn == "mac" ? "on a Mac " : ""
        var text = "Calculated \(place)with CKD \(comparison.calculatedWith)."
        if comparison.needsRemeasure {
            text += " The image processing differs, so Recompute renders the original again and re-measures every ROI. Reviews are locked until then."
        } else if comparison.affectsValues {
            text += " The equations differ; Recompute recalculates from the stored measurements. Reviews are locked until then."
        } else if comparison.outdated {
            text += " Nothing that affects the numbers differs; Recompute records this version."
        }
        return text
    }
}

struct Banner: View {
    let text: String
    let systemImage: String
    let tint: Color
    var progress = false
    var action: (title: String, run: () -> Void)?
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if progress { ProgressView() } else { Image(systemName: systemImage).foregroundStyle(tint) }
            Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("banner.text")
            if let action {
                Button(action.title, action: action.run).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("banner.\(action.title.lowercased())")
            }
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
