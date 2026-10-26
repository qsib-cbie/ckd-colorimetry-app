import Foundation

public struct JSONError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public extension JSONValue {
    static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw JSONError(message: "Unexpected text after JSON value.") }
        return value
    }

    func prettyJSON(indent: Int = 2) -> String {
        var out = ""
        write(into: &out, level: 0, indent: indent)
        return out
    }

    private func write(into out: inout String, level: Int, indent: Int) {
        let pad = String(repeating: " ", count: (level + 1) * indent)
        let close = String(repeating: " ", count: level * indent)
        switch self {
        case .array(let values) where !values.isEmpty:
            out += "[\n"
            for (index, value) in values.enumerated() {
                out += pad
                value.write(into: &out, level: level + 1, indent: indent)
                out += index == values.count - 1 ? "\n" : ",\n"
            }
            out += close + "]"
        case .object(let pairs) where !pairs.isEmpty:
            out += "{\n"
            for (index, pair) in pairs.enumerated() {
                out += pad + PythonFormat.jsonString(pair.0) + ": "
                pair.1.write(into: &out, level: level + 1, indent: indent)
                out += index == pairs.count - 1 ? "\n" : ",\n"
            }
            out += close + "}"
        case .array:
            out += "[]"
        case .object:
            out += "{}"
        default:
            out += pythonJSON
        }
    }

    var objectPairs: [(String, JSONValue)]? {
        if case .object(let pairs) = self { return pairs }
        return nil
    }

    var arrayValues: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    func setting(_ key: String, _ value: JSONValue) -> JSONValue {
        guard var pairs = objectPairs else { return self }
        if let index = pairs.firstIndex(where: { $0.0 == key }) {
            pairs[index].1 = value
        } else {
            pairs.append((key, value))
        }
        return .object(pairs)
    }

    func removing(_ key: String) -> JSONValue {
        guard let pairs = objectPairs else { return self }
        return .object(pairs.filter { $0.0 != key })
    }
}

extension JSONValue: Equatable {
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func value() throws -> JSONValue {
        guard index < bytes.count else { throw JSONError(message: "Unexpected end of JSON.") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return try number()
        }
    }

    mutating func literal(_ text: String) throws {
        let expected = Array(text.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
            throw JSONError(message: "Invalid JSON literal.")
        }
        index += expected.count
    }

    mutating func object() throws -> JSONValue {
        index += 1
        var pairs: [(String, JSONValue)] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw JSONError(message: "Expected a key.") }
            let key = try string()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw JSONError(message: "Expected ':'.") }
            index += 1
            skipWhitespace()
            pairs.append((key, try value()))
            skipWhitespace()
            guard index < bytes.count else { throw JSONError(message: "Unterminated object.") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            throw JSONError(message: "Expected ',' or '}'.")
        }
    }

    mutating func array() throws -> JSONValue {
        index += 1
        var values: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(values) }
        while true {
            skipWhitespace()
            values.append(try value())
            skipWhitespace()
            guard index < bytes.count else { throw JSONError(message: "Unterminated array.") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(values) }
            throw JSONError(message: "Expected ',' or ']'.")
        }
    }

    mutating func string() throws -> String {
        index += 1
        var scalars = String.UnicodeScalarView()
        var raw: [UInt8] = []
        func flush() throws {
            guard !raw.isEmpty else { return }
            guard let text = String(bytes: raw, encoding: .utf8) else { throw JSONError(message: "Invalid UTF-8.") }
            scalars.append(contentsOf: text.unicodeScalars)
            raw.removeAll()
        }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\"") {
                try flush()
                return String(scalars)
            }
            guard byte == UInt8(ascii: "\\") else { raw.append(byte); continue }
            try flush()
            guard index < bytes.count else { break }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): scalars.append("\"")
            case UInt8(ascii: "\\"): scalars.append("\\")
            case UInt8(ascii: "/"): scalars.append("/")
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                var code = try hex4()
                if (0xD800...0xDBFF).contains(code), index + 1 < bytes.count,
                   bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                    index += 2
                    let low = try hex4()
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                }
                guard let scalar = Unicode.Scalar(code) else { throw JSONError(message: "Invalid escape.") }
                scalars.append(scalar)
            default:
                throw JSONError(message: "Invalid escape.")
            }
        }
        throw JSONError(message: "Unterminated string.")
    }

    mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let text = String(bytes: bytes[index..<index + 4], encoding: .ascii),
              let code = UInt32(text, radix: 16) else { throw JSONError(message: "Invalid unicode escape.") }
        index += 4
        return code
    }

    mutating func number() throws -> JSONValue {
        let start = index
        var isInteger = true
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                isInteger = false
            } else if !(byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") || (0x30...0x39).contains(byte)) {
                break
            }
            index += 1
        }
        guard let text = String(bytes: bytes[start..<index], encoding: .ascii), !text.isEmpty else {
            throw JSONError(message: "Invalid JSON value.")
        }
        if isInteger, let value = Int(text) { return .int(value) }
        guard let value = Double(text), value.isFinite else { throw JSONError(message: "Invalid number \(text).") }
        return .double(value)
    }
}
