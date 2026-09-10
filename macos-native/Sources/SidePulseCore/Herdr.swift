import Foundation

public final class HerdrReducer {
    private var previous: [String: String] = [:]
    private var published: [String: AgentSession] = [:]
    public init() {}
    public func reconnecting() { previous.removeAll() }

    public func apply(_ data: Data, remote: RemoteConfiguration, at now: Date = Date()) throws -> [AgentSession] {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard root["id"]?.string == "cli:agent:list" else { throw NativeError("Unexpected Herdr response identifier.") }
        if let error = root["error"]?.object {
            throw NativeError(error.text("message", "code") ?? "Herdr returned an error.")
        }
        guard root["result"]?["type"]?.string == "agent_list",
              let rows = root["result"]?["agents"]?.array else { throw NativeError("Invalid Herdr agent list.") }
        var nextRaw: [String: String] = [:]
        var next: [String: AgentSession] = [:]
        for row in rows {
            guard let object = row.object,
                  let name = object.text("agent"), let state = object.text("agent_status"),
                  let terminal = object.text("terminal_id") else { throw NativeError("Incomplete Herdr agent record.") }
            let normalizedProvider = name.lowercased().replacingOccurrences(of: "github-", with: "")
                .replacingOccurrences(of: "-cli", with: "").replacingOccurrences(of: "-code", with: "")
            guard let provider = Provider(rawValue: normalizedProvider) else { continue }
            let id = "herdr:\(remote.id):\(terminal):\(provider.rawValue)"
            guard nextRaw[id] == nil else { throw NativeError("Duplicate Herdr agent identity.") }
            nextRaw[id] = state
            let mode: AgentMode?
            if state == "working" { mode = .working }
            else if state == "blocked" { mode = .waiting }
            else if ["idle", "done"].contains(state),
                    previous[id] == "working" || previous[id] == "blocked" { mode = .completed }
            else if let existing = published[id], existing.mode == .completed,
                    now.timeIntervalSince(existing.updatedAt) < 1200 { mode = .completed }
            else { mode = nil }
            guard let mode else { continue }
            let cwd = object.text("foreground_cwd", "cwd")
            let title = object.text("terminal_title_stripped", "terminal_title")
                ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? provider.title
            let previousDate = published[id].flatMap { $0.mode == mode ? $0.updatedAt : nil }
            next[id] = AgentSession(
                id: id, provider: provider, sessionID: object.text("agent_session"),
                title: String(title.prefix(100)), cwd: cwd, mode: mode,
                updatedAt: previousDate ?? now, observedAt: now, event: "Herdr",
                remoteID: remote.id
            )
        }
        previous = nextRaw; published = next
        return Array(next.values)
    }

    public static func command(for remote: RemoteConfiguration) throws -> String {
        try remote.validate()
        let session = remote.session.isEmpty ? "" : " --session \(HookConfiguration.shellQuote(remote.session))"
        let discovery: String
        if remote.herdrPath.isEmpty {
            discovery = """
            p=$(command -v herdr 2>/dev/null); \
            if [ -z "$p" ]; then for c in /opt/homebrew/bin/herdr /usr/local/bin/herdr "$HOME/.cargo/bin/herdr" "$HOME/.local/bin/herdr" "$HOME/.local/share/mise/shims/herdr" "$HOME/.nix-profile/bin/herdr"; \
            do if [ -x "$c" ]; then p="$c"; break; fi; done; fi;
            """
        } else { discovery = "p=\(HookConfiguration.shellQuote(remote.herdrPath));" }
        let script = discovery + """
         [ -n "$p" ] && [ -x "$p" ] || { echo "Herdr executable not found" >&2; exit 127; }; \
        while :; do "$p"\(session) agent list 2>&1 | cat || exit; sleep 2; done
        """
        return "sh -c \(HookConfiguration.shellQuote(script))"
    }
}
