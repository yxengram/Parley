import Foundation

// A JSON value that is Sendable and Hashable, for what travels through the MCP layer and for tool
// schemas: `[String: Any]` is neither, and a tool's schema has to survive unchanged.

public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Nesting past this is refused: the parsers recurse, and servers run on 512 KiB stacks here. A
    /// real schema or tool result is nowhere near it, and llama.cpp stops at the same depth.
    public static let maxDepth = 128

    /// From what JSONSerialization produces. Nil for anything else, for a number JSON cannot write
    /// back (`-1e999` parses to infinity, and writing that raises an exception no `try?` catches),
    /// and past `maxDepth`.
    public init?(any: Any?) {
        self.init(any: any, depth: 0)
    }

    private init?(any: Any?, depth: Int) {
        guard depth <= Self.maxDepth else { return nil }
        switch any {
        case nil, is NSNull:
            self = .null
        case let number as NSNumber:
            // NSNumber also bridges Bool, so tell them apart first (a schema's `true` and `1` differ).
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if !CFNumberIsFloatType(number), NSNumber(value: number.int64Value).compare(number) == .orderedSame {
                self = .int(number.int64Value)
            } else {
                // Above Int64 too: approximate, where int64Value would wrap to another number.
                guard number.doubleValue.isFinite else { return nil }
                self = .double(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var out: [JSONValue] = []
            out.reserveCapacity(array.count)
            for item in array {
                guard let value = JSONValue(any: item, depth: depth + 1) else { return nil }
                out.append(value)
            }
            self = .array(out)
        case let dict as [String: Any]:
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(dict.count)
            for (key, item) in dict {
                guard let value = JSONValue(any: item, depth: depth + 1) else { return nil }
                out[key] = value
            }
            self = .object(out)
        default:
            return nil
        }
    }

    public init?(jsonText: String) {
        self.init(jsonData: Data(jsonText.utf8))
    }

    public init?(jsonData: Data) {
        guard let parsed = Self.parsed(jsonData, options: [.fragmentsAllowed]) else { return nil }
        self.init(any: parsed)
    }

    /// JSONSerialization, for what came from a server. Its own limit is 512 levels, and a thread here
    /// has a 512 KiB stack: one short line nested that deep can kill the app, so depth is checked first.
    static func parsed(_ data: Data, options: JSONSerialization.ReadingOptions = []) -> Any? {
        guard !nestsTooDeep(data) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: options)
    }

    /// JSON this type refuses (too deep, or a number it cannot write back), as opposed to no JSON.
    static func isOutOfRange(_ data: Data) -> Bool {
        if nestsTooDeep(data) { return true }
        return JSONValue(jsonData: data) == nil
            && (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    /// Whether `data` opens more than `maxDepth` arrays and objects at once. Skips strings.
    static func nestsTooDeep(_ data: Data) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }
            switch byte {
            case 0x22:
                inString = true
            case 0x5B, 0x7B:
                depth += 1
                if depth > maxDepth { return true }
            case 0x5D, 0x7D:
                depth -= 1
            default:
                break
            }
        }
        return false
    }

    /// What JSONSerialization can write. A number it cannot becomes null rather than an exception;
    /// nothing parsed gets here with one, but `.double` is public.
    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return NSNumber(value: i)
        case .double(let d): return d.isFinite ? d : NSNull()
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    /// Compact JSON with sorted keys, so equal values have equal text (fingerprints, prompt caches).
    public var sortedJSONData: Data {
        (try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
    }

    public var sortedJSONText: String { String(decoding: sortedJSONData, as: UTF8.self) }

    /// For reading: indented, keys sorted.
    public var prettyJSONText: String {
        let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? sortedJSONText
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 9.0e15: return Int64(d)
        default: return nil
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// The member `key` of an object. Nil for other values, and for an absent key.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}
