import CKDImage
import Foundation

public struct AnalysisFolder: Sendable {
    public static let documentName = "analysis.ckd.json"
    public static let backupName = ".analysis.previous.json"
    public static let historyName = ".history"
    public static let historyLimit = 20
    static let historyKeys = ["draft", "render", "white_balance", "calibration", "results"]
    public static let maximumRawBytes = 100 * 1024 * 1024

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var documentURL: URL { url.appendingPathComponent(Self.documentName) }

    public static func isAnalysis(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(documentName).path)
    }

    public func load() throws -> AnalysisDocument {
        try AnalysisDocument(data: Data(contentsOf: documentURL))
    }

    public func file(_ relative: String) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
            throw DocumentError("Choose a path inside the analysis folder.")
        }
        return url.appendingPathComponent(relative)
    }

    public func originalURL(_ document: AnalysisDocument) throws -> URL {
        try file(document.sourceFile)
    }

    public func verifyOriginal(_ document: AnalysisDocument) throws -> URL {
        let original = try originalURL(document)
        guard try Digest.sha256(file: original) == document.sourceSHA256 else {
            throw DocumentError("The original image changed. Restore the matching original before processing.")
        }
        return original
    }

    @discardableResult
    public func save(_ document: AnalysisDocument, expectedRevision: Int) throws -> AnalysisDocument {
        let current = try load()
        guard current.revision == expectedRevision else {
            throw DocumentError("This analysis changed elsewhere. Reload before saving.")
        }
        guard current.analysisID == document.analysisID else {
            throw DocumentError("The analysis folder was replaced. Reopen it before saving.")
        }
        var saved = document
        saved.stamp(revision: expectedRevision + 1)
        _ = try AnalysisDocument(data: saved.encoded())
        try remember(current, saved)
        try Self.atomicWrite(current.encoded(), to: url.appendingPathComponent(Self.backupName))
        try Self.atomicWrite(saved.encoded(), to: documentURL)
        return saved
    }

    func remember(_ current: AnalysisDocument, _ result: AnalysisDocument) throws {
        guard Self.historyKeys.contains(where: { current.root[$0] != result.root[$0] }) else { return }
        let history = url.appendingPathComponent(Self.historyName)
        try Self.atomicWrite(current.encoded(), to: history.appendingPathComponent(String(format: "rev-%06d.json", current.revision)))
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: history.path)) ?? [])
            .filter { $0.hasPrefix("rev-") && $0.hasSuffix(".json") }.sorted()
        for stale in entries.dropLast(Self.historyLimit) {
            try? FileManager.default.removeItem(at: history.appendingPathComponent(stale))
        }
    }

    public func history() -> [AnalysisDocument] {
        let history = url.appendingPathComponent(Self.historyName)
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: history.path)) ?? [])
            .filter { $0.hasPrefix("rev-") && $0.hasSuffix(".json") }.sorted(by: >)
        return entries.compactMap { try? AnalysisDocument(data: Data(contentsOf: history.appendingPathComponent($0))) }
    }

    @discardableResult
    public func assignNewID() throws -> AnalysisDocument {
        let current = try load()
        var document = current
        document.assignNewID()
        document.stamp(revision: current.revision + 1)
        _ = try AnalysisDocument(data: document.encoded())
        try Self.atomicWrite(current.encoded(), to: url.appendingPathComponent(Self.backupName))
        try Self.atomicWrite(document.encoded(), to: documentURL)
        return document
    }

    public static func exportFilename(title: String, date: Date = Date()) -> String {
        var cleaned = ""
        var replacing = false
        for scalar in title.unicodeScalars {
            let allowed = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._ -".unicodeScalars.contains(scalar))
            if allowed {
                cleaned.unicodeScalars.append(scalar)
                replacing = false
            } else if !replacing {
                cleaned.append("-")
                replacing = true
            }
        }
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return "\(trimmed.isEmpty ? "ckd-analysis" : trimmed)_\(formatter.string(from: date)).zip"
    }

    public static func create(importing raw: URL, in parent: URL) throws -> (AnalysisFolder, AnalysisDocument) {
        let filename = raw.lastPathComponent
        try QCamRawImport.validate(url: raw)
        let size = (try raw.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { throw DocumentError("The image is empty.") }
        guard size <= maximumRawBytes else { throw DocumentError("Maximum RAW file size is 100 MB.") }
        let staged = parent.appendingPathComponent(".import-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))
        let manager = FileManager.default
        try manager.createDirectory(at: staged.appendingPathComponent("original"), withIntermediateDirectories: true)
        do {
            let original = staged.appendingPathComponent("original").appendingPathComponent(filename)
            try manager.copyItem(at: raw, to: original)
            let document = AnalysisDocument.new(filename: filename, sha256: try Digest.sha256(file: original), bytes: size)
            try atomicWrite(document.encoded(), to: staged.appendingPathComponent(documentName))
            let destination = try publish(staged, in: parent, name: document.draft.title)
            return (AnalysisFolder(url: destination), document)
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
    }

    static func publish(_ staged: URL, in parent: URL, name: String) throws -> URL {
        let base = try safeName(name)
        for suffix in 0..<10000 {
            let candidate = parent.appendingPathComponent(suffix == 0 ? base : "\(base) (\(suffix + 1))")
            if FileManager.default.fileExists(atPath: candidate.path) { continue }
            try FileManager.default.moveItem(at: staged, to: candidate)
            return candidate
        }
        throw DocumentError("Too many folders have this name.")
    }

    public static func safeName(_ value: String) throws -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            scalars.append(scalar.value < 0x20 || scalar == "/" || scalar == ":" || scalar == "\\" ? "-" : scalar)
        }
        var name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        while name.hasSuffix(".") { name.removeLast() }
        name = String(String.UnicodeScalarView(name.unicodeScalars.prefix(120)))
        guard !name.isEmpty else { throw DocumentError("Enter a folder name.") }
        return name
    }

    public static func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
