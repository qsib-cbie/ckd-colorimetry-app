import CKDImage
import CKDResults
import Foundation

public enum ContractWorkflow {
    public struct Output {
        public let folder: AnalysisFolder
        public let document: AnalysisDocument
        public let image: QCamRGBAImage
        public let initial: QCamRGBAImage
    }

    public static func run(raw: URL, coordinates: JSONValue, age: Double?, sex: String?, classifierModel: String?,
                           in workspace: URL) throws -> Output {
        var (folder, document) = try AnalysisFolder.create(importing: raw, in: workspace)
        let initial = try AnalysisPipeline.render(&document, folder: folder)
        document = try folder.save(document, expectedRevision: document.revision)
        var draft = try CoordinatePackage.importDraft(coordinates, into: document)
        try AnalysisPipeline.apply(draft, to: &document, imported: true)
        document = try folder.save(document, expectedRevision: document.revision)
        draft = document.draft
        draft.age = age
        draft.sex = sex
        draft.classifierModel = classifierModel
        try AnalysisPipeline.apply(draft, to: &document)
        document = try folder.save(document, expectedRevision: document.revision)
        let balanced = try AnalysisPipeline.whiteBalance(&document, folder: folder, initial: initial)
        try AnalysisPipeline.calibrate(&document, image: balanced)
        try AnalysisPipeline.analyze(&document, image: balanced)
        document = try folder.save(document, expectedRevision: document.revision)
        return Output(folder: folder, document: document, image: balanced, initial: initial)
    }
}
