import Foundation
import XCTest

enum ResultsFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("api/tests/fixtures/ios_results")

    static func cases() throws -> [[String: Any]] {
        let data = try Data(contentsOf: directory.appendingPathComponent("cases.json"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(payload["cases"] as? [[String: Any]])
    }

    static func decode<T: Decodable>(_ value: Any?, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(value), options: [.fragmentsAllowed]))
    }
}

struct Mismatch: CustomStringConvertible {
    let path: String
    let detail: String
    var description: String { "\(path): \(detail)" }
}

enum Compare {
    static func close(_ a: Double, _ b: Double) -> Bool {
        a == b || abs(a - b) <= 1e-9 * max(1, abs(b))
    }

    static func json(_ actual: Any, _ expected: Any, path: String = "$", into mismatches: inout [Mismatch]) {
        if let expectedNumber = expected as? NSNumber, CFGetTypeID(expectedNumber) == CFBooleanGetTypeID() {
            if (actual as? Bool) != expectedNumber.boolValue {
                mismatches.append(Mismatch(path: path, detail: "\(actual) vs bool \(expectedNumber.boolValue)"))
            }
            return
        }
        switch expected {
        case is NSNull:
            if !(actual is NSNull) { mismatches.append(Mismatch(path: path, detail: "\(actual) vs null")) }
        case let number as NSNumber:
            guard let value = (actual as? Double) ?? (actual as? Int).map(Double.init) else {
                mismatches.append(Mismatch(path: path, detail: "\(actual) vs number \(number)"))
                return
            }
            if !close(value, number.doubleValue) {
                mismatches.append(Mismatch(path: path, detail: "\(value) vs \(number.doubleValue)"))
            }
        case let text as String:
            if (actual as? String) != text { mismatches.append(Mismatch(path: path, detail: "\(actual) vs \(text)")) }
        case let array as [Any]:
            guard let values = actual as? [Any], values.count == array.count else {
                mismatches.append(Mismatch(path: path, detail: "array \(actual) vs \(array)"))
                return
            }
            for (index, pair) in zip(values, array).enumerated() {
                json(pair.0, pair.1, path: "\(path)[\(index)]", into: &mismatches)
            }
        case let object as [String: Any]:
            guard let values = actual as? [String: Any] else {
                mismatches.append(Mismatch(path: path, detail: "object expected, found \(actual)"))
                return
            }
            if Set(values.keys) != Set(object.keys) {
                mismatches.append(Mismatch(path: path, detail: "keys \(values.keys.sorted()) vs \(object.keys.sorted())"))
            }
            for (key, value) in object {
                if let other = values[key] { json(other, value, path: "\(path).\(key)", into: &mismatches) }
            }
        default:
            mismatches.append(Mismatch(path: path, detail: "unhandled \(expected)"))
        }
    }

    static func csv(_ actual: String, _ expected: String, name: String, into mismatches: inout [Mismatch]) {
        let a = parse(actual)
        let e = parse(expected)
        guard a.count == e.count else {
            mismatches.append(Mismatch(path: name, detail: "\(a.count) rows vs \(e.count)"))
            return
        }
        for (row, pair) in zip(a, e).enumerated() {
            guard pair.0.count == pair.1.count else {
                mismatches.append(Mismatch(path: "\(name) row \(row)", detail: "\(pair.0.count) cells vs \(pair.1.count)"))
                continue
            }
            for (column, cells) in zip(pair.0, pair.1).enumerated() where !cell(cells.0, cells.1) {
                let header = e.first?[column] ?? "\(column)"
                mismatches.append(Mismatch(path: "\(name) row \(row) \(header)", detail: "\(cells.0) vs \(cells.1)"))
            }
        }
        if !expected.isEmpty && !actual.hasSuffix("\r\n") {
            mismatches.append(Mismatch(path: name, detail: "missing CRLF line ending"))
        }
    }

    private static func cell(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if let x = Double(a), let y = Double(b) { return close(x, y) }
        if a.hasPrefix("["), let x = try? JSONSerialization.jsonObject(with: Data(a.utf8)) as? [Double],
           let y = try? JSONSerialization.jsonObject(with: Data(b.utf8)) as? [Double], x.count == y.count {
            return zip(x, y).allSatisfy { close($0, $1) }
        }
        let x = a.split(separator: ";", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: ["'"])) }
        let y = b.split(separator: ";", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: ["'"])) }
        if x.count > 1, x.count == y.count, a.hasPrefix("'") == b.hasPrefix("'"),
           zip(x, y).allSatisfy({ $0 != nil && $1 != nil && close($0!, $1!) }) {
            return true
        }
        return false
    }

    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = Array(text.unicodeScalars).makeIterator()
        var pending: Unicode.Scalar?
        while let scalar = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if scalar == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.unicodeScalars.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
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
