import Foundation

/// A Sendable JSON value. Tool arguments used to be `[String: String]`, which cannot carry the
/// arrays and nested objects that MCP tools and native tool calling use; this can.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public typealias JSONObject = [String: JSONValue]

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

public extension JSONValue {
    /// From the output of `JSONSerialization` (or any Foundation property-list-like value).
    init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let v as JSONValue: self = v
        case let v as String: self = .string(v)
        case let v as [Any]: self = .array(v.map { JSONValue(any: $0) })
        case let v as [String: Any]: self = .object(v.mapValues { JSONValue(any: $0) })
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() { self = .bool(v.boolValue); return }
            switch String(cString: v.objCType) {
            case "d", "f": self = .double(v.doubleValue)
            default: self = .int(v.intValue)
            }
        case let v as Bool: self = .bool(v)
        case let v as Int: self = .int(v)
        case let v as Double: self = .double(v)
        default: self = .string("\(value!)")
        }
    }

    /// Foundation form, for `JSONSerialization`.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }

    /// Parses a JSON document (any top-level value).
    init?(jsonText: String) {
        guard let data = jsonText.data(using: .utf8),
            let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        self.init(any: any)
    }

    /// Compact, key-sorted JSON.
    var jsonText: String {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        guard let data = try? JSONSerialization.data(withJSONObject: anyValue, options: options) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Lenient accessors
    //
    // Models are loose about types: `"x": "10"`, `"x": 10` and `"x": 10.0` all mean the same thing,
    // and the old protocol accepted all three. These accessors keep that.

    /// A scalar as text; nil for null, arrays and objects.
    var asString: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var asInt: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return d.isFinite && abs(d) < 1e15 ? Int(d) : nil
        case .string(let s):
            if let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
            if let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite, abs(d) < 1e15 { return Int(d) }
            return nil
        default: return nil
        }
    }

    var asDouble: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    var asBool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s):
            switch s.lowercased() { case "true", "yes", "1": return true; case "false", "no", "0": return false; default: return nil }
        case .int(let i): return i == 0 ? false : (i == 1 ? true : nil)
        default: return nil
        }
    }

    var asArray: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    var asObject: JSONObject? { if case .object(let o) = self { return o } else { return nil } }
    var isNull: Bool { if case .null = self { return true } else { return false } }

    subscript(key: String) -> JSONValue? { asObject?[key] }

    /// This object with one key set; any other kind of value is returned as it is.
    func replacing(_ key: String, with value: JSONValue) -> JSONValue {
        guard case .object(var o) = self else { return self }
        o[key] = value
        return .object(o)
    }

    /// A one-line rendering for logs and confirmation text.
    func shortDescription(limit: Int = 80) -> String {
        let text: String
        switch self {
        case .string(let s): text = s
        case .array, .object: text = jsonText
        default: text = asString ?? "null"
        }
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > limit ? String(oneLine.prefix(limit)) + "…" : oneLine
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? { self[key]?.asString }
    func int(_ key: String) -> Int? { self[key]?.asInt }
    func bool(_ key: String) -> Bool? { self[key]?.asBool }
    func stringArray(_ key: String) -> [String]? { self[key]?.asArray?.compactMap(\.asString) }

    /// `key=value, key=value`, sorted, values shortened: how a call is shown to the user.
    func summary(limit: Int = 80) -> String {
        map { "\($0.key)=\($0.value.shortDescription(limit: limit))" }.sorted().joined(separator: ", ")
    }
}
