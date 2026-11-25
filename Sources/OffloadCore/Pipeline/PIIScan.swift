import Foundation

public enum PIIKind: String, Sendable, Hashable {
    case usSSN = "ssn"
    case cardNumber = "card"
    case chineseID = "cn-id"
    case passport = "passport"
    case secretKey = "secret"
    case bankAccount = "account"
    case password = "password"
}

/// Deterministic backstop behind the language model: a small on-device model will sometimes let an
/// identifier through, and a regex does not get tired. Tuned to prefer over-redaction — a lost
/// digit string costs little; a leaked card number costs a lot.
///
/// Two uses: `findings` decides whether a *summary* must be dropped (summaries are meant to carry
/// no raw identifiers at all), and `redact` scrubs *raw text* before it is indexed for retrieval,
/// where the surrounding context is still valuable.
public enum PIIScan {
    private struct Rule {
        let kind: PIIKind
        let regex: NSRegularExpression
        let validate: (String) -> Bool
    }

    private static func rx(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    // The label-prefixed rules skip the "account" / "passport" inside our own `[REDACTED:...]`
    // placeholders, so scanning already-redacted text again never eats what follows a placeholder.
    private static let rules: [Rule] = [
        Rule(kind: .usSSN, regex: rx(#"\b(\d{3})[- ](\d{2})[- ](\d{4})\b"#), validate: { m in
            let d = m.filter(\.isNumber)
            guard d.count == 9 else { return false }
            let area = Int(d.prefix(3))!, group = Int(d.dropFirst(3).prefix(2))!, serial = Int(d.suffix(4))!
            return area != 0 && area != 666 && area < 900 && group != 0 && serial != 0
        }),
        Rule(kind: .cardNumber, regex: rx(#"\b(?:\d[ -]?){13,19}\b"#), validate: { m in
            let d = m.filter(\.isNumber)
            return (13...19).contains(d.count) && luhn(d)
        }),
        Rule(kind: .chineseID, regex: rx(#"\b[1-9]\d{5}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dX]\b"#), validate: { chineseIDChecksum($0) }),
        Rule(kind: .passport, regex: rx(#"(?<!REDACTED:)(?:passport|护照)[^\n]{0,24}?\b((?=[A-Z0-9]*\d)[A-Z0-9]{6,9})\b"#), validate: { _ in true }),
        Rule(kind: .secretKey, regex: rx(#"\b(?:sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30,}|xox[abp]-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,})\b"#, []), validate: { _ in true }),
        Rule(kind: .bankAccount, regex: rx(#"(?<!REDACTED:)(?:account|acct|iban|routing|银行卡|账号|账户)[^\n]{0,20}?(\d[\d -]{7,30}\d)"#), validate: { m in m.filter(\.isNumber).count >= 8 }),
        Rule(kind: .password, regex: rx(#"(?:password|passwd|pwd|密码)\s*[:：=]\s*\S{4,}"#), validate: { _ in true }),
    ]

    public static func findings(in text: String) -> Set<PIIKind> {
        var found = Set<PIIKind>()
        let ns = text as NSString
        for rule in rules {
            for m in rule.regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if rule.validate(ns.substring(with: m.range)) { found.insert(rule.kind); break }
            }
        }
        return found
    }

    public static func containsHighRiskPII(_ text: String) -> Bool { !findings(in: text).isEmpty }

    /// Replaces every validated match with `[REDACTED:<kind>]`.
    public static func redact(_ text: String) -> (text: String, kinds: Set<PIIKind>) {
        var out = text
        var kinds = Set<PIIKind>()
        for rule in rules {
            let ns = out as NSString
            let matches = rule.regex.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed()
            var mutable = out
            for m in matches {
                let matched = ns.substring(with: m.range)
                guard rule.validate(matched) else { continue }
                // For label-prefixed patterns keep the label and redact only the value.
                var range = m.range
                if m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound, rule.kind == .passport || rule.kind == .bankAccount {
                    range = m.range(at: 1)
                }
                mutable = (mutable as NSString).replacingCharacters(in: range, with: "[REDACTED:\(rule.kind.rawValue)]")
                kinds.insert(rule.kind)
            }
            out = mutable
        }
        return (out, kinds)
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    static func chineseIDChecksum(_ id: String) -> Bool {
        let chars = Array(id.uppercased())
        guard chars.count == 18 else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let codes = Array("10X98765432")
        var sum = 0
        for i in 0..<17 { guard let d = chars[i].wholeNumberValue else { return false }; sum += d * weights[i] }
        return codes[sum % 11] == chars[17]
    }
}
