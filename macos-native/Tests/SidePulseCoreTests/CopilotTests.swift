import Foundation
import XCTest
@testable import SidePulseCore

final class CopilotTests: XCTestCase {
    private func event(_ name: String, fields: [String: JSONValue] = [:], at date: Date = Date()) throws -> NormalizedEvent {
        var raw: [String: JSONValue] = ["hook_event_name": .string(name), "session_id": .string("copilot-test")]
        raw.merge(fields) { _, next in next }
        return try EventNormalizer.normalize(HookEnvelope(provider: .copilot, line: .object(raw)), receivedAt: date)
    }

    func testCopilotTestingModeOnlyAllowsCopilotHooks() {
        for provider in Provider.allCases {
            XCTAssertEqual(ApplicationMode.copilotTesting.permitsHookChanges(for: provider), provider == .copilot)
            XCTAssertFalse(ApplicationMode.preview.permitsHookChanges(for: provider))
            XCTAssertTrue(ApplicationMode.standard.permitsHookChanges(for: provider))
        }
        XCTAssertTrue(ApplicationMode.copilotTesting.restrictsSystemChanges)
        XCTAssertFalse(ApplicationMode.copilotTesting.permitsRemotes)
        XCTAssertFalse(ApplicationMode.copilotTesting.permitsSimulation)
    }

    func testAttentionNotificationsAskWithoutBackgroundNotificationsOverwritingState() throws {
        let now = Date()
        for kind in ["permission_prompt", "elicitation_dialog"] {
            let store = SessionStore()
            store.ingest(try event("UserPromptSubmit", at: now))
            store.ingest(try event("Notification", fields: [
                "notification_type": .string(kind), "message": .string("Choose an environment")
            ], at: now.addingTimeInterval(1)))
            XCTAssertEqual(store.snapshot(at: now.addingTimeInterval(1)).state, .ask)
            for background in ["agent_completed", "agent_idle", "shell_completed", "shell_detached_completed"] {
                XCTAssertFalse(store.ingest(try event("Notification", fields: [
                    "notification_type": .string(background), "message": .string("Background work completed")
                ], at: now.addingTimeInterval(2))))
                XCTAssertEqual(store.snapshot(at: now.addingTimeInterval(2)).state, .ask)
            }
            store.ingest(try event("PostToolUse", at: now.addingTimeInterval(3)))
            XCTAssertEqual(store.snapshot(at: now.addingTimeInterval(3)).state, .working)
        }
    }

    func testLegacyInputGetsItsEventFromTheConfiguredCommand() throws {
        let input = JSONValue.object(["sessionId": .string("legacy"), "cwd": .string("/work"), "prompt": .string("Start")])
        let prepared = try CopilotHookInput.prepare(input, fallbackEvent: "userPromptSubmitted")
        let normalized = try EventNormalizer.normalize(HookEnvelope(provider: .copilot, line: prepared))
        XCTAssertEqual(normalized.session.event, "UserPromptSubmit")
        XCTAssertEqual(normalized.session.mode, .working)
        XCTAssertEqual(normalized.session.sessionID, "legacy")
    }

    func testDelayedNotificationsUseCopilotsEventTimeRatherThanHelperLaunchTime() throws {
        let now = Date()
        let store = SessionStore()
        store.ingest(try event("PostToolUse", fields: [
            "timestamp": .number(now.timeIntervalSince1970 * 1000)
        ], at: now))
        let delayed = try event("Notification", fields: [
            "timestamp": .number(now.addingTimeInterval(-1).timeIntervalSince1970 * 1000),
            "logged_at": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(1))),
            "notification_type": .string("permission_prompt"),
            "title": .string("Permission needed"), "cwd": .string("/work/project")
        ], at: now.addingTimeInterval(1))
        XCTAssertFalse(store.ingest(delayed))
        XCTAssertEqual(store.snapshot(at: now.addingTimeInterval(1)).state, .working)
        XCTAssertEqual(delayed.session.title, "project")
        let failure = try event("ErrorOccurred", fields: [
            "recoverable": .bool(false), "error": .object(["message": .string("The operation failed.")])
        ])
        XCTAssertEqual(failure.session.message, "The operation failed.")
    }

    func testStopUsesTheLatestAssistantMessageFromEitherCopilotTranscriptFormat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spn-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl")
        let formats = [
            """
            {"type":"user.message","data":{"content":"Start"}}
            {"type":"assistant.message","data":{"content":"Which environment should I use?"}}
            {"type":"assistant.turn_end","data":{}}
            """,
            """
            {"type":"user","message":{"content":"Start"}}
            {"type":"assistant","message":{"content":[{"type":"text","text":"Which environment should I use?"}]}}
            """
        ]
        for transcript in formats {
            try Data((transcript + "\n").utf8).write(to: file)
            let input = JSONValue.object(["session_id": .string("transcript"), "transcript_path": .string(file.path)])
            let prepared = try CopilotHookInput.prepare(input, fallbackEvent: "Stop")
            let normalized = try EventNormalizer.normalize(HookEnvelope(provider: .copilot, line: prepared))
            XCTAssertEqual(normalized.session.mode, .waiting)
            XCTAssertEqual(normalized.session.message, "Which environment should I use?")
        }
        try Data("""
        {"type":"assistant.message","data":{"content":"An old question?"}}
        {"type":"user.message","data":{"content":"A new task"}}
        """.utf8).write(to: file)
        XCTAssertNil(try CopilotHookInput.lastAssistantMessage(at: file))
    }

    func testTranscriptTailIsBoundedAndExplicitMessagesArePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spn-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl")
        let text = String(repeating: "x", count: CopilotHookInput.transcriptReadLimit + 100) +
            "\n" + #"{"type":"assistant.message","data":{"content":"Finished."}}"# + "\n"
        try Data(text.utf8).write(to: file)
        XCTAssertEqual(try CopilotHookInput.lastAssistantMessage(at: file), "Finished.")
        let input = JSONValue.object([
            "hook_event_name": .string("Stop"), "last_assistant_message": .string("Explicit reply"),
            "transcript_path": .string(root.appendingPathComponent("missing").path)
        ])
        XCTAssertEqual(try CopilotHookInput.prepare(input, fallbackEvent: nil), input)
    }

    func testMetadataFailuresAreReportedWithoutLosingTheEventIdentity() throws {
        var reported = false
        let input = JSONValue.object(["event": .object(["transcript_path": .string("relative-file")])])
        let prepared = try CopilotHookInput.prepare(input, fallbackEvent: "Stop") { _ in reported = true }
        XCTAssertTrue(reported)
        XCTAssertEqual(prepared["event"]?["hook_event_name"]?.string, "Stop")
        XCTAssertThrowsError(try CopilotHookInput.prepare(.object([:]), fallbackEvent: "not-a-hook"))
    }

    func testCopilotConfigurationRequestsCompatiblePayloadsAndPreservesOtherHooks() throws {
        let helper = URL(fileURLWithPath: "/Applications/SidePulse's Native.app/Contents/Helpers/SidePulseHook")
        let socket = URL(fileURLWithPath: "/tmp/native/events.sock")
        let original = #"{"version":1,"other":true,"hooks":{"userPromptSubmitted":[{"type":"command","bash":"echo keep-me"}]}}"#
        let rendered = try HookConfiguration.render(provider: .copilot, original: original, helper: helper, socket: socket)
        let configuration = try JSONDecoder().decode(JSONValue.self, from: Data(rendered.utf8))
        XCTAssertEqual(configuration["other"]?.bool, true)
        XCTAssertEqual(configuration["hooks"]?["userPromptSubmitted"]?.array?.first?["bash"]?.string, "echo keep-me")
        let hook = try XCTUnwrap(configuration["hooks"]?["UserPromptSubmit"]?.array?.last)
        XCTAssertNil(hook["useVSCodeFormat"])
        XCTAssertEqual(hook["timeoutSec"]?.number, 5)
        XCTAssertTrue(hook["bash"]?.string?.contains("--event 'UserPromptSubmit'") == true)
        XCTAssertTrue(hook["bash"]?.string?.contains("Copilot will continue.") == true)
    }

    func testMissingNativeHelperCannotDenyCopilotTools() throws {
        let missing = URL(fileURLWithPath: "/tmp/native-missing-\(UUID().uuidString)/SidePulseHook")
        let command = try HookConfiguration.command(provider: .copilot, helper: missing,
                                                     socket: URL(fileURLWithPath: "/tmp/unused"), event: "PreToolUse")
        let process = Process()
        let output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = error
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(stdout.isEmpty)
        XCTAssertTrue(String(decoding: stderr, as: UTF8.self).contains("Copilot will continue."))
    }
}
