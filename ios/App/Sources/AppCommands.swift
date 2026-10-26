import SwiftUI

extension FocusedValues {
    @Entry var analysisModel: AnalysisModel?
}

struct AppCommands: Commands {
    let workspace: WorkspaceModel
    @FocusedValue(\.analysisModel) private var model

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(model?.tool.isDrawing == true ? "Undo Point" : "Undo") { model?.undo() }
                .keyboardShortcut("z")
                .disabled(!(model?.canUndo ?? false))
            Button("Redo") { model?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(model?.canRedo ?? false))
        }
        CommandGroup(replacing: .newItem) {
            Button("Import RAW…") { workspace.request(.raw) }
                .keyboardShortcut("o")
            Button("Import Export ZIP…") { workspace.request(.zip) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Import Analysis Folder…") { workspace.request(.folder) }
        }
        CommandMenu("Analysis") {
            ForEach(Step.allCases) { step in
                Button(step.title) { model?.step = step }
                    .keyboardShortcut(KeyEquivalent(Character(String(step.rawValue + 1))))
                    .disabled(model == nil)
            }
            Divider()
            Button(model?.primaryAction?.title ?? "Run Step") {
                if let model { Task { await model.runPrimary() } }
            }
            .keyboardShortcut(.return)
            .disabled(!(model?.primaryAction?.enabled ?? false) || (model?.busy ?? true))
            Button("Draw Rectangle") { model?.start(.rectangle) }
                .keyboardShortcut("d")
                .disabled(!(model?.availableTools.contains { $0 == .rectangle || $0 == .corners } ?? false))
            Button("Draw Polygon") { model?.start(.polygon) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!(model?.availableTools.contains(.polygon) ?? false))
            Button("Next Reservoir") { model?.nextReservoir() }
                .keyboardShortcut("n", modifiers: [])
                .disabled(model?.step != .reservoirs || (model?.draft.reservoirs.isEmpty ?? true))
            Divider()
            Button("Differences") { model?.showingDifferences = true }
                .disabled(model?.document["results"] == nil)
            Button("Export ZIP…") {
                if let model { Task { await model.export(includeDebugImages: UserDefaults.standard.bool(forKey: "exportDebugImages")) } }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model?.document["results"] == nil || (model?.busy ?? true))
        }
    }
}
