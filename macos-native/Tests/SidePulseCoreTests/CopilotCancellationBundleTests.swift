import Foundation
import XCTest
@testable import SidePulseCore

final class CopilotCancellationBundleTests: XCTestCase {
    func testMultipleCopilotInstancesKeepSharedDisplayPriority() throws {
        guard let path = ProcessInfo.processInfo.environment["SIDEPULSE_NATIVE_APP"] else {
            throw XCTSkip("Set SIDEPULSE_NATIVE_APP to exercise an assembled app bundle.")
        }
        let app = URL(fileURLWithPath: path, isDirectory: true)
        let helper = app.appendingPathComponent("Contents/Helpers/SidePulseHook")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spn-cancel-app-\(UUID().uuidString.prefix(8))")
        let paths = NativePaths(root: root)
        try paths.prepare()
        try Persistence.save(AppConfiguration(), to: paths.configuration)
        let homes = ["one": root.appendingPathComponent("home-one"), "two": root.appendingPathComponent("home-two")]
        var process: Process?
        defer {
            if let process, process.processIdentifier > 0 {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not clean up cancellation fixture: \(error)") }
        }

        func environment(for id: String) throws -> [String: String] {
            var result = ProcessInfo.processInfo.environment
            result["COPILOT_HOME"] = try XCTUnwrap(homes[id]).appendingPathComponent(".copilot").path
            return result
        }
        func logFile(_ id: String) throws -> URL {
            try CopilotCancellationReader.eventFile(
                sessionID: id, directory: CopilotCancellationReader.eventsDirectory(home: XCTUnwrap(homes[id]))
            )
        }
        for id in ["one", "two"] {
            _ = try HookConfiguration.install(provider: .copilot, home: XCTUnwrap(homes[id]),
                                               helper: helper, socket: paths.socket)
            let file = try logFile(id)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        func request(_ action: String) throws -> JSONValue {
            let data = try JSONEncoder().encode(JSONValue.object(["action": .string(action)]))
            return try JSONDecoder().decode(JSONValue.self, from: NativeIPC.request(data, socket: paths.socket, timeout: 3))
        }
        func launch() throws {
            let next = Process()
            next.executableURL = app.appendingPathComponent("Contents/MacOS/SidePulseNative")
            next.arguments = ["--state-dir", root.path, "--copilot-testing"]
            next.environment = try environment(for: "one")
            next.standardOutput = FileHandle.nullDevice
            next.standardError = FileHandle.nullDevice
            process = next
            try next.run()
            let deadline = Date().addingTimeInterval(10)
            while next.isRunning && Date() < deadline {
                if (try? request("ping")["ok"]?.bool) == true { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw NativeError("Cancellation fixture app did not start.")
        }
        func send(_ event: String, id: String, fields: [String: JSONValue] = [:]) throws {
            var payload: [String: JSONValue] = [
                "session_id": .string(id), "cwd": .string(root.path),
                "session_title": .string("Copilot instance \(id)"),
                "timestamp": .number(Date().timeIntervalSince1970 * 1000)
            ]
            payload.merge(fields) { _, next in next }
            let child = Process()
            let input = Pipe(), errors = Pipe()
            child.executableURL = helper
            child.arguments = ["--provider", "copilot", "--event", event, "--socket", paths.socket.path, "--strict"]
            child.environment = try environment(for: id)
            child.standardInput = input
            child.standardOutput = FileHandle.nullDevice
            child.standardError = errors
            try child.run()
            try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(JSONValue.object(payload)))
            try input.fileHandleForWriting.close()
            let error = errors.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0, String(decoding: error, as: UTF8.self))
        }
        func append(_ type: String, id: String) throws {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let data = try JSONEncoder().encode(JSONValue.object([
                "type": .string(type), "timestamp": .string(formatter.string(from: Date())),
                "data": .object(["reason": .string("user_initiated"), "turnId": .string("fixture-turn")])
            ])) + Data([10])
            let handle = try FileHandle(forWritingTo: logFile(id))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        func session(_ snapshot: JSONValue, id: String) -> JSONValue? {
            snapshot["sessions"]?.array?.first { $0["sessionID"]?.string == id }
        }
        @discardableResult
        func waitFor(_ state: String, active: Int, cancelled: [String] = [],
                     file: StaticString = #filePath, line: UInt = #line) throws -> JSONValue {
            let deadline = Date().addingTimeInterval(8)
            var value = try request("snapshot")
            while Date() < deadline {
                if value["ui"]?["label"]?.string == state,
                   value["activeCount"]?.number == Double(active),
                   cancelled.allSatisfy({ session(value, id: $0)?["event"]?.string == "CopilotAbort" }) { break }
                Thread.sleep(forTimeInterval: 0.1)
                value = try request("snapshot")
            }
            XCTAssertEqual(value["state"]?.string, state, file: file, line: line)
            XCTAssertEqual(value["ui"]?["label"]?.string, state, file: file, line: line)
            XCTAssertEqual(value["activeCount"]?.number, Double(active), file: file, line: line)
            for id in cancelled {
                XCTAssertEqual(session(value, id: id)?["mode"]?.string, "idle_ready", file: file, line: line)
                XCTAssertEqual(session(value, id: id)?["event"]?.string, "CopilotAbort", file: file, line: line)
            }
            return value
        }

        try launch()
        try send("UserPromptSubmit", id: "one")
        try send("PreToolUse", id: "one")
        try send("UserPromptSubmit", id: "two")
        try waitFor("Working", active: 2)
        try append("abort", id: "one")
        try send("PostToolUseFailure", id: "one", fields: ["error": .string("User cancelled")])
        let working = try waitFor("Working", active: 1, cancelled: ["one"])
        XCTAssertEqual(working["sessions"]?.array?.first?["sessionID"]?.string, "two")
        XCTAssertEqual(session(working, id: "two")?["copilotEventLog"]?.string, try logFile("two").path)

        try send("UserPromptSubmit", id: "one")
        try send("Notification", id: "two", fields: [
            "notification_type": .string("elicitation_dialog"), "message": .string("Choose a target")
        ])
        let asking = try waitFor("Ask", active: 2)
        XCTAssertEqual(asking["sessions"]?.array?.first?["sessionID"]?.string, "two")
        try append("abort", id: "one")
        try waitFor("Ask", active: 1, cancelled: ["one"])
        try send("UserPromptSubmit", id: "two")
        try waitFor("Working", active: 1, cancelled: ["one"])
        try append("abort", id: "two")
        try waitFor("Idle", active: 0, cancelled: ["one", "two"])

        try send("PostToolUseFailure", id: "one", fields: ["error": .string("User cancelled")])
        try send("Stop", id: "one", fields: ["last_assistant_message": .string("Old question?")])
        try waitFor("Idle", active: 0, cancelled: ["one", "two"])
        let history = try XCTUnwrap(Persistence.load([HistoryEntry].self, from: paths.history))
        XCTAssertFalse(history.contains { $0.state == .done }, "Cancellation must not flash a successful completion.")

        try append("assistant.turn_start", id: "two")
        try waitFor("Working", active: 1, cancelled: ["one"])
        try send("Stop", id: "two", fields: ["last_assistant_message": .string("Finished.")])
        try waitFor("Done", active: 0, cancelled: ["one"])
        try send("UserPromptSubmit", id: "two")
        try waitFor("Working", active: 1, cancelled: ["one"])
        _ = try request("quit")
        process?.waitUntilExit()
        try append("abort", id: "two")
        try launch()
        try waitFor("Idle", active: 0, cancelled: ["one", "two"])
        _ = try request("quit")
        process?.waitUntilExit()
    }
}
