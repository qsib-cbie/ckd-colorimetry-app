import CKDDocument
import CKDResults
import Foundation
import XCTest

enum Paths {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("api/tests/fixtures")
    static let macReference = fixtures.appendingPathComponent("mac_reference")

    static func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ckd-document-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func json(_ url: URL) throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: url))
    }
}

struct Difference: CustomStringConvertible {
    let path: String
    let detail: String
    var description: String { "\(path): \(detail)" }
}

enum Same {
    static func json(_ actual: JSONValue?, _ expected: JSONValue?, tolerance: Double, path: String = "$",
                     skip: Set<String> = [], into out: inout [Difference]) {
        switch (actual, expected) {
        case (nil, nil): return
        case (.some(let a), .some(let e)):
            if let x = a.doubleValue, let y = e.doubleValue, !(a.isBool || e.isBool) {
                if !(x == y || abs(x - y) <= tolerance * max(1, abs(y))) { out.append(Difference(path: path, detail: "\(x) vs \(y)")) }
                return
            }
            switch (a, e) {
            case (.array(let xs), .array(let ys)):
                guard xs.count == ys.count else { out.append(Difference(path: path, detail: "\(xs.count) vs \(ys.count) items")); return }
                for (index, pair) in zip(xs, ys).enumerated() {
                    json(pair.0, pair.1, tolerance: tolerance, path: "\(path)[\(index)]", skip: skip, into: &out)
                }
            case (.object(let xs), .object(let ys)):
                let keys = Set(xs.map(\.0)).union(ys.map(\.0)).subtracting(skip)
                for key in keys.sorted() {
                    json(a[key], e[key], tolerance: tolerance, path: "\(path).\(key)", skip: skip, into: &out)
                }
            default:
                if a != e { out.append(Difference(path: path, detail: "\(a.pythonJSON.prefix(120)) vs \(e.pythonJSON.prefix(120))")) }
            }
        default:
            out.append(Difference(path: path, detail: "\(actual?.pythonJSON.prefix(80) ?? "missing") vs \(expected?.pythonJSON.prefix(80) ?? "missing")"))
        }
    }

    static func csv(_ actual: String, _ expected: String, tolerance: Double, name: String, into out: inout [Difference]) {
        let a = parse(actual), e = parse(expected)
        guard a.count == e.count else { out.append(Difference(path: name, detail: "\(a.count) vs \(e.count) rows")); return }
        for (row, pair) in zip(a, e).enumerated() {
            guard pair.0.count == pair.1.count else {
                out.append(Difference(path: "\(name) row \(row)", detail: "\(pair.0.count) vs \(pair.1.count) cells"))
                continue
            }
            for (column, cells) in zip(pair.0, pair.1).enumerated() where !cell(cells.0, cells.1, tolerance) {
                out.append(Difference(path: "\(name) row \(row) \(e.first?[column] ?? "")", detail: "\(cells.0) vs \(cells.1)"))
            }
        }
    }

    private static func cell(_ a: String, _ b: String, _ tolerance: Double) -> Bool {
        if a == b { return true }
        func number(_ text: String) -> Double? { Double(text.hasPrefix("'") ? String(text.dropFirst()) : text) }
        if let x = number(a), let y = number(b) { return abs(x - y) <= tolerance * max(1, abs(y)) }
        let xs = a.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let ys = b.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        if xs.count > 1, xs.count == ys.count { return zip(xs, ys).allSatisfy { cell($0, $1, tolerance) } }
        let ps = a.split(separator: ":").map(String.init), qs = b.split(separator: ":").map(String.init)
        if ps.count == 2, qs.count == 2 { return zip(ps, qs).allSatisfy { cell($0, $1, tolerance) } }
        if let x = try? JSONValue.parse(Data(a.utf8)), let y = try? JSONValue.parse(Data(b.utf8)) {
            var differences: [Difference] = []
            json(x, y, tolerance: tolerance, into: &differences)
            return differences.isEmpty
        }
        return false
    }

    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if quoted {
                if scalar == "\"" {
                    if index < scalars.count, scalars[index] == "\"" { field.unicodeScalars.append("\""); index += 1 } else { quoted = false }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"": quoted = true
            case ",": row.append(field); field = ""
            case "\r": continue
            case "\n": row.append(field); rows.append(row); row = []; field = ""
            default: field.unicodeScalars.append(scalar)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

extension JSONValue {
    var isBool: Bool { if case .bool = self { return true } else { return false } }
}

func assertNoDifferences(_ differences: [Difference], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(differences.isEmpty, "\(label): \(differences.count) differences\n"
                  + differences.prefix(15).map(\.description).joined(separator: "\n"), file: file, line: line)
}
