import Darwin
import Foundation
import XCTest
@testable import SidePulseCore

final class CopilotCancellationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("spn-cancel-\(UUID().uuidString)")
    private var directory: URL { root.appendingPathComponent("session-state") }

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func event(_ name: String = "UserPromptSubmit", id: String = "one", offset: Double = 0,
                       fields: [String: JSONValue] = [:], directory: URL? = nil) throws -> NormalizedEvent {
        let file = try CopilotCancellationReader.eventFile(sessionID: id, directory: directory ?? self.directory)
        var raw: [String: JSONValue] = [
            "hook_event_name": .string(name), "session_id": .string(id), "cwd": .string("/same/workspace"),
            "sidepulse_copilot_event_log": .string(file.path)
        ]
        raw.merge(fields) { _, next in next }
        return try EventNormalizer.normalize(HookEnvelope(provider: .copilot, line: .object(raw)),
                                             receivedAt: now.addingTimeInterval(offset))
    }

    private func record(_ type: String = "abort", offset: Double = 1, agent: String? = nil) throws -> Data {
        var raw: [String: JSONValue] = [
            "type": .string(type), "timestamp": .number(now.addingTimeInterval(offset).timeIntervalSince1970 * 1000),
            "data": .object(["reason": .string("user_initiated")])
        ]
        if let agent { raw["agentId"] = .string(agent) }
        return try JSONEncoder().encode(JSONValue.object(raw)) + Data([10])
    }

    private func write(_ data: Data, id: String = "one", directory: URL? = nil, append: Bool = false) throws {
        let file = try CopilotCancellationReader.eventFile(sessionID: id, directory: directory ?? self.directory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if append {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else { try data.write(to: file, options: .atomic) }
    }

    @discardableResult
    private func poll(_ reader: CopilotCancellationReader, into store: SessionStore) -> CopilotCancellationPoll {
        let result = reader.poll(store.persistentSessions, at: now.addingTimeInterval(100))
        for signal in result.signals { store.ingest(signal) }
        return result
    }

    private func snapshot(_ store: SessionStore) -> MonitorSnapshot {
        store.snapshot(at: now.addingTimeInterval(100))
    }

    func testOneCancelledInstanceCannotHideWorkingDoneOrAskInstances() throws {
        let cases: [(String, [String: JSONValue], DisplayState, Int)] = [
            ("PreToolUse", [:], .working, 1),
            ("Stop", [:], .done, 0),
            ("Notification", ["notification_type": .string("elicitation_dialog")], .ask, 1),
            ("SessionStart", [:], .idle, 0)
        ]
        for (name, fields, expected, activeCount) in cases {
            let store = SessionStore()
            store.ingest(try event())
            store.ingest(try event(name, id: "two", fields: fields))
            try write(record())
            try write(Data(), id: "two")
            let result = poll(CopilotCancellationReader(directory: directory), into: store)
            XCTAssertTrue(result.errors.isEmpty)
            let current = snapshot(store)
            XCTAssertEqual(current.state, expected, name)
            XCTAssertEqual(current.activeCount, activeCount, name)
            XCTAssertEqual(current.sessions.count, 2)
            XCTAssertEqual(current.sessions.first { $0.sessionID == "one" }?.statusLabel, "Cancelled")
            XCTAssertEqual(current.sessions.first { $0.sessionID == "one" }?.mode, .idle)
            if activeCount > 0 {
                XCTAssertEqual(current.listSections.first?.title, "Active")
                XCTAssertEqual(current.listSections.first?.sessions.map(\.sessionID), ["two"])
            }
        }
    }

    func testQuestionWinsWhileAnotherRunsAndSurvivesItsCancellation() throws {
        let reader = CopilotCancellationReader(directory: directory)
        let store = SessionStore()
        store.ingest(try event("PreToolUse"))
        store.ingest(try event("Notification", id: "two", fields: [
            "notification_type": .string("elicitation_dialog"), "message": .string("Choose a target")
        ]))
        XCTAssertEqual(snapshot(store).state, .ask)
        try write(record())
        try write(Data(), id: "two")
        poll(reader, into: store)
        XCTAssertEqual(snapshot(store).state, .ask)
        XCTAssertEqual(snapshot(store).activeCount, 1)
        XCTAssertEqual(snapshot(store).sessions.first?.sessionID, "two")
        store.ingest(try event(id: "two", offset: 2))
        XCTAssertEqual(snapshot(store).state, .working)
        try write(record(offset: 3), id: "two", append: true)
        poll(reader, into: store)
        XCTAssertEqual(snapshot(store).state, .idle)
        XCTAssertEqual(snapshot(store).activeCount, 0)
        XCTAssertEqual(snapshot(store).listSections.map(\.title), ["Recent"])
    }

    func testCancellationClearsOnlyItsOwnPermissionsAndSettlingDeadline() throws {
        let store = SessionStore()
        store.ingest(try event("PostToolUse", fields: ["tool_name": .string("Bash")]))
        store.ingest(try event("PermissionRequest", id: "two", fields: ["tool_use_id": .string("approval-two")]))
        XCTAssertNotNil(store.persistentSessions.first { $0.sessionID == "one" }?.postToolUseSettlesAt)
        try write(record())
        try write(Data(), id: "two")
        let reader = CopilotCancellationReader(directory: directory)
        poll(reader, into: store)
        let cancelled = try XCTUnwrap(store.persistentSessions.first { $0.sessionID == "one" })
        XCTAssertNil(cancelled.postToolUseSettlesAt)
        XCTAssertNil(cancelled.tool)
        XCTAssertEqual(snapshot(store).state, .ask)
        XCTAssertEqual(store.persistentSessions.first { $0.sessionID == "two" }?.pendingPermissions, ["approval-two"])
        try write(record(offset: 2), id: "two", append: true)
        poll(reader, into: store)
        XCTAssertTrue(store.persistentSessions.allSatisfy { $0.pendingPermissions.isEmpty })
        XCTAssertEqual(snapshot(store).state, .idle)
    }

    func testLateSignalCannotOverrideNewerPromptOrQuestion() throws {
        let store = SessionStore()
        store.ingest(try event())
        try write(record())
        let reader = CopilotCancellationReader(directory: directory)
        let pending = try XCTUnwrap(reader.poll(store.persistentSessions, at: now.addingTimeInterval(10)).signals.first)
        store.ingest(try event(offset: 2))
        XCTAssertFalse(store.ingest(pending))
        XCTAssertEqual(snapshot(store).state, .working)
        store.ingest(try event("Notification", offset: 3, fields: ["notification_type": .string("elicitation_dialog")]))
        XCTAssertFalse(store.ingest(pending))
        XCTAssertEqual(snapshot(store).state, .ask)
        XCTAssertTrue(reader.poll(store.persistentSessions, at: now.addingTimeInterval(10)).signals.isEmpty)
    }

    func testCleanupCannotReviveCancelledTurnAndANewTurnCanResume() throws {
        let store = SessionStore()
        store.ingest(try event())
        try write(record())
        let reader = CopilotCancellationReader(directory: directory)
        poll(reader, into: store)
        for name in ["PostToolUse", "PostToolUseFailure", "PermissionDenied", "Stop", "StopFailure", "ErrorOccurred", "SessionEnd"] {
            XCTAssertFalse(store.ingest(try event(name, offset: 2)), name)
            XCTAssertEqual(snapshot(store).state, .idle, name)
        }
        try write(record("assistant.turn_start", offset: 3), append: true)
        poll(reader, into: store)
        XCTAssertEqual(snapshot(store).state, .working)
        XCTAssertEqual(store.persistentSessions.first?.event, "CopilotTurnStart")
        store.ingest(try event("Stop", offset: 4))
        XCTAssertEqual(snapshot(store).state, .done)
        try write(record(offset: 5), append: true)
        poll(reader, into: store)
        XCTAssertEqual(snapshot(store).state, .idle)
        XCTAssertTrue(store.ingest(try event(offset: 6)))
        XCTAssertEqual(snapshot(store).state, .working)
    }

    func testCleanupArrivingBeforeTheCancellationPollStillSettlesToIdle() throws {
        for name in ["PostToolUse", "PostToolUseFailure", "Stop", "ErrorOccurred"] {
            let store = SessionStore()
            store.ingest(try event())
            try write(record())
            store.ingest(try event(name, offset: 2))
            let saved = try JSONCoding.encoder().encode(store.persistentSessions)
            let restored = SessionStore(sessions: try JSONCoding.decoder().decode([AgentSession].self, from: saved))
            poll(CopilotCancellationReader(directory: directory), into: restored)
            XCTAssertEqual(snapshot(restored).state, .idle, name)
            XCTAssertEqual(snapshot(restored).sessions.first?.statusLabel, "Cancelled", name)
            XCTAssertEqual(restored.persistentSessions.first?.updatedAt, now.addingTimeInterval(1), name)
        }
    }

    func testNewerActivityRemainsProtectedEvenWhenFollowedByCleanup() throws {
        for name in ["UserPromptSubmit", "PreToolUse", "Notification"] {
            let store = SessionStore()
            store.ingest(try event())
            try write(record())
            store.ingest(try event(name, offset: 2, fields: ["notification_type": .string("elicitation_dialog")]))
            store.ingest(try event("PostToolUseFailure", offset: 3))
            let result = poll(CopilotCancellationReader(directory: directory), into: store)
            XCTAssertTrue(result.signals.isEmpty, name)
            XCTAssertEqual(snapshot(store).state, .ask, name)
            XCTAssertEqual(store.persistentSessions.first?.copilotActivityAt, now.addingTimeInterval(2), name)
        }
    }

    func testRestartPreservesCancellationAndDoesNotRecreateDismissedSessions() throws {
        let store = SessionStore()
        store.ingest(try event("PermissionRequest"))
        try write(record())
        let reader = CopilotCancellationReader(directory: directory)
        poll(reader, into: store)
        let saved = try JSONCoding.encoder().encode(store.persistentSessions)
        let restored = SessionStore(sessions: try JSONCoding.decoder().decode([AgentSession].self, from: saved))
        let restartedReader = CopilotCancellationReader(directory: directory)
        let result = restartedReader.poll(restored.persistentSessions, at: now.addingTimeInterval(10))
        XCTAssertFalse(restored.ingest(try XCTUnwrap(result.signals.first)))
        XCTAssertEqual(try JSONCoding.encoder().encode(restored.persistentSessions), saved)
        XCTAssertEqual(snapshot(restored).sessions.first?.statusLabel, "Cancelled")
        restored.clear()
        XCTAssertFalse(restored.ingest(try XCTUnwrap(result.signals.first)))
        XCTAssertTrue(snapshot(restored).sessions.isEmpty)
        XCTAssertTrue(restartedReader.poll([]).signals.isEmpty)
        restored.ingest(try event(offset: 3))
        poll(restartedReader, into: restored)
        XCTAssertEqual(snapshot(restored).state, .working)
    }

    func testRootTurnStartAfterAbortWinsWithinTheSameRead() throws {
        let store = SessionStore()
        store.ingest(try event())
        try write(record() + record("assistant.turn_start", offset: 2))
        let result = poll(CopilotCancellationReader(directory: directory), into: store)
        XCTAssertEqual(result.signals.map(\.kind), [.started])
        XCTAssertEqual(snapshot(store).state, .working)
    }

    func testSubagentSignalsCannotCancelOrResumeParent() throws {
        let store = SessionStore()
        store.ingest(try event())
        try write(record(agent: "child"))
        let reader = CopilotCancellationReader(directory: directory)
        XCTAssertTrue(poll(reader, into: store).signals.isEmpty)
        XCTAssertEqual(snapshot(store).state, .working)
        try write(record(offset: 2) + record("assistant.turn_start", offset: 3, agent: "child"), append: true)
        poll(reader, into: store)
        XCTAssertEqual(snapshot(store).state, .idle)
    }

    func testPerInstanceLogDirectoriesAndSourceChangesStayIsolated() throws {
        let other = root.appendingPathComponent("other-home/session-state")
        let store = SessionStore()
        store.ingest(try event())
        store.ingest(try event(id: "two", directory: other))
        try write(record())
        try write(Data(), id: "two", directory: other)
        let reader = CopilotCancellationReader(directory: directory)
        poll(reader, into: store)
        XCTAssertEqual(snapshot(store).state, .working)
        XCTAssertEqual(snapshot(store).sessions.first?.sessionID, "two")
        try write(record(offset: 2), id: "two", directory: other, append: true)
        let pending = reader.poll(store.persistentSessions, at: now.addingTimeInterval(10))
        store.ingest(try event(id: "two", offset: 1, directory: directory))
        XCTAssertFalse(store.ingest(try XCTUnwrap(pending.signals.first { $0.sessionID == "two" })))
        XCTAssertEqual(snapshot(store).state, .working)
    }

    func testPartialNewTurnDoesNotPublishAnEarlierAbort() throws {
        let store = SessionStore()
        store.ingest(try event())
        let start = try record("assistant.turn_start", offset: 2)
        try write(record() + start.dropLast(5))
        let reader = CopilotCancellationReader(directory: directory)
        XCTAssertTrue(poll(reader, into: store).signals.isEmpty)
        try write(Data(start.suffix(5)), append: true)
        XCTAssertEqual(poll(reader, into: store).signals.map(\.kind), [.started])
        XCTAssertEqual(snapshot(store).state, .working)
    }

    func testInitialTailAndIncrementalReadsAreBounded() throws {
        let store = SessionStore()
        store.ingest(try event())
        let limit = CopilotCancellationReader.readLimit
        let huge = try JSONEncoder().encode(JSONValue.object([
            "type": .string("tool.execution_complete"), "data": .string(String(repeating: "x", count: limit * 3))
        ])) + Data([10])
        try write(huge + record())
        let reader = CopilotCancellationReader(directory: directory)
        let first = poll(reader, into: store)
        XCTAssertTrue(first.errors.isEmpty)
        XCTAssertLessThanOrEqual(first.bytesRead, limit + 1)
        XCTAssertEqual(snapshot(store).state, .idle)
        let unchanged = poll(reader, into: store)
        XCTAssertLessThanOrEqual(unchanged.bytesRead, 64)
    }

    func testConcurrentPollsPreserveCursorState() throws {
        let session = try event().session
        let time = now.addingTimeInterval(10)
        try write(record())
        let reader = CopilotCancellationReader(directory: directory)
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            let result = reader.poll([session], at: time)
            XCTAssertTrue(result.errors.isEmpty)
            XCTAssertEqual(result.signals.map(\.kind), [.aborted])
        }
    }

    func testBacklogMustBeCaughtUpBeforeApplyingAnAbort() throws {
        let store = SessionStore()
        store.ingest(try event())
        try write(Data())
        let reader = CopilotCancellationReader(directory: directory)
        poll(reader, into: store)
        let filler = Data(#"{"type":"tool.execution_complete","data":{}}"#.utf8) + Data([10])
        var backlog = try record()
        while backlog.count < CopilotCancellationReader.readLimit * 3 { backlog.append(filler) }
        backlog.append(try record("assistant.turn_start", offset: 2))
        try write(backlog, append: true)
        var caughtUp = false
        for _ in 0..<5 {
            let result = poll(reader, into: store)
            XCTAssertTrue(result.errors.isEmpty)
            XCTAssertLessThanOrEqual(result.bytesRead, CopilotCancellationReader.readLimit + 64)
            XCTAssertEqual(snapshot(store).state, .working)
            if result.signals.first?.kind == .started { caughtUp = true; break }
            XCTAssertTrue(result.signals.isEmpty)
        }
        XCTAssertTrue(caughtUp)
    }

    func testReplacementTruncationAndInPlaceRewritesResetCursors() throws {
        let session = try event().session
        try write(record("assistant.turn_start"))
        let reader = CopilotCancellationReader(directory: directory)
        _ = reader.poll([session], at: now.addingTimeInterval(10))
        try write(record(offset: 2))
        XCTAssertEqual(reader.poll([session], at: now.addingTimeInterval(10)).signals.first?.kind, .aborted)
        let file = URL(fileURLWithPath: try XCTUnwrap(session.copilotEventLog))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: record("assistant.turn_start", offset: 3) + Data(repeating: 10, count: 200))
        try handle.close()
        XCTAssertEqual(reader.poll([session], at: now.addingTimeInterval(10)).signals.first?.kind, .started)
        try write(Data())
        XCTAssertTrue(reader.poll([session], at: now.addingTimeInterval(10)).signals.isEmpty)
    }

    func testFailuresAreReportedAndDoNotBlockHealthyInstances() throws {
        let sessions = [try event().session, try event(id: "two").session]
        try write(record(), id: "two")
        let reader = CopilotCancellationReader(directory: directory)
        let missing = reader.poll(sessions, at: now.addingTimeInterval(10))
        XCTAssertEqual(missing.errors.count, 1)
        XCTAssertEqual(missing.signals.map(\.sessionID), ["two"])
        XCTAssertTrue(reader.poll(sessions, at: now.addingTimeInterval(10)).errors.isEmpty)
        try write(Data("invalid JSON\n".utf8) + record())
        let recovered = reader.poll(sessions, at: now.addingTimeInterval(10))
        XCTAssertEqual(recovered.errors.count, 1)
        XCTAssertEqual(Set(recovered.signals.map(\.sessionID)), ["one", "two"])
        try write(record(offset: 20), append: true)
        let future = reader.poll(sessions, at: now.addingTimeInterval(10))
        XCTAssertEqual(future.errors.count, 1)
        XCTAssertEqual(future.signals.map(\.sessionID), ["two"])
    }

    func testUnsafePathsAndNonregularFilesCannotBeRead() throws {
        for id in ["..", "../other", "/tmp/other", "one/two", "one\\two", "one\n"] {
            XCTAssertThrowsError(try CopilotCancellationReader.eventFile(sessionID: id, directory: directory))
        }
        let session = try event().session
        let file = try CopilotCancellationReader.eventFile(sessionID: "one", directory: directory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        let reader = CopilotCancellationReader(directory: directory)
        let result = reader.poll([session])
        XCTAssertTrue(result.signals.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
        var mismatched = session
        mismatched.copilotEventLog = directory.appendingPathComponent("other/events.jsonl").path
        XCTAssertEqual(reader.poll([mismatched]).errors.count, 1)
    }

    func testRemoteAndSubagentSessionsAreNotMonitored() throws {
        var remote = try event().session
        remote.remoteID = "host"
        var child = try event().session
        child.id = "copilot:agent:child"
        let result = CopilotCancellationReader(directory: directory).poll([remote, child])
        XCTAssertTrue(result.signals.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testActivityTimestampDoesNotLeakToOtherProviders() throws {
        for provider in [Provider.codex, .claude, .grok] {
            let store = SessionStore()
            for (index, name) in ["UserPromptSubmit", "PreToolUse"].enumerated() {
                let envelope = HookEnvelope(provider: provider, line: .object([
                    "hook_event_name": .string(name), "session_id": .string("other")
                ]))
                store.ingest(try EventNormalizer.normalize(envelope, receivedAt: now.addingTimeInterval(Double(index))))
            }
            XCTAssertNil(store.persistentSessions.first?.copilotActivityAt, provider.rawValue)
            XCTAssertEqual(snapshot(store).state, .working)
        }
    }

    func testSessionEndAbortUsesCancelledRatherThanDone() throws {
        let store = SessionStore()
        store.ingest(try event("PermissionRequest", fields: ["tool_use_id": .string("approval")]))
        store.ingest(try event("SessionEnd", offset: 1, fields: ["reason": .string("abort")]))
        XCTAssertEqual(snapshot(store).state, .idle)
        XCTAssertEqual(snapshot(store).sessions.first?.statusLabel, "Cancelled")
        XCTAssertEqual(store.persistentSessions.first?.pendingPermissions, [])
    }

    func testHelperSuppliesEachInstancesLogLocation() throws {
        let payload = JSONValue.object(["session_id": .string("one"), "hook_event_name": .string("PreToolUse")])
        let first = try CopilotHookInput.prepare(payload, fallbackEvent: nil, eventsDirectory: directory)
        let other = root.appendingPathComponent("other-home/session-state")
        let second = try CopilotHookInput.prepare(payload, fallbackEvent: nil, eventsDirectory: other)
        XCTAssertNotEqual(first["sidepulse_copilot_event_log"], second["sidepulse_copilot_event_log"])
        let normalized = try EventNormalizer.normalize(HookEnvelope(provider: .copilot, line: first), receivedAt: now)
        XCTAssertEqual(normalized.session.copilotEventLog, directory.appendingPathComponent("one/events.jsonl").path)
        let store = SessionStore()
        store.ingest(normalized)
        store.ingest(try EventNormalizer.normalize(HookEnvelope(provider: .copilot, line: payload),
                                                   receivedAt: now.addingTimeInterval(1)))
        XCTAssertEqual(store.persistentSessions.first?.copilotEventLog, normalized.session.copilotEventLog)
    }
}
