import CKDDocument
import CKDResults
import SwiftUI

struct ResultsPanel: View {
    @Bindable var model: AnalysisModel
    @State private var excluding: ReservoirResult?
    @State private var reason = ""

    var body: some View {
        if let results = model.results {
            summaries(results)
            demographics(results)
            prediction(results.prediction)
            Section("Reservoirs") {
                ForEach(results.reservoirs, id: \.id) { reservoir in
                    reservoirRow(reservoir)
                }
            }
            .alert("Exclude reservoir \(excluding?.id ?? 0)?", isPresented: Binding(get: { excluding != nil }, set: { if !$0 { excluding = nil } })) {
                TextField("Reason", text: $reason)
                Button("Cancel", role: .cancel) {}
                Button("Exclude", role: .destructive) {
                    if let excluding { setReview(excluding.id, "excluded", reason: String(reason.prefix(500))) }
                }
            }
        } else {
            Section {
                Text("Analyze the reservoirs to see concentrations and the prediction.").foregroundStyle(.secondary)
            }
        }
    }

    static func number(_ value: Double, digits: Int = 3) -> String {
        String(format: "%.\(digits)f", value)
    }

    private func valueText(_ value: Double?, sd: Double?, unit: String) -> String {
        guard let value else { return "Not available" }
        let spread = sd.map { " ± \(Self.number($0))" } ?? ""
        return "\(Self.number(value))\(spread) \(AnalyteName.unit(unit))"
    }

    @ViewBuilder
    private func summaries(_ results: ConcentrationResults) -> some View {
        Section("Final values") {
            ForEach(results.summaries, id: \.analyte) { summary in
                let unreviewed = results.reservoirs.filter { $0.analyte == summary.analyte && $0.value != nil }
                LabeledContent(AnalyteName.label(summary.analyte)) {
                    VStack(alignment: .trailing) {
                        if summary.value == nil, !unreviewed.isEmpty {
                            let values = unreviewed.compactMap(\.value)
                            Text(valueText(values.reduce(0, +) / Double(values.count), sd: nil, unit: summary.unit))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("result.summary.\(summary.analyte)")
                            Text("Not final · \(values.count == 1 ? "reservoir \(unreviewed[0].id)" : "mean of \(values.count) reservoirs") not included (\(Set(unreviewed.map { reviewLabel($0.reviewStatus).lowercased() }).sorted().joined(separator: ", "))). Not used for urea or the prediction.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        } else {
                            Text(valueText(summary.value, sd: summary.sd, unit: summary.unit))
                                .accessibilityIdentifier("result.summary.\(summary.analyte)")
                        }
                        if !summary.includedIDs.isEmpty {
                            Text("\(summary.includedIDs.count == 1 ? "Reservoir" : "Reservoirs") \(summary.includedIDs.map(String.init).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func demographics(_ results: ConcentrationResults) -> some View {
        Section("Inputs") {
            if model.draft.reservoirs.contains(where: { $0.analyte == "urea" }) {
                Picker("Urea pH model", selection: Binding(get: { model.draft.ureaPHModel ?? "" },
                                                           set: { value in model.edit { $0.ureaPHModel = value.isEmpty ? nil : value } })) {
                    Text(results.ureaPHModel.nearest.map { "Automatic (nearest: pH \($0.dropFirst(3)))" } ?? "Automatic").tag("")
                    Text("pH 6.0").tag("pH_6.0")
                    Text("pH 6.5").tag("pH_6.5")
                    Text("pH 7.0").tag("pH_7.0")
                }
                Picker("Urea calibration", selection: Binding(get: { model.draft.ureaCalibration },
                                                              set: { value in model.edit { $0.ureaCalibration = value } })) {
                    Text(verbatim: "L*a*b* (default)").tag("lab")
                    Text(verbatim: "a*b* only").tag("ab")
                }
            }
            CommitField(title: "Age (years)", value: model.draft.age.map(Self.age) ?? "", identifier: "input.age", keyboard: .decimalPad) { text in
                let value = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
                model.edit { $0.age = value.flatMap { $0 > 0 ? $0 : nil } }
            }
            Picker("Sex", selection: Binding(get: { model.draft.sex ?? "" }, set: { value in model.edit { $0.sex = value.isEmpty ? nil : value } })) {
                Text("Not set").tag("")
                Text("Female").tag("female")
                Text("Male").tag("male")
            }
            .accessibilityIdentifier("input.sex")
            Picker("Prediction model", selection: Binding(get: { model.draft.classifierModel ?? "" },
                                                          set: { value in model.edit { $0.classifierModel = value.isEmpty ? nil : value } })) {
                Text("Automatic").tag("")
                ForEach(["full", "creatinine", "urea"], id: \.self) { Text(CKDEquations.classifierLabels[$0]!).tag($0) }
            }
        }
        .disabled(model.reviewsLocked)
    }

    static func age(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    @ViewBuilder
    private func prediction(_ prediction: Prediction) -> some View {
        Section("Prediction") {
            if prediction.isComplete {
                Text(prediction.classification ?? "").font(.headline).accessibilityIdentifier("result.prediction")
                LabeledContent("Probability", value: Self.number(prediction.probability ?? 0, digits: 4))
                LabeledContent("Threshold", value: Self.number(prediction.threshold ?? 0))
                if let label = prediction.modelLabel {
                    LabeledContent("Model", value: label + (prediction.auc.map { ", AUC \(Self.number($0))" } ?? ""))
                }
            } else {
                Text(prediction.reason ?? "Not calculated.").foregroundStyle(.secondary).accessibilityIdentifier("result.prediction")
            }
        }
    }

    @ViewBuilder
    private func reservoirRow(_ reservoir: ReservoirResult) -> some View {
        let fixed = reservoir.reviewStatus == "not_applicable"
            || ["missing_input", "provisional_input"].contains(reservoir.calculation.calculationStatus)
        let invalid = reservoir.calculation.calculationStatus == "invalid_domain"
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Reservoir \(reservoir.id)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(reservoir.analyte == "custom" ? reservoir.reservoir.customName.isEmpty ? "Custom" : reservoir.reservoir.customName : AnalyteName.label(reservoir.analyte))
                    .font(.title3.bold())
                Spacer()
                Menu(reviewLabel(reservoir.reviewStatus)) {
                    Button(invalid ? "Include anyway" : "Include") { setReview(reservoir.id, "included") }
                    Button("Exclude…") {
                        reason = reservoir.reservoir.reason
                        excluding = reservoir
                    }
                    Button("Needs review") { setReview(reservoir.id, "needs_review") }
                }
                .disabled(fixed || model.reviewsLocked)
                .accessibilityIdentifier("review.\(reservoir.id)")
            }
            if reservoir.analyte == "custom" {
                Text(verbatim: "L*a*b* " + reservoir.averageLab.map { Self.number($0, digits: 2) }.joined(separator: ", "))
            } else {
                let sd: Double? = { if case .standard(let u) = reservoir.uncertainty { return u.sd } else { return nil } }()
                Text(valueText(reservoir.value, sd: sd, unit: reservoir.calculation.unit))
                    .accessibilityIdentifier("result.reservoir.\(reservoir.id)")
            }
            let labels = [reservoir.reservoir.condition, reservoir.reservoir.replicate].filter { !$0.isEmpty }
            if !labels.isEmpty {
                Text(labels.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(reservoir.calculation.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func reviewLabel(_ status: String) -> String {
        switch status {
        case "automatically_included": return "Included automatically"
        case "included": return "Included"
        case "excluded": return "Excluded"
        case "needs_review": return "Needs review"
        case "mathematically_invalid": return "Invalid"
        case "not_applicable": return "Color only"
        default: return status
        }
    }

    private func setReview(_ id: Int, _ review: String, reason: String = "") {
        model.updateReservoir(id) {
            $0.review = review
            $0.reason = review == "excluded" ? reason : ""
        }
    }
}
