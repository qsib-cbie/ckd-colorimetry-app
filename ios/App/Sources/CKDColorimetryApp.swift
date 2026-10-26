import CKDDocument
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct CKDColorimetryApp: App {
    @State private var workspace = WorkspaceModel()
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(workspace)
                .onOpenURL { workspace.open($0) }
                .onAppear { UIApplication.shared.isIdleTimerDisabled = AnalysisModel.keepsScreenAwake }
                .task { workspace.applyLaunchOptions() }
                .onAppear { Appearance.apply(appearance) }
                .onChange(of: appearance) { _, value in Appearance.apply(value) }
        }
        .commands { AppCommands(workspace: workspace) }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var style: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    @MainActor
    static func apply(_ value: String) {
        let style = (Appearance(rawValue: value) ?? .system).style
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}

enum ImportKind {
    case raw, zip, folder, workspace

    var types: [UTType] {
        switch self {
        case .raw: return [.dngRaw, .cr2Raw, .data]
        case .zip: return [.zip]
        case .folder, .workspace: return [.folder]
        }
    }
}

struct ImportRequest {
    let id = UUID()
    let kind: ImportKind
    let folder: URL
}

struct RecentWorkspace: Identifiable {
    let bookmark: Data
    let url: URL?

    var id: Data { bookmark }
    var name: String { url?.lastPathComponent ?? "Folder not found" }
}

@MainActor
@Observable
final class WorkspaceModel {
    static let activeKey = "workspaceBookmark"
    static let recentKey = "recentWorkspaceBookmarks"

    let defaultRoot: URL
    private(set) var root: URL
    private(set) var library: WorkspaceLibrary
    let rasters: RasterStore
    var selection: URL?
    var revision = 0
    var currentFolder: URL
    var importRequest: ImportRequest?
    var photoRequest: URL?
    var pendingRender: URL?
    private(set) var duplicateIDs: Set<String> = []
    private(set) var recentWorkspaces: [RecentWorkspace] = []
    private var scoped: URL?
    var error: String?
    var busy = false

    init() {
        let manager = FileManager.default
        defaultRoot = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = defaultRoot
        currentFolder = defaultRoot
        library = WorkspaceLibrary(root: defaultRoot)
        rasters = RasterStore(root: manager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Rasters"))
        if let bookmark = UserDefaults.standard.data(forKey: Self.activeKey) {
            if let url = Self.resolve(bookmark), activate(url) {
                root = url
                currentFolder = url
                library = WorkspaceLibrary(root: url)
            } else {
                error = "The workspace folder could not be opened, so the library on this device is shown. Choose the folder again in Settings."
                UserDefaults.standard.removeObject(forKey: Self.activeKey)
            }
        }
        loadRecents()
    }

    var isExternal: Bool { root != defaultRoot }

    var deviceName: String { UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone" }

    var locationText: String { isExternal ? root.lastPathComponent : "\(deviceName) › CKD Colorimetry" }

    private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private func activate(_ url: URL) -> Bool {
        let started = url.startAccessingSecurityScopedResource()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            if started { url.stopAccessingSecurityScopedResource() }
            return false
        }
        scoped = started ? url : nil
        return true
    }

    private func loadRecents() {
        let bookmarks = UserDefaults.standard.array(forKey: Self.recentKey) as? [Data] ?? []
        recentWorkspaces = bookmarks.map { RecentWorkspace(bookmark: $0, url: Self.resolve($0)) }
    }

    func request(_ kind: ImportKind, into folder: URL? = nil) {
        importRequest = ImportRequest(kind: kind, folder: folder ?? currentFolder)
    }

    func chooseWorkspace(_ url: URL) {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        guard !AnalysisFolder.isAnalysis(url) else {
            error = "Choose a workspace folder outside an existing analysis."
            return
        }
        do {
            switchWorkspace(to: url, bookmark: try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        } catch {
            self.error = error.localizedDescription
        }
    }

    func openRecent(_ recent: RecentWorkspace) {
        guard let url = Self.resolve(recent.bookmark) else {
            error = "This folder is no longer available."
            return
        }
        switchWorkspace(to: url, bookmark: recent.bookmark)
    }

    func forget(_ recent: RecentWorkspace) {
        let bookmarks = recentWorkspaces.map(\.bookmark).filter { $0 != recent.bookmark }
        UserDefaults.standard.set(bookmarks, forKey: Self.recentKey)
        loadRecents()
    }

    private func switchWorkspace(to url: URL, bookmark: Data) {
        let previous = scoped
        scoped = nil
        guard activate(url) else {
            scoped = previous
            error = "This folder is no longer available."
            return
        }
        previous?.stopAccessingSecurityScopedResource()
        setRoot(url)
        UserDefaults.standard.set(bookmark, forKey: Self.activeKey)
        let others = recentWorkspaces.filter { $0.url?.standardizedFileURL != url.standardizedFileURL }.map(\.bookmark)
        UserDefaults.standard.set(Array(([bookmark] + others).prefix(5)), forKey: Self.recentKey)
        loadRecents()
    }

    func useDeviceWorkspace() {
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        UserDefaults.standard.removeObject(forKey: Self.activeKey)
        setRoot(defaultRoot)
    }

    private func setRoot(_ url: URL) {
        root = url
        currentFolder = url
        library = WorkspaceLibrary(root: url)
        selection = nil
        refresh()
    }

    func moveItems(_ paths: [String], into folder: URL) -> Bool {
        var moved = false
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            move(library.item(at: url), to: folder)
            moved = true
        }
        return moved
    }

    func contents(of folder: URL) -> [WorkspaceItem] {
        _ = revision
        return library.contents(of: folder)
    }

    func refresh() {
        revision += 1
        duplicateIDs = library.duplicateAnalysisIDs()
    }

    func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func importRaw(_ url: URL, into folder: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        perform {
            let (created, _) = try AnalysisFolder.create(importing: url, in: folder)
            pendingRender = created.url
            selection = created.url
        }
    }

    func importPhoto(_ item: PhotosPickerItem, into folder: URL) async {
        do {
            guard let raw = try await item.loadTransferable(type: RawPhoto.self) else {
                error = RawPhoto.missing
                return
            }
            defer { try? FileManager.default.removeItem(at: raw.url.deletingLastPathComponent()) }
            importRaw(raw.url, into: folder)
        } catch {
            self.error = RawPhoto.missing
        }
    }

    func open(_ url: URL) {
        if url.pathExtension.lowercased() == "zip" {
            importZIP(url, into: root)
        } else {
            importRaw(url, into: root)
        }
    }

    func importZIP(_ url: URL, into folder: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        perform {
            let (imported, _) = try ExportArchive.read(url, into: folder)
            selection = imported.url
        }
    }

    func importFolder(_ url: URL, into folder: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        perform {
            let imported = try library.importFolder(url, into: folder)
            if AnalysisFolder.isAnalysis(imported) { selection = imported }
        }
    }

    func assignNewID(_ item: WorkspaceItem) {
        perform { try AnalysisFolder(url: item.url).assignNewID() }
    }

    func createFolder(named name: String, in parent: URL) {
        perform { try library.createFolder(named: name, in: parent) }
    }

    func rename(_ item: WorkspaceItem, to name: String) {
        perform {
            let renamed = try library.rename(item, to: name)
            if selection == item.url { selection = renamed }
        }
    }

    func move(_ item: WorkspaceItem, to parent: URL) {
        perform {
            let moved = try library.move(item, to: parent)
            if selection == item.url { selection = moved }
        }
    }

    func delete(_ item: WorkspaceItem) {
        perform {
            if let selection, selection.path.hasPrefix(item.url.path) { self.selection = nil }
            if item.kind == .analysis, let document = try? AnalysisFolder(url: item.url).load() {
                rasters.purge(analysisID: document.analysisID)
            }
            try library.moveToRecentlyDeleted(item)
        }
    }

    func restore(_ item: WorkspaceItem) {
        perform { selection = try library.restore(item) }
    }

    func emptyRecentlyDeleted() {
        perform { try library.emptyRecentlyDeleted() }
    }

    func folders(excluding item: WorkspaceItem? = nil) -> [URL] {
        func walk(_ folder: URL) -> [URL] {
            [folder] + library.contents(of: folder).filter { $0.kind == .folder && $0.url != item?.url }.flatMap { walk($0.url) }
        }
        return walk(root)
    }

    func applyLaunchOptions() {
        let environment = ProcessInfo.processInfo.environment
        if environment["CKD_UI_TEST_RESET"] == "1" {
            UserDefaults.standard.removeObject(forKey: Appearance.key)
            Appearance.apply(Appearance.system.rawValue)
            useDeviceWorkspace()
            UserDefaults.standard.removeObject(forKey: Self.recentKey)
            loadRecents()
            error = nil
            for entry in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: entry)
            }
            try? FileManager.default.removeItem(at: rasters.root)
            selection = nil
        }
        if let path = environment["CKD_UI_TEST_WORKSPACE"], !path.isEmpty {
            chooseWorkspace(URL(testPath: path))
        }
        if library.analyses().isEmpty {
            if let path = environment["CKD_UI_TEST_RAW"], !path.isEmpty {
                importRaw(URL(testPath: path), into: root)
            }
            for path in (environment["CKD_UI_TEST_IMPORT_ZIP"] ?? "").split(separator: "|") {
                importZIP(URL(testPath: String(path)), into: root)
            }
            if let path = environment["CKD_UI_TEST_IMPORT_FOLDER"], !path.isEmpty {
                importFolder(URL(testPath: path), into: root)
            }
            selection = nil
            pendingRender = nil
        }
        refresh()
        if let path = environment["CKD_UI_TEST_STAGE_FILE"], !path.isEmpty {
            let source = URL(testPath: path)
            let staged = root.appendingPathComponent("Staged").appendingPathComponent(source.lastPathComponent)
            try? FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.copyItem(at: source, to: staged)
        }
        if let path = environment["CKD_UI_TEST_OPEN_RAW"], !path.isEmpty {
            open(URL(testPath: path))
        }
    }
}

extension URL {
    /// A UI-test file: an absolute path in the simulator, or a path inside this app's container
    /// that ios/scripts/device_ui_tests.sh copied there on a device.
    init(testPath path: String) {
        self = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path)
    }
}

struct RawPhoto: Transferable {
    static let missing = "This photo has no RAW original. Shoot it as ProRAW or RAW (DNG), or import the file through Files."
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .rawImage) { received in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoImport-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = received.file.lastPathComponent
            let url = directory.appendingPathComponent(["dng", "cr2"].contains(received.file.pathExtension.lowercased()) ? name : name + ".dng")
            try FileManager.default.copyItem(at: received.file, to: url)
            return RawPhoto(url: url)
        }
    }
}
