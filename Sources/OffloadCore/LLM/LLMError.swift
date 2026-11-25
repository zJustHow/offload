import Foundation

public enum LLMError: Error, CustomStringConvertible, Sendable {
    case unavailable(String)
    case badResponse(String)
    case http(status: Int, body: String)
    case unparseable(String)
    case cancelled

    public var description: String {
        switch self {
        case .unavailable(let m): return "model unavailable: \(m)"
        case .badResponse(let m): return "bad model response: \(m)"
        case .http(let s, let b): return "HTTP \(s): \(b.prefix(300))"
        case .unparseable(let m): return "could not parse model output: \(m)"
        case .cancelled: return "cancelled"
        }
    }
}
