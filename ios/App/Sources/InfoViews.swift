import CKDDocument
import CKDImage
import CKDResults
import SwiftUI

struct SettingsView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @AppStorage("exportDebugImages") private var exportDebugImages = false
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.appearance")
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows the iPad or iPhone setting.")
            }
            Section {
                Toggle("Include debug images in exports", isOn: $exportDebugImages)
            } footer: {
                Text("Adds the rendered and white-balanced RGBA rasters in the iOS debug format. Each is about 4 bytes per pixel, so 200 MB at 50 megapixels.")
            }
            Section {
                LabeledContent("Location", value: workspace.locationText)
                    .accessibilityIdentifier("settings.location")
                Button("Choose Folder…", systemImage: "folder") { workspace.request(.workspace) }
                    .accessibilityIdentifier("settings.chooseWorkspace")
                if workspace.isExternal {
                    Button("Use \(workspace.deviceName)", systemImage: "ipad.and.iphone") { workspace.useDeviceWorkspace() }
                        .accessibilityIdentifier("settings.useDevice")
                }
            } header: {
                Text("Workspace")
            } footer: {
                Text("Choose a folder in Files, such as one in iCloud Drive or on a USB drive, to work in it directly. A Mac workspace folder in iCloud Drive opens here too. Analyses are ordinary folders, so they also move through Files, AirDrop or Mail.")
            }
            if !workspace.recentWorkspaces.isEmpty {
                Section("Recent folders") {
                    ForEach(workspace.recentWorkspaces) { recent in
                        Button {
                            workspace.openRecent(recent)
                        } label: {
                            Label(recent.name, systemImage: recent.url?.standardizedFileURL == workspace.root.standardizedFileURL
                                  ? "checkmark.circle.fill" : "folder")
                        }
                        .disabled(recent.url == nil)
                        .swipeActions {
                            Button("Remove", role: .destructive) { workspace.forget(recent) }
                        }
                    }
                }
            }
            Section("App") {
                LabeledContent("Version", value: AppVersion.mobile)
                LabeledContent("CKD release", value: CKDVersions.app)
                NavigationLink("Acknowledgements") { AcknowledgementsView() }
                    .accessibilityIdentifier("settings.acknowledgements")
            }
        }
        .navigationTitle("Settings")
    }
}

struct AcknowledgementsView: View {
    private struct Notice: Identifiable {
        let title: String
        let license: String
        let file: String

        var id: String { file }
    }

    private static let notices = [
        Notice(title: "LibRaw 0.22.1", license: "CDDL 1.0", file: "LibRaw"),
        Notice(title: "LibRaw licence text", license: "CDDL 1.0", file: "LibRaw-CDDL-1.0"),
        Notice(title: "LibRaw: DCB and FBDD", license: "BSD 3-clause", file: "LibRaw-DCB-FBDD-BSD"),
        Notice(title: "LibRaw: X3F library", license: "BSD", file: "LibRaw-X3F-BSD"),
        Notice(title: "ZIPFoundation 0.9.19", license: "MIT", file: "ZIPFoundation-MIT"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.notices) { notice in
                    NavigationLink {
                        LicenseTextView(title: notice.title, file: notice.file)
                    } label: {
                        LabeledContent(notice.title, value: notice.license)
                    }
                    .accessibilityIdentifier("acknowledgements.\(notice.file)")
                }
            } footer: {
                Text("LibRaw decodes the RAW images and is used unmodified under its CDDL option; its source code is available from the LibRaw project at the version shown. ZIPFoundation reads and writes export ZIPs.")
            }
        }
        .navigationTitle("Acknowledgements")
    }
}

struct LicenseTextView: View {
    let title: String
    let file: String

    var body: some View {
        ScrollView {
            Text(verbatim: Bundle.main.url(forResource: file, withExtension: "txt")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Notice not found.")
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .accessibilityIdentifier("license.text")
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct EquationsView: View {
    private static func number(_ value: Double) -> String {
        PythonFormat.float(value)
    }

    private func coefficients(_ values: [Double]) -> String {
        zip(["1", "L*", "a*", "b*"], values).map { "\(Self.number($1))·\($0)" }.joined(separator: " + ")
    }

    var body: some View {
        Form {
            Section("Versions") {
                LabeledContent("iPad and iPhone app", value: AppVersion.mobile)
                LabeledContent("CKD release", value: CKDVersions.app)
                LabeledContent("Scientific engine", value: CKDVersions.engine)
                LabeledContent("Equations", value: CKDEquations.configVersion)
                LabeledContent("Flower 9 reference colors", value: CKDEquations.flowerVersion)
                LabeledContent("LibRaw", value: QCamRawImport.libRawVersionTriple)
                LabeledContent("Platform", value: "iPad and iPhone")
            }
            .accessibilityIdentifier("equations.versions")
            Section("Review ranges") {
                ForEach(CKDEquations.analytes, id: \.self) { analyte in
                    let range = CKDEquations.ranges[analyte]!
                    LabeledContent(AnalyteName.label(analyte),
                                   value: "\(Self.number(range.minimum)) to \(Self.number(range.maximum)) \(AnalyteName.unit(CKDEquations.units[analyte]!))")
                }
            }
            Section {
                Text(verbatim: "b* = \(Self.number(CKDEquations.phQuadratic))·pH² + \(Self.number(CKDEquations.phLinear))·pH + (\(Self.number(CKDEquations.phIntercept)))")
                Text(verbatim: CKDEquations.equations["ph"]!).font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("pH")
            } footer: {
                Text("Solved for the root in the calibrated range; no real root means an invalid domain.")
            }
            Section {
                Text(verbatim: "creatinine (µM) = (\(Self.number(CKDEquations.creatinineNumerator)) − √(\(Self.number(CKDEquations.creatinineOffset)) − \(Self.number(CKDEquations.creatinineSlope))·a*)) / \(Self.number(CKDEquations.creatinineDenominator))")
                Text(verbatim: CKDEquations.equations["creatinine"]!).font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Creatinine")
            }
            ForEach(["lab", "ab"], id: \.self) { key in
                let calibration = CKDEquations.ureaCalibrations[key]!
                Section {
                    ForEach(calibration.models.keys.sorted(), id: \.self) { model in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(model): urea (mM) = \(coefficients(calibration.models[model]!))")
                            Text(verbatim: applies(model)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(verbatim: "Urea, \(calibration.label)")
                } footer: {
                    Text(verbatim: calibration.version)
                }
            }
            Section {
                Text(verbatim: "z = \(Self.number(CKDEquations.classifierIntercept)) − \(Self.number(CKDEquations.classifierUrea))·urea − \(Self.number(CKDEquations.classifierCreatinine))·creatinine − \(Self.number(CKDEquations.classifierAge))·age + \(Self.number(CKDEquations.classifierMale))·male; probability = 1 / (1 + eᶻ)")
                LabeledContent("Threshold", value: Self.number(CKDEquations.classifierThreshold))
                Text(verbatim: CKDEquations.classifierVersion).font(.caption).foregroundStyle(.secondary)
                ForEach(["creatinine", "urea"], id: \.self) { name in
                    let c = CKDEquations.singleClassifiers[name]!
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: CKDEquations.classifierLabels[name]!).bold()
                        Text(verbatim: "logit = \(Self.number(c.intercept)) + \(Self.number(c.analyte))·\(name) + \(Self.number(c.age))·age + \(Self.number(c.male))·male")
                        Text(verbatim: "threshold \(Self.number(c.threshold)), AUC \(Self.number(c.auc)) · \(c.version)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Prediction")
            } footer: {
                Text("Automatic uses urea and creatinine when both are final, otherwise the single-analyte model that has its input.")
            }
            Section("Calibration") {
                LabeledContent("Flower 9 references", value: CKDEquations.flowerVersion)
                LabeledContent("Standard 24 maximum RMSE", value: Self.number(MacCalibration.standard24MaxRMSE))
                Text("L* is fitted independently and a*, b* jointly.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Equations and versions")
    }

    private func applies(_ model: String) -> String {
        let limits = CKDEquations.ureaModelLimits
        switch model {
        case "pH_6.0": return "pH ≤ \(Self.number(limits.low))"
        case "pH_6.5": return "\(Self.number(limits.low)) < pH ≤ \(Self.number(limits.high))"
        default: return "pH > \(Self.number(limits.high))"
        }
    }
}

enum AppVersion {
    static let mobile = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
}
