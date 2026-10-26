import CKDDocument
import CKDResults
import Foundation
import ZIPFoundation

let arguments = CommandLine.arguments
if arguments.count >= 7, arguments[1] == "--run", arguments[3] == "--raw", arguments[5] == "--output" {
    let scale = arguments.count == 9 && arguments[7] == "--scale" ? Double(arguments[8]) ?? 1 : 1
    try StatsRun.run(document: URL(fileURLWithPath: arguments[2]), raw: URL(fileURLWithPath: arguments[4]), scale: scale,
                     output: URL(fileURLWithPath: arguments[6], isDirectory: true))
    exit(0)
}
guard arguments.count == 3, arguments[1] == "--output" else {
    FileHandle.standardError.write(Data("""
        usage: ckd-contract --output <candidate directory>
               ckd-contract --run <Mac analysis JSON> --raw <RAW> --output <directory> [--scale <factor>]

        """.utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("api/tests/fixtures")
let reference = fixtures.appendingPathComponent("mac_reference/contract")

let archive = try Archive(url: reference.appendingPathComponent("mac_export.zip"), accessMode: .read)
var coordinates = Data()
_ = try archive.extract(archive["coordinates.json"]!) { coordinates.append($0) }
let mac = try JSONValue.parse(Data(contentsOf: reference.appendingPathComponent("Mac analysis/analysis.ckd.json")))

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let result = try ContractWorkflow.run(
    raw: fixtures.appendingPathComponent("_NOT_ACTUAL_TEST.dng"),
    coordinates: try JSONValue.parse(coordinates),
    age: mac["draft"]?["age"]?.doubleValue,
    sex: mac["draft"]?["sex"]?.stringValue,
    classifierModel: mac["draft"]?["classifier_model"]?.stringValue,
    in: output
)
try ExportArchive.write(result.document, folder: result.folder, image: result.image, initial: result.initial,
                        to: output.appendingPathComponent("ios_export.zip"))
print("Wrote \(result.folder.url.lastPathComponent) and ios_export.zip to \(output.path)")
