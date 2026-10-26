import Foundation

public enum PythonFormat {
    public static func float(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        if value == 0 { return value.sign == .minus ? "-0.0" : "0.0" }
        let sign = value < 0 ? "-" : ""
        let (digits, decimalPoint) = shortestDigits(abs(value))
        if decimalPoint <= -4 || decimalPoint > 16 {
            let exponent = decimalPoint - 1
            let head = String(digits.prefix(1))
            let tail = String(digits.dropFirst())
            let mantissa = tail.isEmpty ? head : head + "." + tail
            return sign + mantissa + "e" + (exponent < 0 ? "-" : "+") + String(format: "%02d", abs(exponent))
        }
        if decimalPoint <= 0 {
            return sign + "0." + String(repeating: "0", count: -decimalPoint) + digits
        }
        if decimalPoint >= digits.count {
            return sign + digits + String(repeating: "0", count: decimalPoint - digits.count) + ".0"
        }
        let split = digits.index(digits.startIndex, offsetBy: decimalPoint)
        return sign + digits[..<split] + "." + digits[split...]
    }

    public static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value > 0x7E {
                    if scalar.value > 0xFFFF {
                        let offset = scalar.value - 0x10000
                        out += String(format: "\\u%04x\\u%04x", 0xD800 + (offset >> 10), 0xDC00 + (offset & 0x3FF))
                    } else {
                        out += String(format: "\\u%04x", scalar.value)
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func shortestDigits(_ value: Double) -> (String, Int) {
        let description = "\(value)"
        var mantissa = Substring(description)
        var exponent = 0
        if let marker = description.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = description[..<marker]
            exponent = Int(description[description.index(after: marker)...]) ?? 0
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts[0])
        var digits = whole + (parts.count > 1 ? String(parts[1]) : "")
        var decimalPoint = whole.count + exponent
        while digits.count > 1 && digits.hasPrefix("0") {
            digits.removeFirst()
            decimalPoint -= 1
        }
        while digits.count > 1 && digits.hasSuffix("0") {
            digits.removeLast()
        }
        return (digits, decimalPoint)
    }
}

public enum CSVCell: Sendable {
    case empty
    case int(Int)
    case double(Double)
    case text(String)
    case json(JSONValue)

    public static func number(_ value: Double?) -> CSVCell {
        value.map(CSVCell.double) ?? .empty
    }

    public static func whole(_ value: Int?) -> CSVCell {
        value.map(CSVCell.int) ?? .empty
    }

    public static func string(_ value: String?) -> CSVCell {
        value.map(CSVCell.text) ?? .empty
    }

    var rendered: String {
        switch self {
        case .empty: return ""
        case .int(let value): return String(value)
        case .double(let value): return PythonFormat.float(value)
        case .json(let value): return value.pythonJSON
        case .text(let value):
            let trimmed = value.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\u{0B}" || $0 == "\u{0C}" }
            if let first = trimmed.first, "=+-@".contains(first) {
                return "'" + value
            }
            return value
        }
    }
}

public enum CSVText {
    public static func make(fields: [String], rows: [[CSVCell]]) -> String {
        var out = line(fields)
        for row in rows {
            out += line(row.map(\.rendered))
        }
        return out
    }

    private static func line(_ cells: [String]) -> String {
        cells.map(quoted).joined(separator: ",") + "\r\n"
    }

    private static func quoted(_ cell: String) -> String {
        guard cell.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" || $0 == "\r\n" }) else {
            return cell
        }
        return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
