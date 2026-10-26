import CKDImage
import Foundation

public struct CachedRaster: Sendable {
    public let image: QCamRGBAImage
    public let matchesSavedHash: Bool
}

public struct RasterStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    func url(_ document: AnalysisDocument, _ block: String) -> URL? {
        guard let array = document[block]?["array"]?.stringValue else { return nil }
        let name = ((array as NSString).lastPathComponent as NSString).deletingPathExtension + ".rgba"
        return root.appendingPathComponent(document.analysisID).appendingPathComponent(name)
    }

    public func save(_ image: QCamRGBAImage, document: AnalysisDocument, block: String) throws {
        guard let url = url(document, block) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image.data.write(to: url, options: .atomic)
    }

    public func cached(_ document: AnalysisDocument, block: String) -> QCamRGBAImage? {
        guard let url = url(document, block),
              let width = document[block]?["width"]?.intValue, let height = document[block]?["height"]?.intValue,
              let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count == width * height * 4 else { return nil }
        return QCamRGBAImage(width: width, height: height, data: data)
    }

    public func image(_ document: AnalysisDocument, folder: AnalysisFolder, balanced: Bool) throws -> CachedRaster {
        let block = balanced && document["white_balance"] != nil ? "white_balance" : "render"
        guard document[block] != nil else { throw DocumentError("This image has not been processed yet.") }
        if let image = cached(document, block: block) {
            return CachedRaster(image: image, matchesSavedHash: true)
        }
        var rebuilt = document
        let initial = try cached(document, block: "render") ?? AnalysisPipeline.render(&rebuilt, folder: folder)
        let initialMatches = Digest.sha256(initial.data) == document["render"]?["rgba8888_sha256"]?.stringValue
        try save(initial, document: document, block: "render")
        guard block == "white_balance" else { return CachedRaster(image: initial, matchesSavedHash: initialMatches) }
        rebuilt = document
        let image = try AnalysisPipeline.whiteBalance(&rebuilt, folder: folder, initial: initial)
        try save(image, document: document, block: "white_balance")
        let matches = Digest.sha256(image.data) == document["white_balance"]?["rgba8888_sha256"]?.stringValue
        return CachedRaster(image: image, matchesSavedHash: initialMatches && matches)
    }

    public func purge(analysisID: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(analysisID))
    }

    public func prune(_ document: AnalysisDocument) {
        let keep = Set(["render", "white_balance"].compactMap { url(document, $0)?.lastPathComponent })
        let directory = root.appendingPathComponent(document.analysisID)
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
