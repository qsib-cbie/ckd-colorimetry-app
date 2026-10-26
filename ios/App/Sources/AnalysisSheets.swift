import CKDDocument
import CKDResults
import SwiftUI

struct DifferencesView: View {
    @Bindable var model: AnalysisModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let differences = model.document.differences {
                    content(differences)
                } else {
                    ContentUnavailableView("No results", systemImage: "chart.bar", description: Text("Analyze before comparing results."))
                }
            }
            .navigationTitle("Differences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Recompute") {
                        dismiss()
                        Task { await model.run(.recompute) }
                    }
                    .disabled(model.busy || model.document["results"] == nil)
                    .accessibilityIdentifier("differences.recompute")
                }
            }
        }
    }

    private func content(_ differences: ResultsDifferences) -> some View {
        List {
            Section {
                Text(summary(differences.comparison)).accessibilityIdentifier("differences.summary")
            }
            Section("Versions") {
                ForEach(differences.versions) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label).fontWeight(row.differs ? .semibold : .regular)
                        HStack {
                            Text("Saved: \(row.saved ?? "Not recorded")")
                            Spacer()
                            Text("This app: \(row.current)")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .listRowBackground(row.differs ? Color.orange.opacity(0.14) : nil)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("differences.version.\(row.key)")
                }
            }
            Section("Values") {
                ForEach(differences.values) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(label(row.kind))
                            Spacer()
                            Text(status(row)).foregroundStyle(row.changed == true ? .orange : .secondary)
                        }
                        HStack {
                            Text("Saved \(valueText(row.saved, unit: row.unit))")
                            Spacer()
                            Text(differences.comparison.needsRemeasure ? "After recompute" : "Current \(valueText(row.current, unit: row.unit))")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .listRowBackground(row.changed == true ? Color.orange.opacity(0.14) : nil)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("differences.value.\(row.id)")
                }
            }
            Section {
                Text("Recompute keeps the saved numbers in the analysis run history. Reservoirs whose value or status changes go back to “needs review”; other review decisions are kept.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ comparison: VersionComparison) -> String {
        let place = comparison.calculatedOn == "mac" ? "on a Mac " : "on iPad or iPhone "
        let start = "These results were calculated \(place)with CKD \(comparison.calculatedWith). This app is CKD \(CKDVersions.app). "
        if comparison.needsRemeasure {
            return start + "The image processing changed, so Recompute renders the original RAW again, re-applies white balance and calibration, and measures every ROI. New values appear after recomputing."
        }
        if comparison.affectsValues {
            return start + "The equations changed. The current values below are calculated from the stored color measurements."
        }
        return start + "Nothing that affects the numbers changed. Recompute records this app version."
    }

    private func label(_ kind: ResultsDifferences.ValueRow.Kind) -> String {
        switch kind {
        case .reservoir(let id, let analyte): return "Reservoir \(id) · \(AnalyteName.label(analyte.isEmpty ? nil : analyte))"
        case .summary(let analyte): return "Final \(AnalyteName.label(analyte))"
        case .prediction: return "CKD prediction"
        }
    }

    private func valueText(_ value: Double?, unit: String) -> String {
        guard let value else { return "Not available" }
        return unit == "probability" ? String(format: "%.4f", value) : String(format: "%.3f", value) + " " + AnalyteName.unit(unit)
    }

    private func status(_ row: ResultsDifferences.ValueRow) -> String {
        guard let changed = row.changed else { return "Unknown until recomputed" }
        guard changed else { return "Unchanged" }
        if let current = row.currentStatus, current != row.savedStatus {
            return "Changed (\(row.savedStatus ?? "none") to \(current))"
        }
        return "Changed"
    }
}

struct RunHistoryView: View {
    let model: AnalysisModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let runs = model.runSnapshots()
            List {
                if runs.isEmpty {
                    Text("No runs yet.").foregroundStyle(.secondary)
                }
                ForEach(runs) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.imported ? "Imported results" : "Run at revision \(run.revision.map(String.init) ?? "?")")
                        Text(dateText(run.createdAt)).font(.caption)
                        Text(versionsText(run.versions)).font(.caption).foregroundStyle(.secondary)
                        if run.keepsPreviousResults {
                            Text("Keeps the results it replaced").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("runs.row")
                }
                Section {
                    Text("Each Analyze and Recompute keeps its results, tables and coordinates in the runs folder of this analysis, in the same format as the Mac.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Run history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
    }

    private func dateText(_ value: String?) -> String {
        guard let value else { return "Date not recorded" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let trimmed = value.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        guard let date = formatter.date(from: trimmed) else { return value }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    private func versionsText(_ versions: JSONValue?) -> String {
        let place = versions?["platform"]?.stringValue == "ios" ? "iPad or iPhone" : "Mac"
        let app = versions?["app"]?.stringValue ?? "unknown version"
        let configuration = versions?["configuration"]?.stringValue.map { " · \($0)" } ?? ""
        return "CKD \(app) on \(place)\(configuration)"
    }
}
