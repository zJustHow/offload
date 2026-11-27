import Foundation
import Security

public struct ModelProfile: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, Sendable { case apple, openaiCompatible, anthropic, claudeCLI, codexCLI }
    public var provider: Provider
    public var baseURL: String?
    public var model: String?
    /// Keychain account holding the API key (keys never live in the config file).
    public var keyAccount: String?
    public var vision: Bool?
    /// Use the provider's native tool calling for the assistant. On by default for Anthropic; off
    /// for OpenAI-compatible servers, where support depends on the model (set it when yours has it).
    public var nativeTools: Bool?
    /// Claude subscription only, and only used for answering questions: Claude may search and read the
    /// knowledge base itself, through Offload's read-only MCP server, instead of only being handed excerpts.
    public var memoryTools: Bool?
    /// Claude subscription only, assistant role: Claude carries out the assistant's tasks itself, calling the same
    /// tools the assistant has (notes, web, connected apps, operating the Mac) back in the app, which still decides
    /// what runs, asks for approval and shows progress in the notch.
    public var agentTools: Bool?

    public static let apple = ModelProfile(provider: .apple)
    public init(provider: Provider, baseURL: String? = nil, model: String? = nil, keyAccount: String? = nil, vision: Bool? = nil, nativeTools: Bool? = nil, memoryTools: Bool? = nil, agentTools: Bool? = nil) {
        self.provider = provider; self.baseURL = baseURL; self.model = model; self.keyAccount = keyAccount; self.vision = vision; self.nativeTools = nativeTools; self.memoryTools = memoryTools; self.agentTools = agentTools
    }
}

/// What the assistant (the notch's Do mode and `offload agent`) may do. Defaults reproduce the
/// original behaviour: look things up, operate the Mac, ask before anything irreversible.
public struct AgentSettings: Codable, Equatable, Sendable {
    /// Which tools run freely, which ask, which are refused. See `PermissionPolicy`.
    public var permissions = PermissionPolicy(mode: .act)
    /// Look around and show a plan first; act only once the user approves it.
    public var planFirst = false
    /// Lets the assistant read web pages and search the web. Off by default: what it asks for
    /// leaves this Mac, and a page it reads is a way for someone else to talk to it.
    public var webTools = false
    public var webAllowedDomains: [String] = []
    public var webBlockedDomains: [String] = []
    /// Lets the assistant propose changes to notes (each one needs the user's approval).
    public var noteEditing = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentSettings()
        permissions = try c.decodeIfPresent(PermissionPolicy.self, forKey: .permissions) ?? d.permissions
        planFirst = try c.decodeIfPresent(Bool.self, forKey: .planFirst) ?? d.planFirst
        webTools = try c.decodeIfPresent(Bool.self, forKey: .webTools) ?? d.webTools
        webAllowedDomains = try c.decodeIfPresent([String].self, forKey: .webAllowedDomains) ?? d.webAllowedDomains
        webBlockedDomains = try c.decodeIfPresent([String].self, forKey: .webBlockedDomains) ?? d.webBlockedDomains
        noteEditing = try c.decodeIfPresent(Bool.self, forKey: .noteEditing) ?? d.noteEditing
    }
}

public struct EmbeddingProfile: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case appleContextual, appleSentence, openaiCompatible, hashing }
    public var kind: Kind
    public var baseURL: String?
    public var model: String?
    public var keyAccount: String?
    public static let `default` = EmbeddingProfile(kind: .appleContextual)
    public init(kind: Kind, baseURL: String? = nil, model: String? = nil, keyAccount: String? = nil) {
        self.kind = kind; self.baseURL = baseURL; self.model = model; self.keyAccount = keyAccount
    }
}

public struct OffloadConfig: Codable, Equatable, Sendable {
    public var vaultPath: String?
    public var folders: [String] = []
    public var imessageChats: [String] = []
    public var whatsappChats: [String] = []
    public var mailEnabled = false
    public var calendarEnabled = false
    public var appleNotesEnabled = false
    /// The SiYuan workspace's `data` folder, when SiYuan should be read.
    public var siyuanPath: String?
    public var gmailEnabled = false
    public var googleCalendarEnabled = false
    /// Reads every item: must be cheap and private, so it defaults to the built-in on-device model.
    public var triage: ModelProfile = .apple
    /// Writes the knowledge base. Merging many items into notes needs a much stronger model than
    /// the built-in one (see docs/ARCHITECTURE.md); configure one for good results.
    public var knowledge: ModelProfile = .apple
    /// Answers questions, drafts replies and runs the agent.
    public var assistant: ModelProfile = .apple
    public var embedding: EmbeddingProfile = .default
    public var scheduleHour = 3
    /// Keep the index following the chosen folders while the app runs (see `LiveSync`). Files are
    /// read and triaged as they change, but only in folders that have already been read once.
    public var liveSync = true
    /// The first-run guide: where the user is, and whether they have finished (or skipped) it.
    public var onboardingStep = 0
    public var onboardingCompleted = false
    /// Apps (MCP servers) the assistant can use. See `MCPServerConfig`.
    public var mcpServers: [MCPServerConfig] = []
    public var agent = AgentSettings()

    public init() {}

    /// Tolerant decoding: a config written by an older version simply lacks the newer keys, and the
    /// compiler-generated decoder would reject it instead of using the defaults above.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OffloadConfig()
        vaultPath = try c.decodeIfPresent(String.self, forKey: .vaultPath)
        folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? d.folders
        imessageChats = try c.decodeIfPresent([String].self, forKey: .imessageChats) ?? d.imessageChats
        whatsappChats = try c.decodeIfPresent([String].self, forKey: .whatsappChats) ?? d.whatsappChats
        mailEnabled = try c.decodeIfPresent(Bool.self, forKey: .mailEnabled) ?? d.mailEnabled
        calendarEnabled = try c.decodeIfPresent(Bool.self, forKey: .calendarEnabled) ?? d.calendarEnabled
        appleNotesEnabled = try c.decodeIfPresent(Bool.self, forKey: .appleNotesEnabled) ?? d.appleNotesEnabled
        siyuanPath = try c.decodeIfPresent(String.self, forKey: .siyuanPath)
        gmailEnabled = try c.decodeIfPresent(Bool.self, forKey: .gmailEnabled) ?? d.gmailEnabled
        googleCalendarEnabled = try c.decodeIfPresent(Bool.self, forKey: .googleCalendarEnabled) ?? d.googleCalendarEnabled
        triage = try c.decodeIfPresent(ModelProfile.self, forKey: .triage) ?? d.triage
        knowledge = try c.decodeIfPresent(ModelProfile.self, forKey: .knowledge) ?? d.knowledge
        assistant = try c.decodeIfPresent(ModelProfile.self, forKey: .assistant) ?? d.assistant
        embedding = try c.decodeIfPresent(EmbeddingProfile.self, forKey: .embedding) ?? d.embedding
        scheduleHour = try c.decodeIfPresent(Int.self, forKey: .scheduleHour) ?? d.scheduleHour
        liveSync = try c.decodeIfPresent(Bool.self, forKey: .liveSync) ?? d.liveSync
        onboardingStep = try c.decodeIfPresent(Int.self, forKey: .onboardingStep) ?? d.onboardingStep
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? d.onboardingCompleted
        mcpServers = try c.decodeIfPresent([MCPServerConfig].self, forKey: .mcpServers) ?? d.mcpServers
        agent = try c.decodeIfPresent(AgentSettings.self, forKey: .agent) ?? d.agent
    }
}

/// Where everything lives.
///
/// The default directory is `~/Library/Application Support/Offload`. `OFFLOAD_HOME` (or an
/// explicit `support`) relocates the whole installation — database, config and the default vault —
/// which is how development and tests run without touching real user data.
public struct AppPaths: Sendable {
    public static let defaultDirectoryName = "Offload"
    public let support: URL
    private let isCustomLocation: Bool

    public init(support: URL? = nil) {
        if let support { self.support = support; isCustomLocation = true; return }
        if let env = ProcessInfo.processInfo.environment["OFFLOAD_HOME"], !env.isEmpty {
            self.support = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
            isCustomLocation = true
        } else {
            self.support = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/\(Self.defaultDirectoryName)", isDirectory: true)
            isCustomLocation = false
        }
    }

    public var database: URL { support.appendingPathComponent("offload.sqlite") }
    public var config: URL { support.appendingPathComponent("config.json") }
    public var logs: URL { support.appendingPathComponent("logs", isDirectory: true) }
    /// Inside the installation when it was relocated; `~/Offload Knowledge` only for the standard one.
    public var defaultVault: URL {
        isCustomLocation ? support.appendingPathComponent("vault", isDirectory: true) : VaultWorkspace.defaultRoot()
    }

    public func loadConfig() throws -> OffloadConfig {
        guard let data = try? Data(contentsOf: config) else { return OffloadConfig() }
        return try JSONDecoder().decode(OffloadConfig.self, from: data)
    }

    public func save(_ config: OffloadConfig) throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: self.config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.config.path)
    }
}

public enum Keychain {
    static let service = "dev.offload.keys"

    public static func set(_ secret: String, account: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw LLMError.unavailable("Keychain write failed (\(status))") }
    }

    public static func get(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}
