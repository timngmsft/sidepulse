import CryptoKit
import Foundation

public struct NormalizedEvent: Sendable {
    public var session: AgentSession
    public var permissionKey: String?
    public var updatesStatus = true
    public var questionKey: String?
}

public enum EventNormalizer {
    private static let postToolUseSettlingSeconds: TimeInterval = 2 * 60

    public static func canonicalName(_ name: String) -> String {
        let key = name.lowercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "userpromptsubmitted", "userpromptsubmit": return "UserPromptSubmit"
        case "agentstop", "stop": return "Stop"
        case "subagentend", "subagentstop": return "SubagentStop"
        default:
            return events.first { $0.lowercased() == key } ?? name
        }
    }

    public static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionRequest", "PermissionDenied", "Notification",
        "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "Stop",
        "StopFailure", "ErrorOccurred"
    ]

    public static func normalize(_ envelope: HookEnvelope, receivedAt now: Date = Date()) throws -> NormalizedEvent {
        guard envelope.provider.supportsHooks else { throw NativeError("Herdr activity must come from a remote monitor, not a local hook.") }
        guard let outer = envelope.line.object else { throw NativeError("Hook payload must be a JSON object.") }
        let raw = outer["event"]?.object ?? outer
        guard let eventText = raw.text("hook_event_name", "hookEventName", "event_name", "eventName", "type") else {
            throw NativeError("Hook payload has no event name.")
        }
        let event = canonicalName(eventText)
        guard events.contains(event) else { throw NativeError("Unsupported hook event: \(event)") }
        var provider = envelope.provider
        if provider == .claude,
           (raw.text("transcriptPath", "transcript_path")?.contains("/.grok/") == true ||
            (raw["hookEventName"] != nil && raw["workspaceRoot"] != nil)) { provider = .grok }
        let sessionID = raw.text("session_id", "sessionId", "conversation_id", "conversationId")
        let agentID = raw.text("agent_id", "agentId")
        let cwd = raw.text("cwd", "workspaceRoot")
        let key = agentID.map { "agent:\($0)" } ?? sessionID.map { "session:\($0)" } ?? "cwd:\(cwd ?? "unknown")"
        let message = raw.text("last_assistant_message", "lastAssistantMessage", "message")
            ?? (provider == .copilot ? raw["error"]?["message"]?.string ?? raw["error"]?.string : nil)
            ?? (provider == .copilot && event == "SubagentStop" ? raw.text("response") : nil)
        let notification = raw.text("notification_type", "notificationType")
        let copilotNotification = provider == .copilot && event == "Notification" && notification != nil
        let needsAttention = ["permission_prompt", "elicitation_dialog"].contains(notification ?? "")
        let tool = raw.text("tool_name", "toolName")
        let questionTool = provider == .copilot && ["ask_user", "askuserquestion"].contains(tool?.lowercased() ?? "")
        let explicit = explicitMode(raw: raw, message: message)
        let waiting = (copilotNotification && needsAttention) || (event == "PreToolUse" && questionTool)
        let mode = waiting ? AgentMode.waiting : try explicit ?? mode(for: event, raw: raw, message: message)
        let eventTime = provider == .copilot ? parseDate(raw["timestamp"]) : nil
        let timestamp = eventTime ?? parseDate(outer["logged_at"] ?? raw["logged_at"] ?? raw["timestamp"]) ?? now
        let title = raw.text("session_title", "sessionTitle")
            ?? (provider == .copilot && event == "Notification" ? nil : raw.text("title"))
            ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "\(provider.title) \(String((sessionID ?? agentID ?? "session").prefix(8)))"
        var session = AgentSession(
            id: "\(provider.rawValue):\(key)", provider: provider, sessionID: sessionID,
            title: String(title.prefix(100)), cwd: cwd, mode: mode,
            updatedAt: min(timestamp, now), observedAt: min(timestamp, now), event: event,
            message: message.map { String($0.prefix(2000)) }, tool: tool
        )
        if provider == .copilot {
            session.copilotEventLog = raw.text("sidepulse_copilot_event_log")
            if event == "SessionEnd", raw.text("reason") == "abort" {
                session.event = CopilotSessionSignal.Kind.aborted.event
                session.mode = .idle
            }
        }
        if event == "PostToolUse", mode == .working, explicit == nil {
            session.postToolUseSettlesAt = session.updatedAt.addingTimeInterval(postToolUseSettlingSeconds)
        }
        let callID = raw.text("tool_use_id", "toolUseId", "tool_call_id", "toolCallId", "call_id")
        var questionKey: String?
        if provider == .copilot {
            if let callID, questionTool || ["PostToolUse", "PostToolUseFailure", "PermissionDenied"].contains(event) {
                questionKey = "call:\(callID)"
            } else if questionTool {
                // Copilot's file hooks omit call IDs but preserve arguments across start/result events.
                if let input = raw["tool_input"] ?? raw["toolInput"] ?? raw["toolArgs"] {
                    let digest = SHA256.hash(data: try JSONCoding.encoder().encode(input))
                    questionKey = "ask_user:\(digest.map { String(format: "%02x", $0) }.joined())"
                } else {
                    questionKey = "ask_user"
                }
            }
        }
        return NormalizedEvent(session: session, permissionKey: callID ?? tool,
                               updatesStatus: !copilotNotification || needsAttention, questionKey: questionKey)
    }

    private static func explicitMode(raw: [String: JSONValue], message: String?) -> AgentMode? {
        if let value = raw.text("sidepulse_status", "sidepulse_mode"), let explicit = AgentMode.parse(value) {
            return explicit
        }
        if let message {
            let text = outsideCodeFences(message)
            for pattern in [
                #"(?m)^\s*<!--\s*(?:sidepulse|agent[-_ ]monitor)\s*(?:(?:status|mode)\s*)?:\s*([a-z0-9_ -]+)\s*-->\s*$"#,
                #"(?m)^\s*\[(?:sidepulse|agent[-_ ]monitor)\s+(?:status|mode)\s*:\s*([a-z0-9_ -]+)\]\s*$"#,
                #"\[sidepulse:(\w+)\]"#
            ] {
                if let marker = match(pattern, in: text),
                   let explicit = AgentMode.parse(marker.trimmingCharacters(in: .whitespaces)) { return explicit }
            }
        }
        return nil
    }

    private static func mode(for event: String, raw: [String: JSONValue], message: String?) throws -> AgentMode {
        switch event {
        case "SessionStart": return .idle
        case "SessionEnd": return raw.text("reason") == "error" ? .blocked : .completed
        case "UserPromptSubmit", "PreCompact", "PostCompact", "SubagentStart": return .working
        case "PreToolUse": return .tool
        case "PostToolUse":
            let response = raw["tool_response"] ?? raw["toolResponse"]
            if response?["is_error"]?.bool == true || response?["success"]?.bool == false { return .blocked }
            return .working
        case "PermissionRequest": return .waiting
        case "PostToolUseFailure", "PermissionDenied", "StopFailure": return .blocked
        case "ErrorOccurred": return raw["recoverable"]?.bool == true ? .working : .blocked
        case "Stop", "SubagentStop": return asksQuestion(message ?? "") ? .waiting : .completed
        case "Notification":
            let text = [raw.text("notification_type", "notificationType"), message]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            if ["permission", "approval", "input", "question", "idle_prompt"].contains(where: text.contains) { return .waiting }
            if ["complete", "finished", "done"].contains(where: text.contains) { return .completed }
            return .working
        default: throw NativeError("Unsupported hook event: \(event)")
        }
    }

    public static func asksQuestion(_ message: String) -> Bool {
        for original in outsideCodeFences(message).components(separatedBy: .newlines) {
            let line = original.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = line.replacingOccurrences(of: #"`[^`]*`"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = cleaned.lowercased()
            if ["anything else", "anything more", "what else can i", "how else can i",
                "let me know if you", "let me know if there's"].contains(where: lower.contains) { continue }
            if cleaned.hasSuffix("?") { return true }
            if ["please approve", "please confirm", "waiting for your", "need your approval",
                "choose an option", "select an option"].contains(where: lower.contains) { return true }
        }
        return false
    }

    private static func outsideCodeFences(_ message: String) -> String {
        var inFence = false
        var output: [String] = []
        for original in message.components(separatedBy: .newlines) {
            let line = original.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            if !inFence { output.append(original) }
        }
        return output.joined(separator: "\n")
    }

    public static func parseDate(_ value: JSONValue?) -> Date? {
        if let number = value?.number {
            return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
        }
        guard let text = value?.string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(result.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
