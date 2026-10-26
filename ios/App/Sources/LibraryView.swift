import CKDDocument
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let dngRaw = UTType("com.adobe.raw-image") ?? .data
    static let cr2Raw = UTType("com.canon.cr2-raw-image") ?? .data
}

struct LibraryView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var photo: PhotosPickerItem?
    @State private var photoFolder: URL?
    @State private var fileRequest: ImportRequest?

    var body: some View {
        @Bindable var workspace = workspace
        NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $compactColumn) {
            NavigationStack {
                FolderView(folder: workspace.root, title: "Library")
                    .navigationDestination(for: URL.self) { FolderView(folder: $0, title: $0.lastPathComponent) }
            }
            .id(workspace.root)
        } detail: {
            if let selection = workspace.selection {
                AnalysisScreen(url: selection)
                    .id(selection)
            } else {
                ContentUnavailableView("No analysis open", systemImage: "camera.aperture",
                                       description: Text("Import a DNG or CR2 file, or choose an analysis in the library."))
            }
        }
        .onChange(of: workspace.selection) { _, selection in
            guard selection != nil else { return }
            visibility = .detailOnly
            compactColumn = .detail
        }
        .fileImporter(isPresented: Binding(get: { workspace.importRequest != nil }, set: { if !$0 { workspace.importRequest = nil } }),
                      allowedContentTypes: workspace.importRequest?.kind.types ?? [.data]) { result in
            if case .failure(let error) = result { workspace.error = error.localizedDescription }
            guard case .success(let url) = result, let request = fileRequest else { return }
            switch request.kind {
            case .zip: workspace.importZIP(url, into: request.folder)
            case .folder: workspace.importFolder(url, into: request.folder)
            case .workspace: workspace.chooseWorkspace(url)
            case .raw: workspace.importRaw(url, into: request.folder)
            }
        }
        .photosPicker(isPresented: Binding(get: { workspace.photoRequest != nil }, set: { if !$0 { workspace.photoRequest = nil } }),
                      selection: $photo, matching: .images, preferredItemEncoding: .current)
        .onChange(of: workspace.importRequest?.id) { _, _ in
            if let request = workspace.importRequest { fileRequest = request }
        }
        .onChange(of: workspace.photoRequest) { _, folder in
            if let folder { photoFolder = folder }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await workspace.importPhoto(item, into: photoFolder ?? workspace.root) }
        }
        .alert("Something went wrong", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspace.error ?? "")
        }
    }
}

struct FolderView: View {
    @Environment(WorkspaceModel.self) private var workspace
    let folder: URL
    let title: String
    @State private var naming: Naming?
    @State private var moving: WorkspaceItem?
    @State private var deleting: WorkspaceItem?
    @State private var dropTarget: URL?

    struct Naming: Identifiable {
        let id = UUID()
        let item: WorkspaceItem?
        var text: String
    }

    var body: some View {
        let items = workspace.contents(of: folder)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if items.isEmpty {
                    Text("Import a DNG or CR2 file to start an analysis.")
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
                ForEach(items) { item in
                    row(item)
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(highlight(item), in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 10))
                        .draggable(item.url.path)
                        .dropDestination(for: String.self) { paths, _ in
                            item.kind == .folder && workspace.moveItems(paths.filter { $0 != item.url.path }, into: item.url)
                        } isTargeted: { targeted in
                            if targeted { dropTarget = item.url } else if dropTarget == item.url { dropTarget = nil }
                        }
                        .contextMenu {
                            if isDuplicate(item) {
                                Button("Give this copy its own ID", systemImage: "number") { workspace.assignNewID(item) }
                            }
                            Button("Rename", systemImage: "pencil") { naming = Naming(item: item, text: item.title) }
                            Button("Move to…", systemImage: "folder") { moving = item }
                            Button("Move to Recently Deleted", systemImage: "trash", role: .destructive) { deleting = item }
                        }
                }
                if folder == workspace.root {
                    Divider().padding(.vertical, 8)
                    Group {
                        NavigationLink {
                            RecentlyDeletedView()
                        } label: {
                            linkLabel("Recently Deleted", systemImage: "trash")
                        }
                        NavigationLink {
                            SettingsView()
                        } label: {
                            linkLabel("Settings", systemImage: "gearshape")
                        }
                        NavigationLink {
                            EquationsView()
                        } label: {
                            linkLabel("Equations and versions", systemImage: "function")
                        }
                        .accessibilityIdentifier("library.equations")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Import RAW…", systemImage: "square.and.arrow.down") { workspace.request(.raw, into: folder) }
                    Button("Import from Photos…", systemImage: "photo.on.rectangle") { workspace.photoRequest = folder }
                        .accessibilityIdentifier("library.importPhoto")
                    Button("Import export ZIP…", systemImage: "doc.zipper") { workspace.request(.zip, into: folder) }
                    Button("Import analysis folder…", systemImage: "folder.badge.gearshape") { workspace.request(.folder, into: folder) }
                    Button("New Folder", systemImage: "folder.badge.plus") { naming = Naming(item: nil, text: "New Folder") }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityIdentifier("library.add")
            }
        }
        .onAppear { workspace.currentFolder = folder }
        .alert(naming?.item == nil ? "New Folder" : "Rename", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: Binding(get: { naming?.text ?? "" }, set: { naming?.text = $0 }))
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard let naming else { return }
                if let item = naming.item {
                    workspace.rename(item, to: naming.text)
                } else {
                    workspace.createFolder(named: naming.text, in: folder)
                }
            }
        }
        .confirmationDialog("Move \(deleting?.title ?? "") to Recently Deleted?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) { if let deleting { workspace.delete(deleting) } }
        }
        .sheet(item: $moving) { item in
            MoveSheet(item: item)
        }
    }

    private func highlight(_ item: WorkspaceItem) -> Color {
        if dropTarget == item.url && item.kind == .folder { return Color.accentColor.opacity(0.25) }
        return workspace.selection == item.url ? Color.accentColor.opacity(0.15) : .clear
    }

    private func linkLabel(_ title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func isDuplicate(_ item: WorkspaceItem) -> Bool {
        item.analysisID.map { workspace.duplicateIDs.contains($0) } ?? false
    }

    @ViewBuilder
    private func row(_ item: WorkspaceItem) -> some View {
        switch item.kind {
        case .folder:
            NavigationLink(value: item.url) {
                linkLabel(item.title, systemImage: "folder")
            }
            .accessibilityIdentifier("library.folder.\(item.title)")
        case .analysis:
            Button {
                workspace.selection = item.url
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label(item.title, systemImage: "camera.aperture")
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    if isDuplicate(item) {
                        Text("Shares its ID with another copy").font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("library.duplicate")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("library.analysis.\(item.title)")
        case .problem:
            VStack(alignment: .leading, spacing: 2) {
                Label(item.title, systemImage: "exclamationmark.triangle")
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MoveSheet: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let item: WorkspaceItem

    var body: some View {
        NavigationStack {
            List(workspace.folders(excluding: item), id: \.self) { folder in
                Button(folder == workspace.root ? "Library" : folder.path.replacingOccurrences(of: workspace.root.path + "/", with: "")) {
                    workspace.move(item, to: folder)
                    dismiss()
                }
            }
            .navigationTitle("Move \(item.title)")
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}

struct RecentlyDeletedView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @State private var confirmEmpty = false

    var body: some View {
        let _ = workspace.revision
        let items = workspace.library.recentlyDeleted()
        List {
            if items.isEmpty {
                Text("Nothing here.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack {
                    Label(item.title, systemImage: item.kind == .folder ? "folder" : "camera.aperture")
                    Spacer()
                    Button("Restore") { workspace.restore(item) }
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .toolbar {
            Button("Empty", role: .destructive) { confirmEmpty = true }
                .disabled(items.isEmpty)
        }
        .confirmationDialog("Permanently delete everything in Recently Deleted?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) { workspace.emptyRecentlyDeleted() }
        }
    }
}

