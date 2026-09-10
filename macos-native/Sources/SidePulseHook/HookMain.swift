import Darwin
import Foundation
import SidePulseCore

@main
enum HookMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        let socket = value("--socket").map { URL(fileURLWithPath: $0) } ?? NativePaths().socket
        let inspecting = args.contains("--snapshot") || args.contains("--ping") || value("--request") != nil
        var pendingPayload: Data?
        do {
            let payload: Data
            if inspecting {
                payload = try JSONEncoder().encode(JSONValue.object([
                    "action": .string(value("--request") ?? (args.contains("--snapshot") ? "snapshot" : "ping"))
                ]))
            } else {
                guard let name = value("--provider"), let provider = Provider(rawValue: name) else {
                    throw NativeError("Usage: SidePulseHook --provider codex|claude|copilot|grok [--socket PATH]")
                }
                var input = Data()
                while let chunk = try FileHandle.standardInput.read(upToCount: 16_384), !chunk.isEmpty {
                    guard input.count + chunk.count <= NativeIPC.requestLimit else { throw NativeError("Hook payload exceeds 1 MiB.") }
                    input.append(chunk)
                }
                var line = try JSONDecoder().decode(JSONValue.self, from: input.isEmpty ? Data("{}".utf8) : input)
                guard var object = line.object else { throw NativeError("Hook payload must be a JSON object.") }
                if object["logged_at"] == nil {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    object["logged_at"] = .string(formatter.string(from: Date()))
                }
                line = .object(object)
                payload = try JSONEncoder().encode(HookEnvelope(provider: provider, line: line))
                pendingPayload = payload
            }
            let response = try NativeIPC.request(payload, socket: socket, timeout: inspecting ? 3 : 0.5)
            let object = try JSONDecoder().decode(JSONValue.self, from: response)
            if object["ok"]?.bool == false {
                pendingPayload = nil
                throw NativeError(object["error"]?.string ?? "Event was rejected.")
            }
            guard object["ok"]?.bool == true else { throw NativeError("The native app did not acknowledge the request.") }
            pendingPayload = nil
            if inspecting {
                try FileHandle.standardOutput.write(contentsOf: response)
                try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
            }
        } catch {
            if let pendingPayload {
                do { try PendingEvents.enqueue(pendingPayload, socket: socket) }
                catch { FileHandle.standardError.write(Data("SidePulse Native could not queue event: \(error.localizedDescription)\n".utf8)) }
            }
            let text = "SidePulse Native: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(text.utf8))
            // Agent hooks must never fail the agent's own operation.
            if inspecting || args.contains("--strict") { exit(1) }
        }
    }
}
