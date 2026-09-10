import Foundation

public enum CopilotHookInput {
    public static let transcriptReadLimit = 262_144

    public static func prepare(_ line: JSONValue, fallbackEvent: String?,
                               reportMetadataError: ((Error) -> Void)? = nil) throws -> JSONValue {
        guard var outer = line.object else { throw NativeError("Copilot hook input must be a JSON object.") }
        let nested = outer["event"]?.object != nil
        var raw = outer["event"]?.object ?? outer
        let suppliedEvent = raw.text("hook_event_name", "hookEventName", "event_name", "eventName", "type")
        if suppliedEvent == nil, let fallbackEvent {
            let canonical = EventNormalizer.canonicalName(fallbackEvent)
            guard EventNormalizer.events.contains(canonical) else { throw NativeError("Unknown Copilot hook event.") }
            raw["hook_event_name"] = .string(canonical)
        }
        if let name = suppliedEvent ?? fallbackEvent,
           EventNormalizer.canonicalName(name) == "Stop",
           raw.text("last_assistant_message", "lastAssistantMessage", "message") == nil,
           let path = raw.text("transcript_path", "transcriptPath") {
            do {
                guard path.hasPrefix("/") else { throw NativeError("Copilot transcript path must be absolute.") }
                if let message = try lastAssistantMessage(at: URL(fileURLWithPath: path)) {
                    raw["last_assistant_message"] = .string(message)
                }
            } catch {
                guard let reportMetadataError else { throw error }
                reportMetadataError(error)
            }
        }
        if nested { outer["event"] = .object(raw) }
        else { outer = raw }
        return .object(outer)
    }

    public static func lastAssistantMessage(at file: URL) throws -> String? {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw NativeError("Copilot transcript is not a regular file.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = size > UInt64(transcriptReadLimit) ? size - UInt64(transcriptReadLimit) : 0
        try handle.seek(toOffset: offset)
        var data = try handle.read(upToCount: transcriptReadLimit) ?? Data()
        if offset > 0 {
            guard let newline = data.firstIndex(of: 10) else { return nil }
            data.removeSubrange(...newline)
        }
        for line in data.split(separator: 10).reversed() {
            let record = try JSONDecoder().decode(JSONValue.self, from: Data(line))
            let type = record["type"]?.string
            if type == "user.message" || type == "user" || record["role"]?.string == "user" { return nil }
            if type == "assistant.message", let text = textContent(record["data"]?["content"]) { return text }
            if type == "assistant", let text = textContent(record["message"]?["content"]) { return text }
            if record["role"]?.string == "assistant", let text = textContent(record["content"]) { return text }
        }
        return nil
    }

    private static func textContent(_ value: JSONValue?) -> String? {
        let text: String
        if let string = value?.string { text = string }
        else if let blocks = value?.array {
            text = blocks.compactMap { block in
                guard ["text", "output_text"].contains(block["type"]?.string ?? "") else { return nil }
                return block["text"]?.string
            }.joined(separator: "\n")
        } else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
