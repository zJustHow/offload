import Foundation

/// Keeps an agent's conversation inside the model's context window.
///
/// The old approach blanked the middle of the conversation with "[earlier step omitted]", so the
/// model lost what it had already tried and repeated itself. This replaces the older steps with a
/// short, deterministic digest (what was done and what came back) folded into the task message, and
/// keeps the most recent steps verbatim. No model call: a small local model is the one that runs
/// out of room, and it is the one worst placed to summarize.
///
/// Shape of the conversation: `[system, task, (assistant, observation)*]`. Steps are only ever
/// removed as whole pairs, so every native tool call keeps its result.
public enum HistoryCompactor {
    static let marker = "[Earlier steps, summarized to save space]"
    static let maxDigestCharacters = 1_800

    public static func size(of message: ChatMessage) -> Int {
        message.text.count
            + message.toolResults.reduce(0) { $0 + $1.text.count }
            + message.toolCalls.reduce(0) { $0 + JSONValue.object($1.arguments).jsonText.count }
    }

    public static func size(of messages: [ChatMessage]) -> Int { messages.reduce(0) { $0 + size(of: $1) } }

    /// `messages` unchanged while it fits `budget` characters.
    public static func compact(_ messages: [ChatMessage], budget: Int, preserveRecent: Int = 4) -> [ChatMessage] {
        guard size(of: messages) > budget, messages.count > 2 + preserveRecent else { return fit(messages, budget: budget) }

        var keepFrom = max(2, messages.count - preserveRecent)
        if messages[keepFrom].role != .assistant { keepFrom -= 1 }          // never split a pair
        guard keepFrom > 2 else { return fit(messages, budget: budget) }

        let older = Array(messages[2..<keepFrom])
        var task = messages[1]
        let previous = split(task.text)
        task.text = previous.base + "\n\n" + marker + "\n" + cap(previous.lines + digest(older), alreadyDropped: previous.dropped).joined(separator: "\n")
        // Rewriting history breaks the signature of every thinking block after the rewrite, and a provider
        // that enforces it rejects the request. Dropping them all once, at this boundary, is what it asks for.
        return fit(withoutProviderBlocks([messages[0], task] + Array(messages[keepFrom...])), budget: budget)
    }

    static func withoutProviderBlocks(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { var m = $0; m.providerBlocks = []; return m }
    }

    // MARK: Digest

    static func digest(_ older: [ChatMessage]) -> [String] {
        var lines: [String] = []
        var i = 0
        while i < older.count {
            let m = older[i]
            guard m.role == .assistant else { i += 1; continue }
            let result = i + 1 < older.count ? older[i + 1] : nil
            let calls = describeCalls(m)
            let observations = describeObservations(result)
            for (n, call) in calls.enumerated() {
                let outcome = n < observations.count ? observations[n] : ""
                lines.append("- " + call + (outcome.isEmpty ? "" : " → " + outcome))
            }
            i += 2
        }
        return lines
    }

    private static func describeCalls(_ m: ChatMessage) -> [String] {
        if !m.toolCalls.isEmpty { return m.toolCalls.map { "\($0.name)(\($0.arguments.summary(limit: 50)))" } }
        if let action = Agent.parseAction(m.text) { return ["\(action.tool)(\(action.args.summary(limit: 50)))"] }
        return [oneLine(m.text, 60)]
    }

    private static func describeObservations(_ m: ChatMessage?) -> [String] {
        guard let m else { return [] }
        if !m.toolResults.isEmpty { return m.toolResults.map { (r: ToolResultBlock) in (r.isError ? "error: " : "") + oneLine(r.text, 100) } }
        var text = m.text
        if text.hasPrefix("Observation: ") { text.removeFirst("Observation: ".count) }
        return [oneLine(text, 100)]
    }

    private static func oneLine(_ s: String, _ limit: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// Drops the oldest lines until the digest fits, and says how many were dropped.
    private static func cap(_ lines: [String], alreadyDropped: Int) -> [String] {
        var kept = lines
        var dropped = alreadyDropped
        while kept.reduce(0, { $0 + $1.count + 1 }) > maxDigestCharacters, kept.count > 1 { kept.removeFirst(); dropped += 1 }
        return dropped > 0 ? ["(\(dropped) earlier steps not listed)"] + kept : kept
    }

    /// The task text without a previous digest, that digest's lines, and how many steps it already omitted.
    private static func split(_ text: String) -> (base: String, lines: [String], dropped: Int) {
        guard let range = text.range(of: "\n\n" + marker + "\n") else { return (text, [], 0) }
        var lines = text[range.upperBound...].components(separatedBy: "\n").filter { !$0.isEmpty }
        var dropped = 0
        if let first = lines.first, first.hasPrefix("("), first.hasSuffix("earlier steps not listed)") {
            dropped = Int(first.dropFirst().prefix(while: { $0.isNumber })) ?? 0
            lines.removeFirst()
        }
        return (String(text[..<range.lowerBound]), lines, dropped)
    }

    // MARK: Last resort

    /// When even the recent steps do not fit, shorten their text (never the task or the system prompt).
    private static func fit(_ messages: [ChatMessage], budget: Int) -> [ChatMessage] {
        guard size(of: messages) > budget, messages.count > 2 else { return messages }
        var out = withoutProviderBlocks(messages)
        let share = max(300, budget / max(1, out.count))
        for i in 2..<out.count {
            if out[i].text.count > share { out[i].text = String(out[i].text.prefix(share)) + "…[shortened]" }
            out[i].toolResults = out[i].toolResults.map { r in
                var r = r
                if r.text.count > share { r.text = String(r.text.prefix(share)) + "…[shortened]" }
                if i < out.count - 1 { r.images = [] }
                return r
            }
            if i < out.count - 1 { out[i].images = [] }
        }
        return out
    }
}
