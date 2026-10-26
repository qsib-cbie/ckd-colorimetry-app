import CKDResults
import Foundation

public struct ResultsDifferences: Sendable {
    public struct VersionRow: Sendable, Identifiable {
        public let key: String
        public let label: String
        public let saved: String?
        public let current: String
        public let differs: Bool

        public var id: String { key }
    }

    public struct ValueRow: Sendable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case reservoir(Int, String)
            case summary(String)
            case prediction
        }

        public let id: Int
        public let kind: Kind
        public let unit: String
        public let saved: Double?
        public let savedStatus: String?
        public let current: Double?
        public let currentStatus: String?
        public let changed: Bool?
    }

    public let comparison: VersionComparison
    public let versions: [VersionRow]
    public let values: [ValueRow]
}

extension CKDVersions {
    public static let labels = [
        "app": "CKD Colorimetry app", "engine": "Scientific engine", "configuration": "Equations",
        "flower_reference": "Flower 9 reference colors", "libraw": "LibRaw",
    ]
}

extension AnalysisDocument {
    public var differences: ResultsDifferences? {
        guard let results = self["results"] else { return nil }
        let saved = results["versions"]
        let comparison = CKDVersions.compare(saved)
        let versions = CKDVersions.comparedKeys.map { key in
            ResultsDifferences.VersionRow(key: key, label: CKDVersions.labels[key] ?? key, saved: saved?[key]?.stringValue,
                                          current: CKDVersions.current[key]?.stringValue ?? "",
                                          differs: comparison.differing.contains(key))
        }
        let preview = comparison.needsRemeasure ? nil
            : CKDConcentrations.compute(draft: draft.resultsDraft, rois: roiMeasurements, calibration: calibrationSummary).json
        let before = Self.resultValues(results)
        let after = preview.map(Self.resultValues)
        let values = before.enumerated().map { index, row in
            let next = after.flatMap { index < $0.count ? $0[index] : nil }
            return ResultsDifferences.ValueRow(
                id: index, kind: row.kind, unit: row.unit, saved: row.value, savedStatus: row.status,
                current: next?.value, currentStatus: next?.status,
                changed: next.map { !(AnalysisPipeline.sameValue($0.value, row.value) && $0.unit == row.unit && $0.status == row.status) }
            )
        }
        return ResultsDifferences(comparison: comparison, versions: versions, values: values)
    }

    static func resultValues(_ results: JSONValue) -> [(kind: ResultsDifferences.ValueRow.Kind, value: Double?, unit: String, status: String?)] {
        var rows: [(kind: ResultsDifferences.ValueRow.Kind, value: Double?, unit: String, status: String?)] = []
        for reservoir in results["reservoirs"]?.arrayValues ?? [] {
            rows.append((.reservoir(reservoir["id"]?.intValue ?? 0, reservoir["analyte"]?.stringValue ?? ""),
                         reservoir["value"]?.doubleValue, reservoir["unit"]?.stringValue ?? "",
                         reservoir["calculation_status"]?.stringValue))
        }
        for (name, summary) in results["summaries"]?.objectPairs ?? [] {
            rows.append((.summary(name), summary["value"]?.doubleValue, summary["unit"]?.stringValue ?? "", nil))
        }
        let prediction = results["prediction"]
        rows.append((.prediction, prediction?["probability"]?.doubleValue, "probability", prediction?["status"]?.stringValue))
        return rows
    }
}
