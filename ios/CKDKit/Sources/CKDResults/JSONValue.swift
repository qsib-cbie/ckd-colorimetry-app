import Foundation

public enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func number(_ value: Double?) -> JSONValue {
        value.map(JSONValue.double) ?? .null
    }

    public static func text(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }

    public static func numbers(_ values: [Double]?) -> JSONValue {
        values.map { .array($0.map(JSONValue.double)) } ?? .null
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }

    public var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationObject)
        case .object(let pairs):
            return Dictionary(pairs.map { ($0.0, $0.1.foundationObject) }, uniquingKeysWith: { _, last in last })
        }
    }

    public var pythonJSON: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return PythonFormat.float(value)
        case .string(let value): return PythonFormat.jsonString(value)
        case .array(let values): return "[" + values.map(\.pythonJSON).joined(separator: ", ") + "]"
        case .object(let pairs):
            return "{" + pairs.map { PythonFormat.jsonString($0.0) + ": " + $0.1.pythonJSON }.joined(separator: ", ") + "}"
        }
    }
}
