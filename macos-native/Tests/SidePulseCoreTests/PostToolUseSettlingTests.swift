import Foundation
import XCTest
@testable import SidePulseCore

final class PostToolUseSettlingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func event(_ name: String = "PostToolUse", provider: Provider = .copilot, id: String = "one",
                       fields: [String: JSONValue] = [:], offset: TimeInterval = 0) throws -> NormalizedEvent {
        var raw: [String: JSONValue] = [
            "hook_event_name": .string(name), "session_id": .string(id), "cwd": .string("/tmp/project")
        ]
        raw.merge(fields) { _, new in new }
        return try EventNormalizer.normalize(HookEnvelope(provider: provider, line: .object(raw)),
                                             receivedAt: now.addingTimeInterval(offset))
    }

    private func snapshot(_ store: SessionStore, after seconds: TimeInterval) -> MonitorSnapshot {
        store.snapshot(at: now.addingTimeInterval(seconds))
    }

    func testImplicitPostToolUseSettlesForEveryLocalProvider() throws {
        for provider in Provider.hookProviders {
            let store = SessionStore()
            store.ingest(try event(provider: provider, fields: ["tool_response": .object(["success": .bool(true)])]))
            for seconds in [0, 119.999, 120] {
                let working = snapshot(store, after: seconds)
                XCTAssertEqual(working.state, .working, provider.rawValue)
                XCTAssertEqual(working.activeCount, 1)
            }
            let done = snapshot(store, after: 120.001)
            XCTAssertEqual(done.state, .done, provider.rawValue)
            XCTAssertEqual(done.activeCount, 0)
            XCTAssertEqual(done.sessions.first?.mode, .completed)
            XCTAssertEqual(done.sessions.first?.statusLabel, "Done")
            XCTAssertEqual(done.listSections.map(\.title), ["Recent"])
        }
    }

    func testDoneDurationStartsAtTheFixedSettlingBoundary() throws {
        for duration in [0.0, 60, 300, 1200] {
            let store = SessionStore()
            store.doneVisible = duration
            store.ingest(try event())
            XCTAssertEqual(snapshot(store, after: 120).state, .working)
            XCTAssertEqual(snapshot(store, after: 120.001).state, duration == 0 ? .idle : .done)
            if duration > 0 {
                XCTAssertEqual(snapshot(store, after: 120 + duration).state, .done)
            }
            let expired = snapshot(store, after: 120 + duration + 0.001)
            XCTAssertEqual(expired.state, .idle)
            XCTAssertEqual(expired.activeCount, 0)
            XCTAssertEqual(snapshot(store, after: 121 + duration).state, .idle)
        }
    }

    func testSnapshotsDoNotRewriteTheEventOrReplayCompletion() throws {
        let store = SessionStore()
        store.doneVisible = 60
        store.ingest(try event())
        let original = store.persistentSessions
        let working = snapshot(store, after: 120)
        let done = snapshot(store, after: 121)
        let later = snapshot(store, after: 179)
        let idle = snapshot(store, after: 181)
        XCTAssertFalse(done.hasSamePresentation(as: working))
        XCTAssertTrue(later.hasSamePresentation(as: done))
        XCTAssertFalse(idle.hasSamePresentation(as: later))
        XCTAssertEqual(done.sessions.first?.updatedAt, now)
        XCTAssertEqual(done.sessions.first?.observedAt, now)
        XCTAssertEqual(done.sessions.first?.event, "PostToolUse")
        XCTAssertEqual(store.persistentSessions, original)
        XCTAssertEqual(store.persistentSessions.first?.mode, .working)
    }

    func testNewActivityCancelsSettlingWithoutTimingOutLongRunningWork() throws {
        for name in ["PreToolUse", "UserPromptSubmit", "PreCompact", "PostCompact", "SubagentStart", "Notification"] {
            let store = SessionStore()
            store.ingest(try event())
            store.ingest(try event(name, offset: 119))
            let active = snapshot(store, after: 500)
            XCTAssertEqual(active.state, .working, name)
            XCTAssertEqual(active.activeCount, 1)
            XCTAssertEqual(active.sessions.first?.mode, name == "PreToolUse" ? .tool : .working)
        }
    }

    func testAnotherToolCompletionRestartsTheSettlingInterval() throws {
        let store = SessionStore()
        store.ingest(try event())
        store.ingest(try event(offset: 119))
        XCTAssertEqual(snapshot(store, after: 121).state, .working)
        XCTAssertEqual(snapshot(store, after: 239).state, .working)
        XCTAssertEqual(snapshot(store, after: 239.001).state, .done)
        XCTAssertEqual(store.persistentSessions.first?.updatedAt, now.addingTimeInterval(119))
    }

    func testDelayedNewerActivityCanReplaceInferredDoneButOlderEventsCannot() throws {
        let store = SessionStore()
        store.ingest(try event())
        XCTAssertEqual(snapshot(store, after: 121).state, .done)
        XCTAssertTrue(store.ingest(try event("PreToolUse", offset: 100)))
        XCTAssertEqual(snapshot(store, after: 122).state, .working)
        XCTAssertFalse(store.ingest(try event(offset: 99)))
        XCTAssertEqual(snapshot(store, after: 400).sessions.first?.mode, .tool)
    }

    func testExplicitModesAndMarkersRetainTheirNormalExpiryAfterReload() throws {
        for mode in AgentMode.allCases {
            for key in ["sidepulse_status", "sidepulse_mode"] {
                let store = SessionStore()
                store.ingest(try event(fields: [key: .string(mode.rawValue)]))
                let data = try JSONCoding.encoder().encode(store.persistentSessions)
                let restored = SessionStore(sessions: try JSONCoding.decoder().decode([AgentSession].self, from: data))
                XCTAssertEqual(snapshot(restored, after: 121).sessions.first?.mode, mode, "\(key): \(mode)")
            }
        }
        for message in [
            "<!-- sidepulse: working -->",
            "[sidepulse status: working]",
            "[sidepulse:working]",
            "<!-- agent-monitor mode: working -->",
            String(repeating: "Context. ", count: 300) + "\n<!-- sidepulse: working -->"
        ] {
            let store = SessionStore()
            store.ingest(try event(fields: ["last_assistant_message": .string(message)]))
            let data = try JSONCoding.encoder().encode(store.persistentSessions)
            let restored = SessionStore(sessions: try JSONCoding.decoder().decode([AgentSession].self, from: data))
            XCTAssertEqual(snapshot(restored, after: 121).state, .working)
            XCTAssertEqual(snapshot(restored, after: 3601).state, .idle)
        }
    }

    func testOnlyAnExplicitModeOnTheCurrentEventSuppressesSettling() throws {
        for fields in [
            ["sidepulse_status": JSONValue.string("unrecognized")],
            ["last_assistant_message": .string("```\n<!-- sidepulse: working -->\n```")],
            ["last_assistant_message": .string("~~~\n[sidepulse:working]\n~~~")]
        ] {
            let store = SessionStore()
            store.ingest(try event(fields: fields))
            XCTAssertEqual(snapshot(store, after: 121).state, .done)
        }
        let store = SessionStore()
        store.ingest(try event(fields: ["message": .string("<!-- sidepulse: working -->")]))
        store.ingest(try event(offset: 1))
        XCTAssertEqual(store.persistentSessions.first?.message, "<!-- sidepulse: working -->")
        XCTAssertEqual(snapshot(store, after: 122).state, .done)
    }

    func testUnresolvedPermissionsPreventSettlingUntilTheMatchingToolFinishes() throws {
        let store = SessionStore()
        store.ingest(try event("PermissionRequest", fields: ["tool_use_id": .string("approval")]))
        store.ingest(try event(fields: ["tool_use_id": .string("unrelated")], offset: 1))
        let waiting = snapshot(store, after: 122)
        XCTAssertEqual(waiting.state, .ask)
        XCTAssertEqual(waiting.activeCount, 1)
        XCTAssertEqual(waiting.sessions.first?.pendingPermissions, ["approval"])
        store.ingest(try event(fields: ["tool_use_id": .string("approval")], offset: 130))
        XCTAssertEqual(snapshot(store, after: 250).state, .working)
        XCTAssertEqual(snapshot(store, after: 250.001).state, .done)
    }

    func testErrorsAndQuestionsAreNeverSettledToDone() throws {
        let events = [
            try event(fields: ["tool_response": .object(["success": .bool(false)])]),
            try event(fields: ["toolResponse": .object(["is_error": .bool(true)])]),
            try event("PostToolUseFailure"), try event("PermissionDenied"), try event("StopFailure"),
            try event("ErrorOccurred", fields: ["recoverable": .bool(false)]),
            try event("Stop", fields: ["last_assistant_message": .string("Which option?")]),
            try event("Notification", fields: ["notification_type": .string("elicitation_dialog")])
        ]
        for event in events {
            let store = SessionStore()
            store.ingest(event)
            XCTAssertEqual(snapshot(store, after: 121).state, .ask, event.session.event)
        }
    }

    func testRealStopUsesItsOwnTimestampAndCanStillAskAQuestion() throws {
        let store = SessionStore()
        store.doneVisible = 60
        store.ingest(try event())
        XCTAssertEqual(snapshot(store, after: 121).state, .done)
        store.ingest(try event("Stop", offset: 130))
        XCTAssertEqual(snapshot(store, after: 181).state, .done)
        XCTAssertEqual(snapshot(store, after: 190.001).state, .idle)
        store.ingest(try event("Stop", fields: ["last_assistant_message": .string("Which option?")], offset: 200))
        XCTAssertEqual(snapshot(store, after: 321).state, .ask)
    }

    func testOtherActiveSessionsStillWinAggregation() throws {
        let store = SessionStore()
        store.ingest(try event())
        store.ingest(try event("PreToolUse", id: "busy"))
        store.ingest(try event("PermissionRequest", id: "waiting"))
        let ask = snapshot(store, after: 121)
        XCTAssertEqual(ask.state, .ask)
        XCTAssertEqual(ask.activeCount, 2)
        XCTAssertEqual(ask.sessions.first { $0.sessionID == "one" }?.mode, .completed)
        store.remove(id: "copilot:session:waiting")
        XCTAssertEqual(snapshot(store, after: 121).state, .working)
        XCTAssertEqual(snapshot(store, after: 121).activeCount, 1)
        store.remove(id: "copilot:session:busy")
        XCTAssertEqual(snapshot(store, after: 121).state, .done)
    }

    func testStaleExpiryWinsWithoutResurrectingExpiredSessions() throws {
        for timeout in [30.0, 120, 150] {
            let store = SessionStore()
            store.staleAfter = timeout
            store.ingest(try event())
            if timeout > 120 { XCTAssertEqual(snapshot(store, after: 121).state, .done) }
            XCTAssertEqual(snapshot(store, after: timeout + 0.001).state, .idle)
            XCTAssertEqual(snapshot(store, after: 500).state, .idle)
        }
    }

    func testRemoteHeartbeatsDoNotUseTheLocalFallback() throws {
        var session = try event().session
        session.remoteID = "remote"
        session.observedAt = now.addingTimeInterval(500)
        let store = SessionStore()
        store.reconcile(remoteID: "remote", sessions: [session])
        XCTAssertEqual(snapshot(store, after: 500).state, .working)
        XCTAssertEqual(snapshot(store, after: 516).state, .idle)
    }

    func testIgnoredCopilotNotificationsDoNotRestartSettling() throws {
        let store = SessionStore()
        store.ingest(try event())
        XCTAssertFalse(store.ingest(try event("Notification", fields: [
            "notification_type": .string("shell_completed"), "message": .string("Background work completed")
        ], offset: 119)))
        XCTAssertEqual(snapshot(store, after: 121).state, .done)
    }

    func testCopilotEventTimeAndFutureTimestampClampingArePreserved() throws {
        let store = SessionStore()
        store.ingest(try event(fields: [
            "timestamp": .number(now.timeIntervalSince1970 * 1000),
            "logged_at": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(100)))
        ], offset: 100))
        XCTAssertEqual(snapshot(store, after: 121).state, .done)

        let future = SessionStore()
        future.ingest(try event(fields: ["timestamp": .number(now.addingTimeInterval(500).timeIntervalSince1970 * 1000)]))
        XCTAssertEqual(snapshot(future, after: 120).state, .working)
        XCTAssertEqual(snapshot(future, after: 121).state, .done)
    }

    func testEventTimeAndPersistenceKeepTheOriginalSettlingDeadline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spn-settle-\(UUID().uuidString)")
        let paths = NativePaths(root: root)
        try paths.prepare()
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not clean up settling fixture: \(error)") }
        }
        let store = SessionStore()
        store.doneVisible = 60
        store.ingest(try event(fields: ["logged_at": .string(ISO8601DateFormatter().string(from: now))], offset: 150))
        try Persistence.save(store.persistentSessions, to: paths.sessions)
        let saved = try XCTUnwrap(Persistence.load([AgentSession].self, from: paths.sessions))
        XCTAssertEqual(saved.first?.updatedAt, now)
        XCTAssertEqual(saved.first?.mode, .working)
        for seconds in [119.0, 121, 180, 181] {
            let restored = SessionStore(sessions: saved)
            restored.doneVisible = 60
            XCTAssertEqual(snapshot(restored, after: seconds).state, snapshot(store, after: seconds).state)
        }
        let restored = SessionStore(sessions: saved)
        restored.doneVisible = 60
        XCTAssertEqual(snapshot(restored, after: 150).state, .done)
        XCTAssertEqual(snapshot(restored, after: 181).state, .idle)
    }

    func testLegacySessionsWithoutSettlingProvenanceKeepTheirOldBehavior() throws {
        let data = try JSONCoding.encoder().encode(try event().session)
        var object = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: data).object)
        object.removeValue(forKey: "postToolUseSettlesAt")
        let legacy = try JSONCoding.decoder().decode(AgentSession.self, from: JSONEncoder().encode(JSONValue.object(object)))
        let store = SessionStore(sessions: [legacy])
        XCTAssertEqual(snapshot(store, after: 121).state, .working)
        XCTAssertEqual(snapshot(store, after: 3601).state, .idle)
        store.ingest(try event(offset: 3602))
        XCTAssertEqual(snapshot(store, after: 3723).state, .done)

        object["postToolUseSettlesAt"] = .string("invalid-date")
        XCTAssertThrowsError(try JSONCoding.decoder().decode(AgentSession.self, from: JSONEncoder().encode(JSONValue.object(object))))
    }
}
