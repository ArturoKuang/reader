import Foundation
import ReaderCore

enum JSONSupport {
    static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: sanitize(object), options: [])
    }

    static func object(from data: Data) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw SyncAPIError(status: 0, code: "bad_request", message: "expected a JSON object")
        }
        return object
    }

    static func array(from data: Data) throws -> [Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let array = value as? [Any] else {
            throw SyncAPIError(status: 0, code: "bad_request", message: "expected a JSON array")
        }
        return array
    }

    static func any(from value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let flag): return flag
        case .number(let number): return number
        case .string(let string): return string
        case .array(let items): return items.map(any(from:))
        case .object(let object):
            return Dictionary(uniqueKeysWithValues: object.map { ($0.key, any(from: $0.value)) })
        }
    }

    static func jsonValue(from any: Any) -> JSONValue {
        switch any {
        case is NSNull: return .null
        case let flag as Bool: return .bool(flag)
        case let number as Int: return .number(Double(number))
        case let number as Double: return .number(number)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let string as String: return .string(string)
        case let items as [Any]: return .array(items.map(jsonValue(from:)))
        case let object as [String: Any]:
            return .object(object.mapValues(jsonValue(from:)))
        default:
            return .string(String(describing: any))
        }
    }

    static func extras(from object: [String: Any]) -> [String: JSONValue] {
        guard let raw = object["extras"] else { return [:] }
        if let dict = raw as? [String: Any] {
            return dict.mapValues(jsonValue(from:))
        }
        return [:]
    }

    static func int(_ object: [String: Any], _ key: String) -> Int? {
        if let value = object[key] as? Int { return value }
        if let value = object[key] as? NSNumber { return value.intValue }
        if let value = object[key] as? String { return Int(value) }
        return nil
    }

    static func double(_ object: [String: Any], _ key: String) -> Double? {
        if let value = object[key] as? Double { return value }
        if let value = object[key] as? Int { return Double(value) }
        if let value = object[key] as? NSNumber { return value.doubleValue }
        return nil
    }

    static func string(_ object: [String: Any], _ key: String) -> String? {
        if object[key] is NSNull { return nil }
        return object[key] as? String
    }

    static func bool(_ object: [String: Any], _ key: String) -> Bool? {
        if let value = object[key] as? Bool { return value }
        if let value = object[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() {
            return value.boolValue
        }
        return nil
    }

    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]:
            return object.mapValues(sanitize)
        case let items as [Any]:
            return items.map(sanitize)
        case let number as Double where number.rounded() == number && number >= Double(Int.min) && number <= Double(Int.max):
            return Int(number)
        default:
            return value
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { JSONSupport.string(self, key) }
    func int(_ key: String) -> Int? { JSONSupport.int(self, key) }
    func bool(_ key: String) -> Bool? { JSONSupport.bool(self, key) }
}
