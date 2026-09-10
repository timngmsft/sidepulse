import Foundation

// The owner serializes access; the app owns this store on the main actor.
public final class SessionStore {
    private var sessionsByID: [String: AgentSession] = [:]
    public var staleAfter: TimeInterval = 3600
    public var doneVisible: TimeInterval = 1200
    public var retention: TimeInterval = 86400

    public init(sessions: [AgentSession] = []) {
        for session in sessions where session.remoteID == nil { sessionsByID[session.id] = session }
    }

    @discardableResult
    public func ingest(_ event: NormalizedEvent) -> Bool {
        var incoming = event.session
        if let previous = sessionsByID[incoming.id] {
            guard incoming.updatedAt >= previous.updatedAt else { return false }
            incoming.pendingPermissions = previous.pendingPermissions
            if incoming.cwd == nil { incoming.cwd = previous.cwd }
            if incoming.title.hasPrefix("\(incoming.provider.title) ") { incoming.title = previous.title }
            if incoming.message == nil && !["SessionStart", "UserPromptSubmit"].contains(incoming.event) {
                incoming.message = previous.message
            }
        }
        if ["SessionStart", "UserPromptSubmit", "SessionEnd"].contains(incoming.event) {
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
            sessions: sessions, activeCount: modes.filter { $0 != .idle && $0 != .completed }.count,
            generatedAt: now
        )
    }
}
