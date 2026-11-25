import Foundation

public enum HTMLText {
    /// Visible text of an HTML document: scripts and styles dropped, tags removed, entities and
    /// whitespace tidied. Not a renderer; good enough to read mail and saved web pages.
    public static func strip(_ html: String) -> String {
        var s = html
        for tag in ["script", "style"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, ch) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            s = s.replacingOccurrences(of: entity, with: ch)
        }
        return s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
    }
}
