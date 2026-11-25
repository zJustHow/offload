import Foundation

/// A cheap description of one unit of source material. Listing must not read file bodies, message
/// databases in full, etc.: the pipeline lists everything, drops what it has already processed
/// (same `fingerprint`), and only then asks the connector to `load` the rest.
public struct WorkItemRef: Sendable {
    public var key: String          // stable inside the bucket: a path, a chat window id, a message-id...
    public var fingerprint: String  // changes whenever the content changes
    public var date: Date?
    public var title: String
    public var uri: String          // where the original lives, shown to the user and the agent
    public var trust: Trust

    public init(key: String, fingerprint: String, date: Date?, title: String, uri: String, trust: Trust) {
        self.key = key; self.fingerprint = fingerprint; self.date = date; self.title = title
        self.uri = uri; self.trust = trust
    }
}

public enum ItemContent: Sendable {
    case text(String)
    /// `Name: message` lines in time order; the user's own lines are labelled "Me".
    case conversation(lines: [String], info: ConversationInfo)
}

public protocol Connector: Sendable {
    /// Namespace for this source's items, e.g. `files:/Users/me/Documents`.
    var bucket: String { get }
    var kind: SourceKind { get }
    /// True when `list()` returns every current item, so items that vanished can be deleted.
    var listsAllItems: Bool { get }
    func list() async throws -> [WorkItemRef]
    func load(_ ref: WorkItemRef) async throws -> ItemContent
}

public enum ConnectorError: Error, CustomStringConvertible {
    case unreadable(String)
    case permissionDenied(String)
    public var description: String {
        switch self {
        case .unreadable(let m): return "unreadable: \(m)"
        case .permissionDenied(let m): return "permission denied: \(m)"
        }
    }
}
