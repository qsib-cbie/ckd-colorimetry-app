import CKDDocument
import CKDImage
import CKDResults
import SwiftUI

struct StepPanel: View {
    @Bindable var model: AnalysisModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                switch model.step {
                case .image: imagePanel
                case .whiteBalance: whiteBalancePanel
                case .calibration: calibrationPanel
                case .reservoirs: ReservoirPanel(model: model)
                case .results: ResultsPanel(model: model)
                }
            }
            .id(model.step)
            .disabled(model.busy)
            if let primary = model.primaryAction {
                Divider()
                VStack(spacing: 4) {
                    Button {
                        Task { await model.run(primary.action) }
                    } label: {
                        Label(primary.title, systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!primary.enabled || model.busy)
                    .accessibilityIdentifier("action.\(primary.action.rawValue)")
                    if let hint = primary.hint {
                        Text(hint).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(.bar)
            }
        }
    }

    @ViewBuilder
    private var imagePanel: some View {
        Section("Original") {
            LabeledContent("File", value: model.document.sourceFilename)
            if let width = model.document.width, let height = model.document.height {
                LabeledContent("Size", value: "\(width) × \(height) px (\(String(format: "%.1f", Double(width * height) / 1e6)) MP)")
            }
        }
        Section {
            Text("LibRaw: VNG demosaic, camera white balance, raw color, 8-bit, full resolution.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var whiteBalancePanel: some View {
        Section {
            if !model.draft.whiteBalance.isEmpty {
                Button("Clear area", role: .destructive) { model.setWhiteBalance([]) }
            }
        } header: {
            Text("Neutral area")
        } footer: {
            Text("Use Rectangle or Polygon on the image to draw over a neutral, evenly lit area. Redrawing it deletes the marker, patches and ROIs drawn after it.")
        }
        if let balance = model.document["white_balance"] {
            Section("Applied") {
                LabeledContent("Multipliers", value: (balance["white_balance"]?.arrayValues ?? []).prefix(3)
                    .compactMap(\.doubleValue).map { String(format: "%.4f", $0) }.joined(separator: ", "))
                LabeledContent("Brightness", value: String(format: "%.4f", balance["brightness"]?.doubleValue ?? 0))
            }
        }
    }

    @ViewBuilder
    private var calibrationPanel: some View {
        let manual = model.draft.mode == "flower_9_manual"
        Section("Marker") {
            Picker("Marker", selection: Binding(get: { model.draft.mode }, set: { model.changeMode($0) })) {
                Text("Flower 9 · manual patches").tag("flower_9_manual")
                if model.draft.mode == "flower_9" {
                    Text("Flower 9 · marker corners").tag("flower_9")
                }
                Text("Standard 24 · legacy 24-patch").tag("standard_24_grid")
            }
            .accessibilityIdentifier("calibration.mode")
        }
        if manual {
            Section {
                LabeledContent("Patches", value: "\(model.draft.manualPatches.count) of 9")
                if !model.draft.manualPatches.isEmpty {
                    Button("Remove last patch", role: .destructive) { model.removeLastPatch() }
                }
            } footer: {
                Text("Draw all nine patches. The order does not matter; the center and ring order are found automatically.")
            }
        } else {
            Section {
                if !model.draft.corners.isEmpty {
                    Button("Clear marker boundary", role: .destructive) { model.setCorners([]) }
                }
            } footer: {
                Text("Use Rectangle to drag around all the patches, then select the marker and drag its corners until the dashed patch outlines sit on the colors. Corners places the four corners one by one.")
            }
        }
        if let calibration = model.document["calibration"] {
            Section("Calibration") {
                LabeledContent("RMSE", value: String(format: "%.3f", calibration["rmse"]?.doubleValue ?? 0))
                LabeledContent("Orientation", value: calibration["orientation"]?.stringValue ?? "")
                if let confidence = calibration["confidence"]?.doubleValue {
                    LabeledContent("Next best fit", value: String(format: "+%.3f RMSE", confidence))
                }
            }
        }
    }
}

struct ReservoirPanel: View {
    @Bindable var model: AnalysisModel
    @State private var confirmRemoval: ReservoirDraft?

    var body: some View {
        let reservoirs = model.draft.reservoirs
        Group {
        Section {
            Picker("Reservoir", selection: Binding(get: { model.activeReservoirID ?? 0 }, set: { model.activeReservoirID = $0 })) {
                ForEach(reservoirs, id: \.id) { r in
                    Text("Reservoir \(r.id) · \(AnalyteName.label(r.analyte)) · \(r.roiIDs.count) ROI\(r.roiIDs.count == 1 ? "" : "s")").tag(r.id)
                }
            }
            .accessibilityIdentifier("reservoir.picker")
            HStack {
                Button("Add reservoir", systemImage: "plus") { model.addReservoir() }
                    .disabled(reservoirs.count >= Draft.maximumReservoirs)
                Spacer()
                if let active = model.activeReservoir {
                    Button(model.clearsLastReservoir ? "Clear" : "Remove", systemImage: "trash", role: .destructive) {
                        if active.analyte != nil || !active.roiIDs.isEmpty { confirmRemoval = active } else { model.removeReservoir(active.id) }
                    }
                    .disabled(model.clearsLastReservoir && active.analyte == nil && active.roiIDs.isEmpty
                              && active.condition.isEmpty && active.replicate.isEmpty)
                }
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Reservoirs")
        }
        if let active = model.activeReservoir {
            Section("Reservoir \(active.id)") {
                Picker("Analyte", selection: Binding(get: { active.analyte ?? "" }, set: { model.assignAnalyte($0.isEmpty ? nil : $0, to: active.id) })) {
                    Text("None").tag("")
                    Text("pH").tag("ph")
                    Text("Urea").tag("urea")
                    Text("Creatinine").tag("creatinine")
                    Text("Custom…").tag("custom")
                }
                .accessibilityIdentifier("reservoir.analyte")
                CommitField(title: "Custom biomarker", value: active.customName, identifier: "reservoir.customName") { text in
                    model.updateReservoir(active.id) { reservoir in
                        reservoir.customName = String(text.prefix(80))
                        if !text.trimmingCharacters(in: .whitespaces).isEmpty { reservoir.analyte = "custom" }
                    }
                }
                CommitField(title: "Notes", value: active.condition, identifier: "reservoir.condition") { text in
                    model.updateReservoir(active.id) { $0.condition = String(text.prefix(80)) }
                }
                if !active.replicate.isEmpty {
                    CommitField(title: "Replicate", value: active.replicate, identifier: "reservoir.replicate") { text in
                        model.updateReservoir(active.id) { $0.replicate = String(text.prefix(40)) }
                    }
                }
            }
            .id(active.id)
            Section {
                ForEach(model.draft.rois.filter { active.roiIDs.contains($0.id) }, id: \.id) { roi in
                    HStack {
                        Text(roi.label)
                        Spacer()
                        Button(role: .destructive) { model.removeROI(roi.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(roi.label)")
                    }
                }
            } header: {
                Text("ROIs in reservoir \(active.id)")
            } footer: {
                Text("\(model.draft.rois.count) ROIs in this analysis; \(unassigned) not assigned to a reservoir.")
            }
        }
        }
        .confirmationDialog("\(model.clearsLastReservoir ? "Clear" : "Remove") reservoir \(confirmRemoval?.id ?? 0)?",
                            isPresented: Binding(get: { confirmRemoval != nil }, set: { if !$0 { confirmRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("\(model.clearsLastReservoir ? "Clear" : "Remove") reservoir", role: .destructive) {
                if let confirmRemoval { model.removeReservoir(confirmRemoval.id) }
            }
        } message: {
            let count = confirmRemoval?.roiIDs.count ?? 0
            Text("\(count == 0 ? "Its" : count == 1 ? "Its ROI is deleted and its" : "Its \(count) ROIs are deleted and its") analyte is unassigned. You can undo it afterwards.")
        }
    }

    private var unassigned: Int {
        let assigned = Set(model.draft.reservoirs.flatMap(\.roiIDs))
        return model.draft.rois.filter { !assigned.contains($0.id) }.count
    }
}

struct CommitField: View {
    let title: String
    let value: String
    let identifier: String
    var keyboard: UIKeyboardType = .default
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            TextField("Optional", text: $text)
                .accessibilityLabel(title)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .focused($focused)
                .onSubmit { focused = false }
                .onAppear { text = value }
                .onDisappear { if text != value { commit(text) } }
                .onChange(of: value) { _, saved in if !focused { text = saved } }
                .onChange(of: focused) { _, editing in
                    if !editing && text != value { commit(text) }
                }
                .toolbar {
                    if focused {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { focused = false }
                        }
                    }
                }
                .accessibilityIdentifier(identifier)
        }
    }
}
