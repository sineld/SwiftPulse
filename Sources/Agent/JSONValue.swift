import Foundation

/// A JSON document of any shape. The MCP server reads and writes its JSON-RPC messages with it.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Coding

extension JSONValue: Codable {
    private struct MemberKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Integers up to 2^53 are exact in a Double; those are written without a fraction (`3`, not `3.0`).
    private static let largestExactInteger = 9_007_199_254_740_992.0

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: MemberKey.self) {
            var members: [String: JSONValue] = [:]
            for key in keyed.allKeys { members[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key) }
            self = .object(members)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var elements: [JSONValue] = []
            while !unkeyed.isAtEnd { elements.append(try unkeyed.decode(JSONValue.self)) }
            self = .array(elements)
            return
        }
        let scalar = try decoder.singleValueContainer()
        if scalar.decodeNil() {
            self = .null
        } else if let flag = try? scalar.decode(Bool.self) {
            self = .bool(flag)
        } else if let value = try? scalar.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try scalar.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .object(members):
            var keyed = encoder.container(keyedBy: MemberKey.self)
            for (name, member) in members { try keyed.encode(member, forKey: MemberKey(stringValue: name)) }
        case let .array(elements):
            var unkeyed = encoder.unkeyedContainer()
            for element in elements { try unkeyed.encode(element) }
        case .null:
            var scalar = encoder.singleValueContainer()
            try scalar.encodeNil()
        case let .bool(flag):
            var scalar = encoder.singleValueContainer()
            try scalar.encode(flag)
        case let .string(text):
            var scalar = encoder.singleValueContainer()
            try scalar.encode(text)
        case let .number(value):
            var scalar = encoder.singleValueContainer()
            if let whole = Self.exactInteger(value) { try scalar.encode(whole) } else { try scalar.encode(value) }
        }
    }

    private static func exactInteger(_ value: Double) -> Int64? {
        abs(value) <= largestExactInteger ? Int64(exactly: value) : nil
    }
}

// MARK: - Reading values

extension JSONValue {
    /// The member named `key` of an object; nil for anything else.
    subscript(key: String) -> JSONValue? {
        guard case let .object(members) = self else { return nil }
        return members[key]
    }

    /// Strings as they are; numbers as text, whole numbers without a fraction.
    var string: String? {
        switch self {
        case let .string(text):
            return text
        case let .number(value):
            if let whole = Self.exactInteger(value) { return String(whole) }
            return String(value)
        default:
            return nil
        }
    }

    /// Numbers (the fraction dropped) and strings that hold an integer.
    var int: Int? {
        switch self {
        case let .number(value):
            return Int(exactly: value.rounded(.towardZero))
        case let .string(text):
            return Int(text)
        default:
            return nil
        }
    }

    var bool: Bool? {
        guard case let .bool(flag) = self else { return nil }
        return flag
    }

    var array: [JSONValue]? {
        guard case let .array(elements) = self else { return nil }
        return elements
    }

    /// An array's string elements, or a single string as a one-element list.
    var strings: [String] {
        guard let elements = array else { return string.map { [$0] } ?? [] }
        return elements.compactMap(\.string)
    }
}

// MARK: - Converting

extension JSONValue {
    /// Round-trips any Encodable value through JSON, with dates as ISO 8601 strings; `.null` if that fails.
    static func from<T: Encodable>(_ value: T) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
        } catch {
            return .null
        }
    }

    /// The value as JSON text with sorted keys, so the same value always gives the same text.
    func encodedString(pretty: Bool = false) -> String {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    /// A repeated key keeps its first value.
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        var members: [String: JSONValue] = [:]
        for (name, value) in elements where members[name] == nil { members[name] = value }
        self = .object(members)
    }
}
