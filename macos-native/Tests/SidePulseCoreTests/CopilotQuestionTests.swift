import Foundation
import XCTest
@testable import SidePulseCore

final class CopilotQuestionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func event(_ name: String, id: String = "one", provider: Provider = .copilot,
                       offset: Double = 0, fields: [String: JSONValue] = [:]) throws -> NormalizedEvent {
        var raw: [String: JSONValue] = ["hook_event_name": .string(name), "session_id": .string(id)]
        raw.merge(fields) { _, next in next }
        return try EventNormalizer.normalize(HookEnvelope(provider: provider, line: .object(raw)),
                                             receivedAt: now.addingTimeInterval(offset))
    }

    private func snapshot(_ store: SessionStore, after seconds: Double = 10) -> MonitorSnapshot {
        store.snapshot(at: now.addingTimeInterval(seconds))
    }

    func testQuestionToolAliasesAskWithoutNotifications() throws {
        for (name, field) in [("AskUserQuestion", "tool_name"), ("ask_user", "toolName")] {
            let store = SessionStore()
            let question = try event("PreToolUse", fields: [field: .string(name)])
            XCTAssertEqual(question.session.mode, .waiting)
            store.ingest(question)
            XCTAssertEqual(snapshot(store).state, .ask)
            XCTAssertEqual(snapshot(store).activeCount, 1)
            for count in [2, 8] {
                XCTAssertEqual(LEDProgram.status(snapshot(store).state, count: count),
                               "off\n#FF3A00 1.6s pulse\nrepeat")
            }
            XCTAssertEqual(store.persistentSessions.first?.pendingQuestions?.count, 1)
            store.ingest(try event("PostToolUse", offset: 1, fields: ["toolName": .string("ask_user")]))
            XCTAssertEqual(snapshot(store).state, .working)
            XCTAssertNil(store.persistentSessions.first?.pendingQuestions)
        }
    }

    func testOnlyCopilotQuestionToolsAreTracked() throws {
        for tool in ["Bash", "ask_user_status", "mcp__server__ask_user"] {
            let value = try event("PreToolUse", fields: ["tool_name": .string(tool)])
            XCTAssertEqual(value.session.mode, .tool)
            XCTAssertNil(value.questionKey)
        }
        for provider in Provider.hookProviders where provider != .copilot {
            let value = try event("PreToolUse", provider: provider, fields: ["tool_name": .string("AskUserQuestion")])
            XCTAssertEqual(value.session.mode, .tool)
            XCTAssertNil(value.questionKey)
        }
    }

    func testCallIDsMatchEvenWhenTheResultOmitsTheToolName() throws {
        for field in ["tool_use_id", "toolUseId", "tool_call_id", "toolCallId", "call_id"] {
            let store = SessionStore()
            store.ingest(try event("PreToolUse", fields: [
                "tool_name": .string("AskUserQuestion"), field: .string("question")
            ]))
            store.ingest(try event("PostToolUse", offset: 1, fields: [field: .string("unrelated")]))
            XCTAssertEqual(snapshot(store).state, .ask)
            store.ingest(try event("PostToolUse", offset: 2, fields: [field: .string("question")]))
            XCTAssertEqual(snapshot(store).state, .working)
            XCTAssertNil(store.persistentSessions.first?.pendingQuestions)
        }
    }

    func testArgumentsCorrelateConcurrentFormsAcrossHookFormats() throws {
        let store = SessionStore()
        let schema = JSONValue.object(["properties": .object(["answer": .object(["type": .string("string")])])])
        let first = JSONValue.object(["message": .string("First form"), "requestedSchema": schema])
        let second = JSONValue.object(["message": .string("Second form"), "requestedSchema": schema])
        let question = try event("PreToolUse", fields: [
            "tool_name": .string("AskUserQuestion"), "tool_input": first
        ])
        let answer = try event("PostToolUse", offset: 2, fields: [
            "toolName": .string("ask_user"),
            "toolArgs": .object(["requestedSchema": schema, "message": .string("First form")])
        ])
        XCTAssertEqual(question.questionKey, answer.questionKey)
        XCTAssertFalse(try XCTUnwrap(question.questionKey).contains("First form"))
        store.ingest(question)
        store.ingest(try event("PreToolUse", offset: 1, fields: [
            "toolName": .string("ask_user"), "toolArgs": second
        ]))
        XCTAssertEqual(store.persistentSessions.first?.pendingQuestions?.count, 2)
        store.ingest(answer)
        XCTAssertEqual(snapshot(store).state, .ask)
        XCTAssertEqual(store.persistentSessions.first?.pendingQuestions?.count, 1)
        store.ingest(try event("PostToolUse", offset: 3, fields: [
            "tool_name": .string("AskUserQuestion"), "tool_input": second
        ]))
        XCTAssertEqual(snapshot(store).state, .working)
        XCTAssertNil(store.persistentSessions.first?.pendingQuestions)
    }

    func testUnrelatedActivityCannotClearAQuestionOrSettleItToDone() throws {
        let store = SessionStore()
        store.ingest(try event("PreToolUse", fields: [
            "tool_name": .string("AskUserQuestion"), "sidepulse_status": .string("done")
        ]))
        store.ingest(try event("PreToolUse", offset: 1, fields: ["tool_name": .string("Bash")]))
        store.ingest(try event("PostToolUse", offset: 2, fields: ["tool_name": .string("Bash")]))
        let source = try XCTUnwrap(store.persistentSessions.first)
        XCTAssertEqual(source.mode, .working)
        XCTAssertEqual(source.updatedAt, now.addingTimeInterval(2))
        XCTAssertEqual(source.postToolUseSettlesAt, now.addingTimeInterval(122))
        XCTAssertEqual(snapshot(store, after: 123).state, .ask)
        for kind in ["agent_idle", "agent_completed", "shell_completed"] {
            XCTAssertFalse(store.ingest(try event("Notification", offset: 124, fields: [
                "notification_type": .string(kind)
            ])))
        }
        store.ingest(try event("Stop", offset: 125, fields: ["last_assistant_message": .string("Finished.")]))
        store.ingest(try event("UserPromptSubmit", id: "other", offset: 126))
        XCTAssertEqual(snapshot(store, after: 127).state, .ask)
        XCTAssertEqual(snapshot(store, after: 127).activeCount, 2)
        store.ingest(try event("PostToolUse", offset: 128, fields: ["tool_name": .string("AskUserQuestion")]))
        XCTAssertEqual(snapshot(store, after: 129).state, .working)
    }

    func testCLINotificationAndQuestionToolShareOnePendingQuestion() throws {
        let store = SessionStore()
        store.ingest(try event("PreToolUse", fields: ["toolName": .string("ask_user")]))
        store.ingest(try event("Notification", offset: 1, fields: [
            "notification_type": .string("elicitation_dialog")
        ]))
        store.ingest(try event("PostToolUse", offset: 2, fields: ["tool_name": .string("Bash")]))
        XCTAssertEqual(snapshot(store).state, .ask)
        XCTAssertEqual(store.persistentSessions.first?.pendingQuestions?.count, 1)
        store.ingest(try event("PostToolUse", offset: 3, fields: ["tool_name": .string("AskUserQuestion")]))
        XCTAssertEqual(snapshot(store).state, .working)
    }

    func testQuestionAndPermissionWaitsRemainIndependent() throws {
        let store = SessionStore()
        store.ingest(try event("PreToolUse", fields: ["tool_name": .string("AskUserQuestion")]))
        store.ingest(try event("PermissionRequest", offset: 1, fields: ["tool_use_id": .string("approval")]))
        store.ingest(try event("PostToolUse", offset: 2, fields: ["tool_use_id": .string("approval")]))
        XCTAssertEqual(snapshot(store).state, .ask)
        XCTAssertTrue(try XCTUnwrap(store.persistentSessions.first).pendingPermissions.isEmpty)
        XCTAssertEqual(store.persistentSessions.first?.pendingQuestions?.count, 1)
        store.ingest(try event("PostToolUse", offset: 3, fields: ["toolName": .string("ask_user")]))
        XCTAssertEqual(snapshot(store).state, .working)
    }

    func testLateAnswerClearsOnlyItsQuestionWithoutRewindingNewerActivity() throws {
        let store = SessionStore()
        store.ingest(try event("PreToolUse", fields: ["tool_name": .string("AskUserQuestion")]))
        store.ingest(try event("PreToolUse", offset: 3, fields: ["tool_name": .string("Bash")]))
        let before = try XCTUnwrap(store.persistentSessions.first)
        XCTAssertTrue(store.ingest(try event("PostToolUse", offset: 2, fields: ["toolName": .string("ask_user")])))
        let after = try XCTUnwrap(store.persistentSessions.first)
        XCTAssertEqual(snapshot(store).state, .working)
        XCTAssertNil(after.pendingQuestions)
        XCTAssertEqual(after.updatedAt, before.updatedAt)
        XCTAssertEqual(after.observedAt, before.observedAt)
        XCTAssertEqual(after.copilotActivityAt, before.copilotActivityAt)
        XCTAssertEqual(after.event, before.event)
        XCTAssertEqual(after.tool, before.tool)
    }

    func testOldAnswerCannotClearANewerQuestionWithTheSameArguments() throws {
        let store = SessionStore()
        let fields: [String: JSONValue] = [
            "toolName": .string("ask_user"), "toolArgs": .object(["message": .string("Choose a target")])
        ]
        store.ingest(try event("PreToolUse", fields: fields))
        store.ingest(try event("PreToolUse", offset: 3, fields: fields))
        XCTAssertFalse(store.ingest(try event("PostToolUse", offset: 2, fields: fields)))
        XCTAssertEqual(snapshot(store).state, .ask)
        XCTAssertEqual(Array(try XCTUnwrap(store.persistentSessions.first?.pendingQuestions).values),
                       [now.addingTimeInterval(3)])
        store.ingest(try event("PostToolUse", offset: 4, fields: fields))
        XCTAssertEqual(snapshot(store).state, .working)
    }

    func testQuestionFailuresClearPendingWaitButPreserveTheErrorState() throws {
        for name in ["PostToolUseFailure", "PermissionDenied"] {
            let store = SessionStore()
            store.ingest(try event("PreToolUse", fields: ["tool_name": .string("AskUserQuestion")]))
            store.ingest(try event(name, offset: 1, fields: ["toolName": .string("ask_user")]))
            XCTAssertNil(store.persistentSessions.first?.pendingQuestions)
            XCTAssertEqual(snapshot(store).sessions.first?.mode, .blocked)
        }
    }

    func testSessionBoundariesAndRootCancellationClearPendingQuestions() throws {
        for (name, expected) in [("SessionStart", DisplayState.idle), ("UserPromptSubmit", .working), ("SessionEnd", .done)] {
            let store = SessionStore()
            store.ingest(try event("PreToolUse", fields: ["tool_name": .string("AskUserQuestion")]))
            store.ingest(try event(name, offset: 1))
            XCTAssertNil(store.persistentSessions.first?.pendingQuestions)
            XCTAssertEqual(snapshot(store).state, expected)
        }
        for useSignal in [false, true] {
            let store = SessionStore()
            store.ingest(try event("PreToolUse", fields: ["tool_name": .string("AskUserQuestion")]))
            store.ingest(try event("PermissionRequest", offset: 1))
            store.ingest(try event("UserPromptSubmit", id: "other"))
            if useSignal {
                XCTAssertTrue(store.ingest(CopilotSessionSignal(
                    sessionID: "one", file: URL(fileURLWithPath: "/tmp/session-state/one/events.jsonl"),
                    kind: .aborted, timestamp: now.addingTimeInterval(2)
                )))
            } else {
                store.ingest(try event("SessionEnd", offset: 2, fields: ["reason": .string("abort")]))
            }
            let cancelled = try XCTUnwrap(store.persistentSessions.first { $0.sessionID == "one" })
            XCTAssertNil(cancelled.pendingQuestions)
            XCTAssertTrue(cancelled.pendingPermissions.isEmpty)
            XCTAssertEqual(cancelled.mode, .idle)
            XCTAssertEqual(snapshot(store).state, .working)
            XCTAssertFalse(store.ingest(try event("PostToolUse", offset: 3, fields: ["tool_name": .string("AskUserQuestion")])))
        }
    }

    func testQuestionPersistenceAndLegacySessions() throws {
        let store = SessionStore()
        store.ingest(try event("PreToolUse", fields: ["tool_name": .string("AskUserQuestion")]))
        store.ingest(try event("PostToolUse", offset: 1, fields: ["tool_name": .string("Bash")]))
        let data = try JSONCoding.encoder().encode(store.persistentSessions)
        let restored = SessionStore(sessions: try JSONCoding.decoder().decode([AgentSession].self, from: data))
        XCTAssertEqual(snapshot(restored, after: 122).state, .ask)
        restored.ingest(try event("PostToolUse", offset: 123, fields: ["toolName": .string("ask_user")]))
        XCTAssertEqual(snapshot(restored, after: 124).state, .working)
        var legacy = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: data).array?.first?.object)
        legacy.removeValue(forKey: "pendingQuestions")
        let session = try JSONCoding.decoder().decode(AgentSession.self, from: JSONEncoder().encode(JSONValue.object(legacy)))
        XCTAssertNil(session.pendingQuestions)
        XCTAssertEqual(snapshot(SessionStore(sessions: [session])).state, .working)
    }

    func testUnrelatedActivityDoesNotExtendTheQuestionTimeout() throws {
        let store = SessionStore()
        store.staleAfter = 60
        store.ingest(try event("PreToolUse", fields: ["tool_name": .string("AskUserQuestion")]))
        XCTAssertEqual(snapshot(store, after: 60).state, .ask)
        XCTAssertEqual(snapshot(store, after: 61).state, .idle)
        store.ingest(try event("PreToolUse", offset: 62, fields: ["tool_name": .string("Bash")]))
        XCTAssertEqual(snapshot(store, after: 63).state, .working)
        store.ingest(try event("PreToolUse", offset: 64, fields: ["toolName": .string("ask_user")]))
        XCTAssertEqual(snapshot(store, after: 65).state, .ask)
    }
}
