import Foundation

/// Small builders for the JSON Schema objects that describe a tool's input, so a tool definition
/// reads as a declaration instead of nested dictionary literals.
public enum JSONSchema {
    public static func object(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        var o: JSONObject = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        o["additionalProperties"] = false
        return .object(o)
    }

    public static func string(_ description: String? = nil, enum values: [String]? = nil) -> JSONValue {
        var o: JSONObject = ["type": "string"]
        if let description { o["description"] = .string(description) }
        if let values { o["enum"] = .array(values.map { .string($0) }) }
        return .object(o)
    }

    public static func integer(_ description: String? = nil, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var o: JSONObject = ["type": "integer"]
        if let description { o["description"] = .string(description) }
        if let minimum { o["minimum"] = .int(minimum) }
        if let maximum { o["maximum"] = .int(maximum) }
        return .object(o)
    }

    public static func boolean(_ description: String? = nil) -> JSONValue {
        var o: JSONObject = ["type": "boolean"]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }

    public static func array(of items: JSONValue, _ description: String? = nil) -> JSONValue {
        var o: JSONObject = ["type": "array", "items": items]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }

    /// An empty parameter list.
    public static let none: JSONValue = object()
}

/// Models are loose about argument types. `coerce` repairs what can be repaired unambiguously
/// (`"10"` for an integer, `"true"` for a boolean, a JSON array sent as a string, a lone string
/// for a list of strings); `validate` then reports what is still wrong, in words a model can act on.
public enum SchemaCheck {
    public static func coerce(_ arguments: JSONObject, to schema: JSONValue) -> JSONObject {
        guard let properties = schema["properties"]?.asObject else { return arguments }
        var out = arguments
        for (key, value) in arguments {
            guard let property = properties[key] else { continue }
            out[key] = coerce(value, to: property)
        }
        return out
    }

    static func coerce(_ value: JSONValue, to schema: JSONValue) -> JSONValue {
        guard let type = schema["type"]?.asString else { return value }
        switch (type, value) {
        case ("integer", .string), ("integer", .double): return value.asInt.map { .int($0) } ?? value
        case ("number", .string): return value.asDouble.map { .double($0) } ?? value
        case ("boolean", .string), ("boolean", .int): return value.asBool.map { .bool($0) } ?? value
        case ("string", .int), ("string", .double), ("string", .bool): return value.asString.map { .string($0) } ?? value
        case ("array", .string(let s)):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("["), let parsed = JSONValue(jsonText: trimmed), case .array = parsed { return parsed }
            return trimmed.isEmpty ? .array([]) : .array([.string(s)])
        case ("array", .array(let items)):
            guard let itemSchema = schema["items"] else { return value }
            return .array(items.map { coerce($0, to: itemSchema) })
        case ("object", .string(let s)):
            if let parsed = JSONValue(jsonText: s), case .object = parsed { return parsed }
            return value
        case ("object", .object(let o)):
            return .object(coerce(o, to: schema))
        default: return value
        }
    }

    /// Problems with `arguments` against `schema`, empty when it is acceptable. Unknown properties
    /// are ignored: models add them, and a harmless extra is not worth a failed step.
    public static func validate(_ arguments: JSONObject, against schema: JSONValue) -> [String] {
        var problems: [String] = []
        let required = schema["required"]?.asArray?.compactMap(\.asString) ?? []
        for name in required where arguments[name] == nil || arguments[name]!.isNull {
            problems.append("\(name) is required")
        }
        for (key, property) in schema["properties"]?.asObject ?? [:] {
            guard let value = arguments[key], !value.isNull else { continue }
            problems += check(value, against: property, path: key)
        }
        return problems
    }

    private static func check(_ value: JSONValue, against schema: JSONValue, path: String) -> [String] {
        var problems: [String] = []
        if let type = schema["type"]?.asString {
            let ok: Bool
            switch (type, value) {
            case ("string", .string), ("integer", .int), ("number", .int), ("number", .double),
                ("boolean", .bool), ("array", .array), ("object", .object): ok = true
            case ("integer", .double(let d)): ok = d == d.rounded()
            default: ok = false
            }
            if !ok { return ["\(path) must be a \(type)"] }
        }
        if let allowed = schema["enum"]?.asArray, !allowed.contains(value) {
            problems.append("\(path) must be one of: " + allowed.compactMap(\.asString).joined(separator: ", "))
        }
        switch value {
        case .int, .double:
            let n = value.asDouble ?? 0
            if let min = schema["minimum"]?.asDouble, n < min { problems.append("\(path) must be at least \(schema["minimum"]?.asString ?? "")") }
            if let max = schema["maximum"]?.asDouble, n > max { problems.append("\(path) must be at most \(schema["maximum"]?.asString ?? "")") }
        default: break
        }
        if case .array(let items) = value, let itemSchema = schema["items"] {
            for (i, item) in items.enumerated() { problems += check(item, against: itemSchema, path: "\(path)[\(i)]") }
        }
        return problems
    }
}
