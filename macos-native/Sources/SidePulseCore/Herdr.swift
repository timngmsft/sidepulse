import Foundation

public enum HerdrConnectionState: String, Codable, Sendable {
    case disabled, connecting, testing, authenticating, connected, paused
    case authenticationRequired, hostUnavailable, notInstalled, notRunning
    case unsupportedPlatform, invalidPath, incompatibleResponse, remoteError

    public var label: String {
        switch self {
        case .disabled: return "Disabled"
        case .connecting: return "Connecting"
        case .testing: return "Testing connection"
        case .authenticating: return "Complete authentication in Terminal"
        case .connected: return "Connected"
        case .paused: return "Paused while this Mac sleeps"
        case .authenticationRequired: return "Authentication required"
        case .hostUnavailable: return "SSH host unavailable"
        case .notInstalled: return "Herdr not installed"
        case .notRunning: return "Herdr session not running"
        case .unsupportedPlatform: return "Unsupported remote platform"
        case .invalidPath: return "Invalid Herdr path"
        case .incompatibleResponse: return "Incompatible Herdr response"
        case .remoteError: return "Remote error"
        }
    }

    public var isBusy: Bool { self == .connecting || self == .testing || self == .authenticating }
    public var isError: Bool {
        ![.disabled, .connecting, .testing, .authenticating, .connected, .paused].contains(self)
    }
}

public struct HerdrConnectionStatus: Codable, Equatable, Sendable {
    public var state: HerdrConnectionState
    public var message: String
    public var path: String?
    public var platform: String?
    public var lastSuccess: Date?
    public var agentCount: Int
    public var retryAt: Date?

    public init(_ state: HerdrConnectionState, message: String = "", path: String? = nil,
                platform: String? = nil, lastSuccess: Date? = nil, agentCount: Int = 0, retryAt: Date? = nil) {
        self.state = state; self.message = message; self.path = path; self.platform = platform
        self.lastSuccess = lastSuccess; self.agentCount = agentCount; self.retryAt = retryAt
    }

    public var summary: String {
        state == .connected ? "Connected - \(agentCount) agent\(agentCount == 1 ? "" : "s")" : state.label
    }
}

public struct HerdrFailure: LocalizedError, Sendable {
    public var state: HerdrConnectionState
    public var message: String
    public init(_ state: HerdrConnectionState, _ message: String) { self.state = state; self.message = message }
    public var errorDescription: String? { message }
}

public enum HerdrAgentState: String, Sendable {
    case idle, working, blocked, done, unknown
}

public struct HerdrObservation: Equatable, Sendable {
    public var agent: String
    public var state: HerdrAgentState
    public var terminalID: String
    public var cwd: String?
    public var title: String?
    public var message: String?
    public var sessionID: String?
}

public enum HerdrRecord: Sendable {
    case agents([HerdrObservation])
    case failure(HerdrFailure)

    public static func parse(_ data: Data) throws -> HerdrRecord {
        guard data.count <= NativeIPC.requestLimit else {
            throw HerdrFailure(.incompatibleResponse, "Herdr response exceeds 1 MiB.")
        }
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard root["id"]?.string == "cli:agent:list" else {
            throw HerdrFailure(.incompatibleResponse, "Unexpected Herdr response identifier.")
        }
        if let error = root["error"]?.object {
            guard let code = error.text("code"), let message = error["message"]?.string else {
                throw HerdrFailure(.incompatibleResponse, "Malformed Herdr error response.")
            }
            return .failure(HerdrFailure(code == "server_not_running" ? .notRunning : .remoteError, message))
        }
        guard root["result"]?["type"]?.string == "agent_list", let rows = root["result"]?["agents"]?.array else {
            throw HerdrFailure(.incompatibleResponse, "Expected a Herdr agent list.")
        }
        var identities: Set<String> = []
        var observations: [HerdrObservation] = []
        for row in rows {
            guard let object = row.object, let name = object.text("agent"),
                  let stateName = object.text("agent_status"), let terminal = object.text("terminal_id") else {
                throw HerdrFailure(.incompatibleResponse, "Incomplete Herdr agent record.")
            }
            let agent = name.lowercased()
            guard let state = HerdrAgentState(rawValue: stateName.lowercased()) else { continue }
            guard identities.insert("\(terminal)\0\(agent)").inserted else {
                throw HerdrFailure(.incompatibleResponse, "Duplicate Herdr agent identity.")
            }
            func text(_ field: String) throws -> String? {
                guard let value = object[field], value != .null else { return nil }
                guard let string = value.string else {
                    throw HerdrFailure(.incompatibleResponse, "Herdr field \(field) must be a string.")
                }
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            let sessionID: String?
            if let session = object["agent_session"]?.object {
                guard let value = session["value"]?.string,
                      let kind = session["kind"]?.string else {
                    throw HerdrFailure(.incompatibleResponse, "Malformed Herdr agent-session reference.")
                }
                sessionID = kind == "id" && !value.isEmpty ? value : nil
            } else { sessionID = try text("agent_session") }
            let cwd = try text("cwd"), foreground = try text("foreground_cwd")
            let title = try text("terminal_title"), stripped = try text("terminal_title_stripped")
            observations.append(HerdrObservation(agent: agent, state: state, terminalID: terminal,
                                                  cwd: foreground ?? cwd, title: stripped ?? title,
                                                  message: title, sessionID: sessionID))
        }
        return .agents(observations)
    }
}

public final class HerdrReducer {
    public static let graceSeconds: TimeInterval = 15
    public var doneVisible: TimeInterval = 1200
    private var previous: [String: HerdrAgentState] = [:]
    private var published: [String: AgentSession] = [:]
    public init() {}

    public func reconnecting(preservePublished: Bool = true) {
        previous.removeAll()
        if !preservePublished { published.removeAll() }
    }

    public func apply(_ data: Data, remote: RemoteConfiguration, at now: Date = Date()) throws -> [AgentSession] {
        switch try HerdrRecord.parse(data) {
        case .agents(let observations): return apply(observations, remote: remote, at: now)
        case .failure(let failure): throw failure
        }
    }

    public func apply(_ observations: [HerdrObservation], remote: RemoteConfiguration,
                      at now: Date = Date()) -> [AgentSession] {
        var nextRaw: [String: HerdrAgentState] = [:]
        var next: [String: AgentSession] = [:]
        for observation in observations {
            let id = "herdr:\(remote.id):\(observation.terminalID):\(observation.agent)"
            nextRaw[id] = observation.state
            let retainedCompletion: AgentMode? = published[id].flatMap {
                $0.mode == .completed && now.timeIntervalSince($0.updatedAt) <= doneVisible ? .completed : nil
            }
            let mode: AgentMode?
            switch observation.state {
            case .working: mode = .working
            case .blocked: mode = .waiting
            case .idle, .done:
                mode = previous[id] == .working || previous[id] == .blocked ? .completed : retainedCompletion
            case .unknown: mode = retainedCompletion
            }
            guard let mode else { continue }
            let name = observation.agent.replacingOccurrences(of: "github-", with: "")
                .replacingOccurrences(of: "-cli", with: "").replacingOccurrences(of: "-code", with: "")
            let provider = Provider(rawValue: name) ?? .herdr
            let title = observation.title ?? observation.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? observation.agent
            var session = AgentSession(
                id: id, provider: provider, sessionID: observation.sessionID, title: String(title.prefix(100)),
                cwd: observation.cwd, mode: mode, updatedAt: published[id].flatMap { $0.mode == mode ? $0.updatedAt : nil } ?? now,
                observedAt: now, event: "Herdr", message: observation.message, remoteID: remote.id
            )
            session.remoteAgentName = observation.agent
            session.remoteTerminalID = observation.terminalID
            next[id] = session
        }
        previous = nextRaw; published = next
        return next.values.sorted { $0.id < $1.id }
    }
}
