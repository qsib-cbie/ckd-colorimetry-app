import Foundation

public struct WorkspaceItem: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case folder, analysis, problem }

    public let url: URL
    public let kind: Kind
    public let title: String
    public let detail: String
    public var analysisID: String?

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
}

public struct WorkspaceLibrary: Sendable {
    public static let recentlyDeletedName = ".Recently Deleted"
    static let originName = ".ckd-origin"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var recentlyDeletedURL: URL { root.appendingPathComponent(Self.recentlyDeletedName) }

    public func contents(of folder: URL) -> [WorkspaceItem] {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        return entries.compactMap { url -> WorkspaceItem? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true, !url.lastPathComponent.hasPrefix(".") else { return nil }
            return item(at: url)
        }.sorted { lhs, rhs in
            if (lhs.kind == .folder) != (rhs.kind == .folder) { return lhs.kind == .folder }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    public func item(at url: URL) -> WorkspaceItem {
        guard AnalysisFolder.isAnalysis(url) else {
            return WorkspaceItem(url: url, kind: .folder, title: url.lastPathComponent, detail: "")
        }
        do {
            let document = try AnalysisFolder(url: url).load()
            return WorkspaceItem(url: url, kind: .analysis, title: document.draft.title, detail: document.sourceFilename,
                                 analysisID: document.analysisID)
        } catch {
            return WorkspaceItem(url: url, kind: .problem, title: url.lastPathComponent, detail: error.localizedDescription)
        }
    }

    public func analyses(under folder: URL? = nil) -> [WorkspaceItem] {
        contents(of: folder ?? root).flatMap { item -> [WorkspaceItem] in
            item.kind == .folder ? analyses(under: item.url) : [item]
        }
    }

    public func duplicateAnalysisIDs() -> Set<String> {
        var counts: [String: Int] = [:]
        for item in analyses() {
            if let id = item.analysisID { counts[id, default: 0] += 1 }
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    @discardableResult
    public func importFolder(_ source: URL, into parent: URL) throws -> URL {
        let manager = FileManager.default
        let isAnalysis = AnalysisFolder.isAnalysis(source)
        guard isAnalysis || !WorkspaceLibrary(root: source).analyses().isEmpty else {
            throw DocumentError("This folder does not contain a CKD analysis.")
        }
        if isAnalysis { _ = try AnalysisFolder(url: source).load() }
        let staged = parent.appendingPathComponent(".import-" + UUID().uuidString)
        try manager.createDirectory(at: staged, withIntermediateDirectories: true)
        do {
            let enumerator = manager.enumerator(atPath: source.path)
            while let relative = enumerator?.nextObject() as? String {
                let entry = source.appendingPathComponent(relative)
                let attributes = try manager.attributesOfItem(atPath: entry.path)
                let type = attributes[.type] as? FileAttributeType
                let name = entry.lastPathComponent
                if type == .typeSymbolicLink || name == ".cache" || name.hasPrefix(".ckd") && name.hasSuffix(".lock") {
                    if type == .typeDirectory { enumerator?.skipDescendants() }
                    continue
                }
                let target = staged.appendingPathComponent(relative)
                if type == .typeDirectory {
                    try manager.createDirectory(at: target, withIntermediateDirectories: true)
                } else if type == .typeRegular {
                    try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try manager.copyItem(at: entry, to: target)
                }
            }
            return try AnalysisFolder.publish(staged, in: parent, name: source.lastPathComponent)
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
    }

    @discardableResult
    public func createFolder(named name: String, in parent: URL) throws -> URL {
        let base = try AnalysisFolder.safeName(name)
        for suffix in 0..<10000 {
            let candidate = parent.appendingPathComponent(suffix == 0 ? base : "\(base) (\(suffix + 1))")
            if FileManager.default.fileExists(atPath: candidate.path) { continue }
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
            return candidate
        }
        throw DocumentError("Too many folders have this name.")
    }

    @discardableResult
    public func rename(_ item: WorkspaceItem, to name: String) throws -> URL {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = try AnalysisFolder.safeName(title)
        if item.kind == .analysis {
            let folder = AnalysisFolder(url: item.url)
            var document = try folder.load()
            var draft = document.draft
            draft.title = String(String.UnicodeScalarView(title.unicodeScalars.prefix(120)))
            try document.replaceDraft(draft)
            try folder.save(document, expectedRevision: document.revision)
        }
        guard safe != item.url.lastPathComponent else { return item.url }
        let parent = item.url.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".rename-" + UUID().uuidString)
        try FileManager.default.moveItem(at: item.url, to: staged)
        do {
            return try AnalysisFolder.publish(staged, in: parent, name: safe)
        } catch {
            try? FileManager.default.moveItem(at: staged, to: item.url)
            throw error
        }
    }

    @discardableResult
    public func move(_ item: WorkspaceItem, to parent: URL) throws -> URL {
        guard !parent.standardizedFileURL.path.hasPrefix(item.url.standardizedFileURL.path + "/"),
              parent.standardizedFileURL != item.url.standardizedFileURL else {
            throw DocumentError("A folder cannot contain itself.")
        }
        guard parent.standardizedFileURL != item.url.deletingLastPathComponent().standardizedFileURL else { return item.url }
        let staged = parent.appendingPathComponent(".move-" + UUID().uuidString)
        try FileManager.default.moveItem(at: item.url, to: staged)
        return try AnalysisFolder.publish(staged, in: parent, name: item.url.lastPathComponent)
    }

    public func moveToRecentlyDeleted(_ item: WorkspaceItem) throws {
        let holder = recentlyDeletedURL.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        let relative = item.url.deletingLastPathComponent().path.replacingOccurrences(of: root.path, with: "")
        try Data(relative.utf8).write(to: holder.appendingPathComponent(Self.originName))
        try FileManager.default.moveItem(at: item.url, to: holder.appendingPathComponent(item.url.lastPathComponent))
    }

    public func recentlyDeleted() -> [WorkspaceItem] {
        let holders = (try? FileManager.default.contentsOfDirectory(at: recentlyDeletedURL, includingPropertiesForKeys: nil)) ?? []
        return holders.flatMap { holder in
            ((try? FileManager.default.contentsOfDirectory(at: holder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent != Self.originName }
                .map { item(at: $0) }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    @discardableResult
    public func restore(_ item: WorkspaceItem) throws -> URL {
        let holder = item.url.deletingLastPathComponent()
        let relative = (try? String(contentsOf: holder.appendingPathComponent(Self.originName), encoding: .utf8)) ?? ""
        var parent = root.appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            parent = root
        }
        let restored = try AnalysisFolder.publish(item.url, in: parent, name: item.url.lastPathComponent)
        try? FileManager.default.removeItem(at: holder)
        return restored
    }

    public func emptyRecentlyDeleted() throws {
        if FileManager.default.fileExists(atPath: recentlyDeletedURL.path) {
            try FileManager.default.removeItem(at: recentlyDeletedURL)
        }
    }
}
