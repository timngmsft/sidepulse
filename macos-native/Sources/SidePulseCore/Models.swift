import Foundation

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String)
    case number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
    public subscript(_ key: String) -> JSONValue? { object?[key] }
}

public extension Dictionary where Key == String, Value == JSONValue {
    func text(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty { return value }
        }
        return nil
    }
}

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, copilot, grok, herdr
    public static let hookProviders: [Provider] = [.codex, .claude, .copilot, .grok]
    public var supportsHooks: Bool { Self.hookProviders.contains(self) }
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .copilot: return "GitHub Copilot"
        case .grok: return "Grok"
        case .herdr: return "Herdr agent"
        }
    }
}

public enum DisplayState: String, Codable, CaseIterable, Sendable {
    case idle = "Idle", working = "Working", ask = "Ask", done = "Done"
    public var colorHex: String {
        switch self {
        case .idle: return "#59616E"
        case .working: return "#00E5FF"
        case .ask: return "#FF3A00"
        case .done: return "#00FF66"
        }
    }
}

public enum AgentMode: String, Codable, CaseIterable, Sendable {
    case idle = "idle_ready"
    case working, tool = "tool_running", progress = "long_task_progress"
    case waiting = "waiting_for_input", blocked = "blocked_error", completed

    public var priority: Int {
        switch self {
        case .blocked: return 0
        case .waiting: return 1
        case .tool: return 2
        case .progress: return 3
        case .working: return 4
        case .completed: return 5
        case .idle: return 6
        }
    }
    public var display: DisplayState {
        switch self {
        case .blocked, .waiting: return .ask
        case .working, .tool, .progress: return .working
        case .completed: return .done
        case .idle: return .idle
        }
    }
    public var isWorking: Bool { display == .working }
    public var isActive: Bool { self != .idle && self != .completed }
    public static func parse(_ text: String) -> AgentMode? {
        let key = text.lowercased().replacingOccurrences(of: "-", with: "_")
        if let exact = AgentMode(rawValue: key) { return exact }
        switch key {
        case "idle", "ready": return .idle
        case "running", "thinking", "busy": return .working
        case "ask", "waiting", "needs_input", "approval": return .waiting
        case "done", "complete", "success", "finished": return .completed
        case "error", "blocked", "failed": return .blocked
        default: return nil
        }
    }
}

public struct AgentSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: Provider
    public var sessionID: String?
    public var title: String
    public var cwd: String?
    public var mode: AgentMode
    public var updatedAt: Date
    public var observedAt: Date
    public var event: String
    public var message: String?
    public var tool: String?
    public var remoteID: String?
    public var remoteAgentName: String?
    public var remoteTerminalID: String?
    public var pendingPermissions: Set<String> = []

    public init(id: String, provider: Provider, sessionID: String? = nil, title: String,
                cwd: String? = nil, mode: AgentMode, updatedAt: Date, observedAt: Date? = nil,
                event: String, message: String? = nil, tool: String? = nil, remoteID: String? = nil) {
        self.id = id; self.provider = provider; self.sessionID = sessionID
        self.title = title; self.cwd = cwd; self.mode = mode
        self.updatedAt = updatedAt; self.observedAt = observedAt ?? updatedAt
        self.event = event; self.message = message; self.tool = tool; self.remoteID = remoteID
    }

    public func effectiveMode(at now: Date, staleAfter: TimeInterval, doneVisible: TimeInterval) -> AgentMode {
        let timeout = remoteID == nil ? staleAfter : HerdrReducer.graceSeconds
        if now.timeIntervalSince(observedAt) > timeout { return .idle }
        if remoteID != nil && (mode == .waiting || mode == .blocked) &&
            now.timeIntervalSince(updatedAt) > staleAfter { return .idle }
        if mode == .completed && now.timeIntervalSince(updatedAt) > doneVisible { return .idle }
        return mode
    }

    public var statusLabel: String { event == "SessionEnd" ? "Ended" : mode.display.rawValue }
    public var providerTitle: String { provider == .herdr ? remoteAgentName ?? provider.title : provider.title }

    public var referenceLabel: String? {
        let agentPrefix = "\(provider.rawValue):agent:"
        if id.hasPrefix(agentPrefix) {
            return "Agent \(id.dropFirst(agentPrefix.count).prefix(8))"
        }
        return sessionID.map { "Session \($0.prefix(8))" }
            ?? remoteTerminalID.map { "Terminal \($0.prefix(12))" }
    }
}

public struct SessionListSection: Identifiable {
    public var title: String
    public var sessions: [AgentSession]
    public var id: String { title }
}

public struct MonitorSnapshot: Codable, Sendable {
    public var state: DisplayState
    public var sessions: [AgentSession]
    public var activeCount: Int
    public var generatedAt: Date
    public init(state: DisplayState, sessions: [AgentSession], activeCount: Int, generatedAt: Date) {
        self.state = state; self.sessions = sessions
        self.activeCount = activeCount; self.generatedAt = generatedAt
    }

    public var listSections: [SessionListSection] {
        let visible = Array(sessions.prefix(30))
        return [
            SessionListSection(title: "Active", sessions: visible.filter { $0.mode.isActive }),
            SessionListSection(title: "Recent", sessions: visible.filter { !$0.mode.isActive })
        ].filter { !$0.sessions.isEmpty }
    }
}

public struct HookEnvelope: Codable, Sendable {
    public var provider: Provider
    public var line: JSONValue
    public init(provider: Provider, line: JSONValue) { self.provider = provider; self.line = line }
}

public struct NativeError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum JSONCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
