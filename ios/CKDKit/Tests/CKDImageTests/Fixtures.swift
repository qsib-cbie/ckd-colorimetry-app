import CryptoKit
import Foundation
import XCTest
@testable import CKDImage

enum Fixtures {
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let directory = repositoryRoot.appendingPathComponent("api/tests/fixtures")

    static func raw(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func json(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func decode<T: Decodable>(_ value: Any?, as type: T.Type) throws -> T {
        let object = try XCTUnwrap(value)
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

func number(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) -> Double {
    guard let value = value as? NSNumber else {
        XCTFail("Expected a number, found \(String(describing: value))", file: file, line: line)
        return .nan
    }
    return value.doubleValue
}

func assertClose(_ actual: Double, _ expected: Any?, tolerance: Double, _ label: String,
                 file: StaticString = #filePath, line: UInt = #line) {
    let expectedValue = number(expected, file: file, line: line)
    XCTAssertLessThanOrEqual(abs(actual - expectedValue), tolerance,
                             "\(label): \(actual) vs \(expectedValue)", file: file, line: line)
}

func assertLab(_ actual: QCamLab, _ expected: Any?, tolerance: Double, _ label: String,
               file: StaticString = #filePath, line: UInt = #line) {
    let lab = expected as? [String: Any] ?? [:]
    assertClose(actual.lStar, lab["l_star"], tolerance: tolerance, "\(label) L*", file: file, line: line)
    assertClose(actual.aStar, lab["a_star"], tolerance: tolerance, "\(label) a*", file: file, line: line)
    assertClose(actual.bStar, lab["b_star"], tolerance: tolerance, "\(label) b*", file: file, line: line)
}

func assertRGB(_ actual: QCamRGBMean, _ expected: Any?, tolerance: Double, _ label: String,
               file: StaticString = #filePath, line: UInt = #line) {
    let rgb = expected as? [String: Any] ?? [:]
    assertClose(actual.red, rgb["red"], tolerance: tolerance, "\(label) red", file: file, line: line)
    assertClose(actual.green, rgb["green"], tolerance: tolerance, "\(label) green", file: file, line: line)
    assertClose(actual.blue, rgb["blue"], tolerance: tolerance, "\(label) blue", file: file, line: line)
}

func assertValues(_ actual: [Double], _ expected: Any?, tolerance: Double, _ label: String,
                  file: StaticString = #filePath, line: UInt = #line) {
    let values = expected as? [Any] ?? []
    XCTAssertEqual(actual.count, values.count, "\(label) count", file: file, line: line)
    for (index, pair) in zip(actual, values).enumerated() {
        assertClose(pair.0, pair.1, tolerance: tolerance, "\(label)[\(index)]", file: file, line: line)
    }
}

struct RenderedFixture {
    let initial: QCamRawRenderResult
    let balanced: QCamWhiteBalanceRender
    let firstPassHash: String

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: RenderedFixture] = [:]

    static func named(_ name: String) throws -> RenderedFixture {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        let reference = try Fixtures.json("swift_core/\(name).json")
        let url = Fixtures.raw(name)
        let initial = try QCamRawImport.render(url: url)
        var firstPassHash = ""
        let balanced = try QCamWhiteBalancePipeline.render(
            url: url,
            initialImage: initial.image,
            cameraWhiteBalance: initial.cameraWhiteBalance,
            polygon: try Fixtures.decode(reference["white_balance_polygon"], as: QCamPolygon.self),
            afterFirstPass: { firstPassHash = Fixtures.sha256($0.data) }
        )
        let rendered = RenderedFixture(initial: initial, balanced: balanced, firstPassHash: firstPassHash)
        cache[name] = rendered
        return rendered
    }
}
