import Foundation

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var int: Int? {
        if case .number(let value) = self, value.rounded() == value, value <= Double(Int.max), value >= Double(Int.min) {
            return Int(value)
        }
        return nil
    }

    public var double: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public subscript(_ key: String) -> JSONValue? {
        object?[key]
    }

    public static func parse(_ text: String) -> JSONValue? {
        var parser = JSONParser(text)
        guard let value = parser.parseValue() else { return nil }
        parser.skipWhitespace()
        return parser.finished ? value : nil
    }

    public func compactJSON() -> String {
        Self.encode(self)
    }

    private static func encode(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            return encodeNumber(number)
        case .string(let string):
            return "\"" + escape(string) + "\""
        case .array(let array):
            return "[" + array.map(encode).joined(separator: ",") + "]"
        case .object(let object):
            let pairs = object.keys.sorted().map { key in
                "\"" + escape(key) + "\":" + encode(object[key] ?? .null)
            }
            return "{" + pairs.joined(separator: ",") + "}"
        }
    }

    private static func encodeNumber(_ number: Double) -> String {
        guard number.isFinite else { return "0" }
        if number.rounded() == number, abs(number) < 1e15 {
            return String(Int(number))
        }
        var text = String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), number)
        if text.contains(",") { text = text.replacingOccurrences(of: ",", with: ".") }
        return text
    }

    /// Escapes `--` so a value cannot close an HTML comment early.
    private static func escape(_ string: String) -> String {
        var out = ""
        var previousDash = false
        for scalar in string.unicodeScalars {
            if previousDash && scalar == "-" {
                out.removeLast()
                out += "\\u002d\\u002d"
                previousDash = false
                continue
            }
            previousDash = scalar == "-"
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\u{c}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}

/// Locale-independent JSON parser. Foundation's JSONSerialization turns numbers
/// and booleans into NSNumber, and on Linux those are easy to mix up.
private struct JSONParser {
    private let text: String
    private var index: String.Index
    private var start: String.Index { text.startIndex }

    init(_ text: String) {
        self.text = text
        self.index = text.startIndex
    }

    var finished: Bool { index == text.endIndex }

    mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        guard index < text.endIndex else { return nil }
        switch text[index] {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"": return parseString().map(JSONValue.string)
        case "t": return consume("true") ? .bool(true) : nil
        case "f": return consume("false") ? .bool(false) : nil
        case "n": return consume("null") ? .null : nil
        default: return parseNumber()
        }
    }

    mutating func skipWhitespace() {
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
    }

    private mutating func parseObject() -> JSONValue? {
        guard consume("{") else { return nil }
        var object: [String: JSONValue] = [:]
        skipWhitespace()
        if consume("}") { return .object(object) }
        while index < text.endIndex {
            skipWhitespace()
            guard let key = parseString() else { return nil }
            skipWhitespace()
            guard consume(":") else { return nil }
            guard let value = parseValue() else { return nil }
            object[key] = value
            skipWhitespace()
            if consume("}") { return .object(object) }
            guard consume(",") else { return nil }
        }
        return nil
    }

    private mutating func parseArray() -> JSONValue? {
        guard consume("[") else { return nil }
        var array: [JSONValue] = []
        skipWhitespace()
        if consume("]") { return .array(array) }
        while index < text.endIndex {
            guard let value = parseValue() else { return nil }
            array.append(value)
            skipWhitespace()
            if consume("]") { return .array(array) }
            guard consume(",") else { return nil }
        }
        return nil
    }

    private mutating func parseString() -> String? {
        guard consume("\"") else { return nil }
        var output = ""
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if character == "\"" { return output }
            if character == "\\" {
                guard index < text.endIndex else { return nil }
                let escaped = text[index]
                index = text.index(after: index)
                switch escaped {
                case "\"": output.append("\"")
                case "\\": output.append("\\")
                case "/": output.append("/")
                case "b": output.append("\u{8}")
                case "f": output.append("\u{c}")
                case "n": output.append("\n")
                case "r": output.append("\r")
                case "t": output.append("\t")
                case "u":
                    guard let scalar = parseHexScalar() else { return nil }
                    output.unicodeScalars.append(scalar)
                default: return nil
                }
            } else {
                output.append(character)
            }
        }
        return nil
    }

    private mutating func parseHexScalar() -> Unicode.Scalar? {
        guard let end = text.index(index, offsetBy: 4, limitedBy: text.endIndex) else { return nil }
        let hex = String(text[index..<end])
        index = end
        guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
        return scalar
    }

    private mutating func parseNumber() -> JSONValue? {
        let begin = index
        if consume("-"), index == text.endIndex { return nil }
        while index < text.endIndex, text[index].isNumber { index = text.index(after: index) }
        if index < text.endIndex, text[index] == "." {
            index = text.index(after: index)
            while index < text.endIndex, text[index].isNumber { index = text.index(after: index) }
        }
        if index < text.endIndex, text[index] == "e" || text[index] == "E" {
            index = text.index(after: index)
            if index < text.endIndex, text[index] == "+" || text[index] == "-" { index = text.index(after: index) }
            while index < text.endIndex, text[index].isNumber { index = text.index(after: index) }
        }
        guard begin < index, let number = Double(String(text[begin..<index])) else { return nil }
        return .number(number)
    }

    private mutating func consume(_ token: String) -> Bool {
        guard text[index...].hasPrefix(token) else { return false }
        index = text.index(index, offsetBy: token.count)
        return true
    }
}

public enum ReaderComment {
    public static func parse(line: String) -> JSONValue? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->") else { return nil }
        var inner = trimmed.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("reader") else { return nil }
        inner = inner.dropFirst("reader".count).trimmingCharacters(in: .whitespaces)
        return JSONValue.parse(String(inner))
    }

    public static func render(_ value: JSONValue) -> String {
        "<!-- reader \(value.compactJSON()) -->"
    }
}
