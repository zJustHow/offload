import Foundation

/// Models wrap JSON in prose and code fences, or leave trailing commentary. These helpers pull the
/// first well-formed JSON value out of such text without trusting the surrounding words.
public enum JSONExtract {
    /// First balanced `{...}` object in `text` (string- and escape-aware), parsed.
    public static func firstObject(in text: String) -> [String: Any]? {
        guard let slice = firstBalanced(in: text, open: "{", close: "}"),
            let data = slice.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func firstBalanced(in text: String, open: Character, close: Character) -> String? {
        let chars = Array(text)
        var start = 0
        while start < chars.count {
            guard let s = chars[start...].firstIndex(of: open) else { return nil }
            var depth = 0, inString = false, escaped = false
            var i = s
            while i < chars.count {
                let c = chars[i]
                if inString {
                    if escaped { escaped = false }
                    else if c == "\\" { escaped = true }
                    else if c == "\"" { inString = false }
                } else if c == "\"" { inString = true }
                else if c == open { depth += 1 }
                else if c == close {
                    depth -= 1
                    if depth == 0 {
                        let candidate = String(chars[s...i])
                        if let d = candidate.data(using: .utf8), (try? JSONSerialization.jsonObject(with: d)) != nil { return candidate }
                        break  // balanced but invalid JSON: look for the next opener
                    }
                }
                i += 1
            }
            start = s + 1
        }
        return nil
    }
}
