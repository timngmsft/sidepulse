import Foundation

// The owner serializes access; the app owns this store on the main actor.
public final class SessionStore {
    private static let copilotCleanupEvents: Set<String> = [
        "PostToolUse", "PostToolUseFailure", "PermissionDenied", "Stop", "StopFailure", "ErrorOccurred", "SessionEnd"
    ]
    private var sessionsByID: [String: AgentSession] = [:]
    public var staleAfter: TimeInterval = 3600
    public var doneVisible: TimeInterval = 1200
    public var retention: TimeInterval = 86400

    public init(sessions: [AgentSession] = []) {
        for session in sessions where session.remoteID == nil { sessionsByID[session.id] = session }
    }

    @discardableResult
    public func ingest(_ event: NormalizedEvent) -> Bool {
        guard event.updatesStatus else { return false }
        var incoming = event.session
        if let previous = sessionsByID[incoming.id] {
            let cutoff = incoming.isCancelled ? previous.copilotCancellationCutoff : previous.updatedAt
            guard incoming.updatedAt >= cutoff else { return false }
            if previous.isCancelled, Self.copilotCleanupEvents.contains(incoming.event) { return false }
            incoming.pendingPermissions = previous.pendingPermissions
            if incoming.cwd == nil { incoming.cwd = previous.cwd }
            if incoming.copilotEventLog == nil { incoming.copilotEventLog = previous.copilotEventLog }
            if incoming.isLocalCopilotSession {
                incoming.copilotActivityAt = previous.copilotActivityAt ?? previous.updatedAt
            }
            if incoming.title.hasPrefix("\(incoming.provider.title) ") { incoming.title = previous.title }
            if incoming.message == nil && !["SessionStart", "UserPromptSubmit"].contains(incoming.event) {
                incoming.message = previous.message
            }
        }
        if incoming.isLocalCopilotSession, !incoming.isCancelled,
           !Self.copilotCleanupEvents.contains(incoming.event) {
            incoming.copilotActivityAt = incoming.updatedAt
        }
        if incoming.isCancelled {
            incoming.pendingPermissions.removeAll()
            incoming.postToolUseSettlesAt = nil
            incoming.message = nil
            incoming.tool = nil
        } else if ["SessionStart", "UserPromptSubmit", "SessionEnd"].contains(incoming.event) {
            incoming.pendingPermissions.removeAll()
        } else if incoming.event == "PermissionRequest" {
            incoming.pendingPermissions.insert(event.permissionKey ?? "permission")
        } else if ["PostToolUse", "PostToolUseFailure", "PermissionDenied"].contains(incoming.event),
                  let key = event.permissionKey {
            incoming.pendingPermissions.remove(key)
            if incoming.pendingPermissions == ["permission"] { incoming.pendingPermissions.removeAll() }
        }
        if !incoming.pendingPermissions.isEmpty && incoming.mode.priority > AgentMode.waiting.priority {
            incoming.mode = .waiting
        }
        sessionsByID[incoming.id] = incoming
        if sessionsByID.count > 256, let oldest = sessionsByID.values.min(by: { $0.observedAt < $1.observedAt }) {
            sessionsByID.removeValue(forKey: oldest.id)
        }
        return true
    }

    @discardableResult
    public func ingest(_ signal: CopilotSessionSignal) -> Bool {
        let id = "copilot:session:\(signal.sessionID)"
        guard var session = sessionsByID[id], session.isLocalCopilotSession else { return false }
        let cutoff = signal.kind == .aborted ? session.copilotCancellationCutoff : session.updatedAt
        guard signal.timestamp >= cutoff else { return false }
        if let path = session.copilotEventLog,
           URL(fileURLWithPath: path).standardizedFileURL != signal.file { return false }
        if signal.kind == .started && !session.isCancelled { return false }
        if session.event == signal.kind.event && signal.timestamp == session.updatedAt { return false }
        session.event = signal.kind.event
        session.mode = signal.kind == .aborted ? .idle : .working
        session.updatedAt = signal.timestamp
        session.observedAt = signal.timestamp
        session.copilotEventLog = signal.file.path
        session.postToolUseSettlesAt = nil
        return ingest(NormalizedEvent(session: session, permissionKey: nil))
    }

    public func reconcile(remoteID: String, sessions: [AgentSession]) {
        sessionsByID = sessionsByID.filter { $0.value.remoteID != remoteID }
        for session in sessions where session.remoteID == remoteID { sessionsByID[session.id] = session }
    }

    public func remove(id: String) { sessionsByID.removeValue(forKey: id) }
    public func clear() { sessionsByID.removeAll() }
    public var persistentSessions: [AgentSession] {
        sessionsByID.values.filter { $0.remoteID == nil }.sorted { $0.id < $1.id }
    }

    public func snapshot(at now: Date = Date()) -> MonitorSnapshot {
        sessionsByID = sessionsByID.filter { now.timeIntervalSince($0.value.observedAt) < retention }
        var sessions = Array(sessionsByID.values)
        sessions.sort {
            let left = $0.effectiveMode(at: now, staleAfter: staleAfter, doneVisible: doneVisible)
            let right = $1.effectiveMode(at: now, staleAfter: staleAfter, doneVisible: doneVisible)
            return left.priority == right.priority ? $0.observedAt > $1.observedAt : left.priority < right.priority
        }
        let modes = sessions.map { $0.effectiveMode(at: now, staleAfter: staleAfter, doneVisible: doneVisible) }
        for index in sessions.indices { sessions[index].mode = modes[index] }
        return MonitorSnapshot(
            state: modes.min(by: { $0.priority < $1.priority })?.display ?? .idle,
            sessions: sessions, activeCount: modes.filter(\.isActive).count,
            generatedAt: now
        )
    }
}
