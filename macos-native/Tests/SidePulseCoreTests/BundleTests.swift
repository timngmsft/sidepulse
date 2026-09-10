import Foundation
import XCTest
@testable import SidePulseCore

final class BundleTests: XCTestCase {
    func testStandaloneBundleAndNativeHelper() throws {
        guard let path = ProcessInfo.processInfo.environment["SIDEPULSE_NATIVE_APP"] else {
            throw XCTSkip("Set SIDEPULSE_NATIVE_APP to exercise an assembled app bundle.")
        }
        let app = URL(fileURLWithPath: path, isDirectory: true)
        let root = app.deletingLastPathComponent().appendingPathComponent("smoke-\(UUID().uuidString.prefix(8))")
        let paths = NativePaths(root: root)
        try paths.prepare()
        var configuration = AppConfiguration()
        configuration.doneVisibleSeconds = 2.5
        try Persistence.save(configuration, to: paths.configuration)
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/SidePulseNative")
        process.arguments = ["--state-dir", root.path, "--development", "--show-window"]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let ended = expectation(description: "Native app exits")
        process.terminationHandler = { _ in ended.fulfill() }
        defer {
            if process.isRunning { process.terminate() }
            if process.processIdentifier > 0 { process.waitUntilExit() }
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not clean up isolated app data: \(error)") }
        }
        try process.run()
        let ping = Data(#"{"action":"ping"}"#.utf8)
        let deadline = Date().addingTimeInterval(10)
        var ready = false
        while process.isRunning && Date() < deadline {
            if (try? NativeIPC.request(ping, socket: paths.socket, timeout: 0.2)) != nil { ready = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(ready, "The bundled application did not start its native receiver.")
        guard ready else { return }
        let helper = app.appendingPathComponent("Contents/Helpers/SidePulseHook")

        func runHelper(_ arguments: [String], input: Data? = nil, expectedExit: Int32 = 0) throws -> Data {
            let child = Process()
            child.executableURL = helper
            child.arguments = ["--socket", paths.socket.path, "--strict"] + arguments
            let output = Pipe(), error = Pipe()
            child.standardOutput = output; child.standardError = error
            let pipe = Pipe()
            child.standardInput = input == nil ? FileHandle.nullDevice : pipe.fileHandleForReading
            try child.run()
            if let input {
                try pipe.fileHandleForWriting.write(contentsOf: input)
                try pipe.fileHandleForWriting.close()
            }
            let result = output.fileHandleForReading.readDataToEndOfFile()
            let message = error.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, expectedExit, String(decoding: message, as: UTF8.self))
            return result
        }
        func request(_ action: String) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: runHelper(["--request", action]))
        }
        func send(_ event: String, id: String = "alpha", extra: [String: JSONValue] = [:]) throws {
            var object: [String: JSONValue] = [
                "hook_event_name": .string(event), "session_id": .string(id),
                "session_title": .string("Native integration \(id)"), "cwd": .string(root.path)
            ]
            object.merge(extra) { _, new in new }
            _ = try runHelper(["--provider", "codex"], input: JSONEncoder().encode(JSONValue.object(object)))
        }
        let initial = try request("snapshot")
        XCTAssertEqual(initial["state"]?.string, "Idle")
        XCTAssertEqual(initial["mode"]?.string, "preview")
        XCTAssertEqual(initial["hookChangesAllowed"]?["copilot"]?.bool, false)
        let width = initial["ui"]?["width"]?.number
        XCTAssertEqual(initial["ui"]?["segments"]?.number, 4)
        func assertState(_ expected: String, file: StaticString = #filePath, line: UInt = #line) throws -> JSONValue {
            let value = try request("snapshot")
            XCTAssertEqual(value["state"]?.string, expected, file: file, line: line)
            XCTAssertEqual(value["ui"]?["label"]?.string, expected, file: file, line: line)
            XCTAssertEqual(value["ui"]?["width"]?.number, width, file: file, line: line)
            return value
        }

        try send("UserPromptSubmit")
        let working = try assertState("Working")
        XCTAssertEqual(working["ui"]?["animations"]?.number, working["ui"]?["reduceMotion"]?.bool == true ? 0 : 4)
        if working["ui"]?["reduceMotion"]?.bool == false && working["ui"]?["visible"]?.bool == true {
            Thread.sleep(forTimeInterval: 0.35)
            let animated = try request("snapshot")
            XCTAssertNotEqual(working["ui"]?["presentationOpacities"], animated["ui"]?["presentationOpacities"])
        }
        try send("PermissionRequest", extra: ["tool_name": .string("Bash"), "tool_use_id": .string("approval")])
        let ask = try assertState("Ask")
        XCTAssertEqual(ask["ui"]?["animations"]?.number, ask["ui"]?["reduceMotion"]?.bool == true ? 0 : 4)
        try send("UserPromptSubmit", id: "beta")
        _ = try assertState("Ask")
        try send("PostToolUse", extra: ["tool_name": .string("Bash"), "tool_use_id": .string("approval")])
        _ = try assertState("Working")
        try send("Stop", extra: ["last_assistant_message": .string("Implemented.")])
        _ = try assertState("Working")
        try send("Stop", id: "beta", extra: ["last_assistant_message": .string("Finished.")])
        _ = try assertState("Done")
        Thread.sleep(forTimeInterval: 1.0)
        let settled = try assertState("Done")
        XCTAssertEqual(settled["ui"]?["animations"]?.number, 0)
        Thread.sleep(forTimeInterval: 2.0)
        let expiryDeadline = Date().addingTimeInterval(2)
        while Date() < expiryDeadline {
            if try request("snapshot")["ui"]?["label"]?.string == "Idle" { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        _ = try assertState("Idle")

        try send("Stop", id: "question", extra: ["last_assistant_message": .string("Which environment should I use?")])
        _ = try assertState("Ask")
        for action in ["capture", "capture-settings", "capture-hooks", "capture-devices", "capture-remotes", "capture-history"] {
            let capture = try request(action)
            let image = try XCTUnwrap(capture["path"]?.string)
            XCTAssertGreaterThan(try Data(contentsOf: URL(fileURLWithPath: image)).count, 1000)
        }
        _ = try runHelper(["--provider", "claude"], input: Data("not-json".utf8), expectedExit: 1)
        XCTAssertEqual(try request("ping")["ok"]?.bool, true)
        _ = try request("quit")
        wait(for: [ended], timeout: 10)
        let saved = try XCTUnwrap(Persistence.load([AgentSession].self, from: paths.sessions))
        XCTAssertTrue(saved.contains { $0.sessionID == "question" && $0.mode == .waiting })
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socket.path))

        let offline = try JSONEncoder().encode(JSONValue.object([
            "hook_event_name": .string("Stop"), "session_id": .string("question"),
            "last_assistant_message": .string("Finished while the application was closed.")
        ]))
        _ = try runHelper(["--provider", "codex"], input: offline, expectedExit: 1)
        XCTAssertEqual(try PendingEvents.files(socket: paths.socket).count, 1)
        let restarted = Process()
        restarted.executableURL = process.executableURL
        restarted.arguments = ["--state-dir", root.path, "--copilot-testing"]
        restarted.standardOutput = FileHandle.nullDevice; restarted.standardError = FileHandle.nullDevice
        defer {
            if restarted.isRunning { restarted.terminate(); restarted.waitUntilExit() }
        }
        try restarted.run()
        let restartDeadline = Date().addingTimeInterval(10)
        while Date() < restartDeadline {
            if (try? NativeIPC.request(ping, socket: paths.socket, timeout: 0.2)) != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let replayed = try request("snapshot")
        XCTAssertNotEqual(replayed["state"]?.string, "Ask")
        let completed = replayed["sessions"]?.array?.first { $0["sessionID"]?.string == "question" }
        XCTAssertEqual(completed?["message"]?.string, "Finished while the application was closed.")
        XCTAssertTrue(try PendingEvents.files(socket: paths.socket).isEmpty)
        XCTAssertEqual(replayed["mode"]?.string, "copilot-testing")
        XCTAssertEqual(replayed["systemChangesAllowed"]?.bool, false)
        for provider in Provider.allCases {
            XCTAssertEqual(replayed["hookChangesAllowed"]?[provider.rawValue]?.bool, provider == .copilot)
        }

        _ = try request("clear")
        let home = root.appendingPathComponent("fixture-home")
        let install = try HookConfiguration.install(provider: .copilot, home: home, helper: helper, socket: paths.socket)
        let hookConfiguration = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: install.file))
        func runConfiguredCopilotHook(_ event: String, _ body: [String: JSONValue]) throws {
            let command = try XCTUnwrap(hookConfiguration["hooks"]?[event]?.array?.last?["bash"]?.string)
            let hook = Process()
            let input = Pipe(), output = Pipe(), error = Pipe()
            hook.executableURL = URL(fileURLWithPath: "/bin/sh")
            hook.arguments = ["-c", command]
            hook.standardInput = input; hook.standardOutput = output; hook.standardError = error
            try hook.run()
            try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(JSONValue.object(body)))
            try input.fileHandleForWriting.close()
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = error.fileHandleForReading.readDataToEndOfFile()
            hook.waitUntilExit()
            XCTAssertEqual(hook.terminationStatus, 0, String(decoding: stderr, as: UTF8.self))
            XCTAssertTrue(stdout.isEmpty, "A status hook must not return a Copilot permission decision.")
            XCTAssertTrue(stderr.isEmpty, String(decoding: stderr, as: UTF8.self))
        }
        let identity: [String: JSONValue] = [
            "session_id": .string("live-copilot"), "cwd": .string(root.path),
            "session_title": .string("Copilot native integration")
        ]
        try runConfiguredCopilotHook("UserPromptSubmit", identity)
        _ = try assertState("Working")
        var question: [String: JSONValue] = [
            "hook_event_name": .string("Notification"), "sessionId": .string("live-copilot"),
            "cwd": .string(root.path)
        ]
        question["notification_type"] = .string("elicitation_dialog")
        question["message"] = .string("Choose an environment")
        try runConfiguredCopilotHook("Notification", question)
        _ = try assertState("Ask")
        question["notification_type"] = .string("shell_completed")
        try runConfiguredCopilotHook("Notification", question)
        _ = try assertState("Ask")
        try runConfiguredCopilotHook("PostToolUse", identity)
        _ = try assertState("Working")
        let transcript = root.appendingPathComponent("copilot-events.jsonl")
        try Data(#"{"type":"assistant.message","data":{"content":"Which environment should I use?"}}"#.utf8).write(to: transcript)
        var stop = identity
        stop["transcript_path"] = .string(transcript.path)
        try runConfiguredCopilotHook("Stop", stop)
        _ = try assertState("Ask")
        try Data(#"{"type":"assistant.message","data":{"content":"Implementation complete."}}"#.utf8).write(to: transcript)
        try runConfiguredCopilotHook("Stop", stop)
        _ = try assertState("Done")
        _ = try request("capture-hooks")
        _ = try HookConfiguration.install(provider: .copilot, home: home, helper: helper, socket: paths.socket, removing: true)
        XCTAssertFalse(HookConfiguration.isInstalled(provider: .copilot, home: home))
        _ = try request("quit")
        restarted.waitUntilExit()
    }
}
