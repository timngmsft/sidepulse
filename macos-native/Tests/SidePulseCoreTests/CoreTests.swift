import Foundation
import XCTest
@testable import SidePulseCore

final class CoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private func event(_ name: String, provider: Provider = .copilot, id: String = "one",
                       extra: [String: JSONValue] = [:], offset: Double = 0) throws -> NormalizedEvent {
        var raw: [String: JSONValue] = [
            "hook_event_name": .string(name), "session_id": .string(id), "cwd": .string("/tmp/project")
        ]
        raw.merge(extra) { _, new in new }
        return try EventNormalizer.normalize(HookEnvelope(provider: provider, line: .object(raw)),
                                             receivedAt: now.addingTimeInterval(offset))
    }

    func testProviderAliasesAndQuestionDetection() throws {
        for provider in Provider.hookProviders {
            let value = try EventNormalizer.normalize(HookEnvelope(provider: provider, line: .object([
                "hookEventName": .string("userPromptSubmitted"), "sessionId": .string("123"),
                "cwd": .string("/work/native")
            ])), receivedAt: now)
            XCTAssertEqual(value.session.mode, .working)
            XCTAssertEqual(value.session.sessionID, "123")
        }
        XCTAssertTrue(EventNormalizer.asksQuestion("Want me to run `git push`?"))
        XCTAssertFalse(EventNormalizer.asksQuestion("Anything else you want to tweak?"))
        XCTAssertFalse(EventNormalizer.asksQuestion("Example: `Want me to push?` => Ask"))
        XCTAssertFalse(EventNormalizer.asksQuestion("```text\nWant me to push?\n```"))
        XCTAssertEqual(try event("Stop", extra: ["last_assistant_message": .string("Which option?")]).session.mode, .waiting)
        XCTAssertEqual(try event("Stop", extra: ["last_assistant_message": .string("[sidepulse:done] Which option?")]).session.mode, .completed)
        XCTAssertEqual(try event("Stop", extra: ["last_assistant_message": .string("<!-- sidepulse: done -->\nWhich option?")]).session.mode, .completed)
        XCTAssertEqual(try event("Stop", extra: ["last_assistant_message": .string("```\n<!-- sidepulse: ask -->\n```\nFinished.")]).session.mode, .completed)
    }

    func testAggregationAndCompletionDoNotHideOtherWork() throws {
        let store = SessionStore()
        store.ingest(try event("UserPromptSubmit"))
        store.ingest(try event("Stop", id: "two"))
        XCTAssertEqual(store.snapshot(at: now).state, .working)
        store.ingest(try event("PermissionRequest", id: "three"))
        XCTAssertEqual(store.snapshot(at: now).state, .ask)
        store.remove(id: "copilot:session:three")
        store.ingest(try event("Stop"))
        XCTAssertEqual(store.snapshot(at: now).state, .done)
        XCTAssertEqual(store.snapshot(at: now.addingTimeInterval(1201)).state, .idle)
    }

    func testSameWorkspaceSessionsRemainDistinctAndShowActiveVersusEnded() throws {
        let store = SessionStore()
        store.ingest(try event("SessionEnd", id: "22222222-ended"))
        store.ingest(try event("UserPromptSubmit", id: "11111111-active", offset: 1))
        let snapshot = store.snapshot(at: now.addingTimeInterval(1))
        XCTAssertEqual(snapshot.sessions.count, 2)
        XCTAssertEqual(Set(snapshot.sessions.map(\.title)), ["project"])
        XCTAssertEqual(snapshot.state, .working)
        XCTAssertEqual(snapshot.activeCount, 1)
        XCTAssertEqual(snapshot.listSections.map(\.title), ["Active", "Recent"])
        let active = try XCTUnwrap(snapshot.listSections.first?.sessions.first)
        let ended = try XCTUnwrap(snapshot.listSections.last?.sessions.first)
        XCTAssertEqual(active.referenceLabel, "Session 11111111")
        XCTAssertEqual(ended.referenceLabel, "Session 22222222")
        XCTAssertEqual(active.statusLabel, "Working")
        XCTAssertEqual(ended.statusLabel, "Ended")

        let expired = store.snapshot(at: now.addingTimeInterval(3602))
        XCTAssertEqual(expired.listSections.map(\.title), ["Recent"])
        XCTAssertEqual(expired.listSections.first?.sessions.count, 2)
        XCTAssertEqual(expired.sessions.first { $0.sessionID == "22222222-ended" }?.statusLabel, "Ended")
    }

    func testQuestionsStayActiveAndSubagentsHaveTheirOwnReference() throws {
        let store = SessionStore()
        store.ingest(try event("Stop", id: "parent-session"))
        store.ingest(try event("Stop", id: "parent-session", extra: [
            "agent_id": .string("child-agent"), "last_assistant_message": .string("Which option?")
        ]))
        let snapshot = store.snapshot(at: now)
        XCTAssertEqual(snapshot.listSections.map(\.title), ["Active", "Recent"])
        XCTAssertEqual(snapshot.listSections[0].sessions[0].referenceLabel, "Agent child-ag")
        XCTAssertEqual(snapshot.listSections[0].sessions[0].statusLabel, "Ask")
        XCTAssertEqual(snapshot.listSections[1].sessions[0].referenceLabel, "Session parent-s")
        XCTAssertEqual(snapshot.listSections[1].sessions[0].statusLabel, "Done")
        XCTAssertEqual(snapshot.state, .ask)
    }

    func testPendingApprovalSurvivesUnrelatedToolCalls() throws {
        let store = SessionStore()
        store.ingest(try event("PermissionRequest", extra: ["tool_use_id": .string("a")]))
        store.ingest(try event("PostToolUse", extra: ["tool_use_id": .string("b")], offset: 1))
        XCTAssertEqual(store.snapshot(at: now.addingTimeInterval(1)).state, .ask)
        store.ingest(try event("PostToolUse", extra: ["tool_use_id": .string("a")], offset: 2))
        XCTAssertEqual(store.snapshot(at: now.addingTimeInterval(2)).state, .working)
    }

    func testOutOfOrderEventsAndExpiry() throws {
        let store = SessionStore()
        store.staleAfter = 10
        store.ingest(try event("Stop", offset: 2))
        XCTAssertFalse(store.ingest(try event("PreToolUse", offset: 1)))
        XCTAssertEqual(store.snapshot(at: now.addingTimeInterval(3)).state, .done)
        XCTAssertEqual(store.snapshot(at: now.addingTimeInterval(20)).state, .idle)
    }

    func testEveryGeneratedLEDProgramFitsFirmwareLimits() throws {
        for state in DisplayState.allCases {
            for count in [2, 8] {
                for brightness in [0.0, 0.2, 1.0] {
                    try LEDProgram.validate(LEDProgram.status(state, count: count, brightness: brightness))
                }
            }
        }
        for percent in [0.0, 20, 55, 100] {
            try LEDProgram.validate(LEDProgram.battery(percent: percent, charging: true))
        }
        XCTAssertEqual(LEDProgram.normalize(#"off\n#00FF66\\n"#), "off\n#00FF66\\n")
        XCTAssertThrowsError(try LEDProgram.validate(String(repeating: "x", count: 513)))
        XCTAssertThrowsError(try LEDProgram.validate(Array(repeating: "off", count: 21).joined(separator: "\n")))
    }

    func testHooksPreserveOtherCommandsAndAreIdempotent() throws {
        let helper = URL(fileURLWithPath: "/Applications/SidePulse Native.app/Contents/Helpers/SidePulseHook")
        let socket = URL(fileURLWithPath: "/tmp/native/events.sock")
        for provider in Provider.hookProviders {
            let original = provider == .codex
                ? "model = \"example\"\n[features]\nhooks = false\nother = true\n"
                : #"{"other":true,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"original-hook"}]}]}}"#
            let once = try HookConfiguration.render(provider: provider, original: original, helper: helper, socket: socket)
            let twice = try HookConfiguration.render(provider: provider, original: once, helper: helper, socket: socket)
            XCTAssertEqual(once, twice, provider.rawValue)
            XCTAssertTrue(once.contains("SidePulseHook"))
            if provider != .codex { XCTAssertTrue(once.contains("original-hook")) }
            let removed = try HookConfiguration.render(provider: provider, original: once, helper: helper, socket: socket, removing: true)
            XCTAssertFalse(removed.contains("SidePulseHook"))
            if provider != .codex { XCTAssertTrue(removed.contains("original-hook")) }
        }
        XCTAssertThrowsError(try HookConfiguration.render(provider: .claude, original: "[]", helper: helper, socket: socket))
        let mixed = #"{"hooks":{"Stop":[{"matcher":"*","hooks":[{"command":"echo untouched"},{"command":"native # sidepulse-native"}]}]}}"#
        let removed = try HookConfiguration.render(provider: .claude, original: mixed, helper: helper, socket: socket, removing: true)
        XCTAssertTrue(removed.contains("echo untouched"))
        XCTAssertFalse(removed.contains("# sidepulse-native"))
    }

    func testIPCIsNativePrivateAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spn-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("events.sock")
        let server = UnixEventServer(socket: socket) { _ in }
        try server.start(deliveryQueue: DispatchQueue(label: "native.test.handler")) { $0 }
        defer { server.stop() }
        let data = Data(#"{"provider":"copilot","line":{"hook_event_name":"Stop"}}"#.utf8)
        XCTAssertEqual(try NativeIPC.request(data, socket: socket), data)
        let permissions = try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let second = UnixEventServer(socket: socket) { _ in }
        XCTAssertThrowsError(try second.start { $0 })
        XCTAssertEqual(try NativeIPC.request(data, socket: socket), data)
    }

    func testHerdrOnlyAnnouncesNewCompletionAndPreservesCompletionTime() throws {
        let reducer = HerdrReducer()
        var remote = RemoteConfiguration()
        remote.target = "example"
        func payload(_ state: String) -> Data {
            Data(#"{"id":"cli:agent:list","result":{"type":"agent_list","agents":[{"agent":"claude","terminal_id":"term","agent_status":""#.utf8)
            + Data(state.utf8) + Data(#"","cwd":"/remote/work"}]}}"#.utf8)
        }
        XCTAssertTrue(try reducer.apply(payload("done"), remote: remote, at: now).isEmpty)
        XCTAssertEqual(try reducer.apply(payload("working"), remote: remote, at: now).first?.mode, .working)
        let finished = try reducer.apply(payload("idle"), remote: remote, at: now.addingTimeInterval(1)).first
        XCTAssertEqual(finished?.mode, .completed)
        XCTAssertEqual(try reducer.apply(payload("done"), remote: remote, at: now.addingTimeInterval(2)).first?.updatedAt, finished?.updatedAt)
        XCTAssertThrowsError(try reducer.apply(Data("{}".utf8), remote: remote))
        remote.target = "-oProxyCommand=bad"
        XCTAssertThrowsError(try HerdrCommands.agentList(path: "/usr/bin/herdr", remote: remote, polling: true))
    }

    func testOfflineEventsArePrivateAndIsolated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spn-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("events.sock")
        let data = try JSONEncoder().encode(HookEnvelope(provider: .codex, line: .object(["hook_event_name": .string("Stop")])))
        try PendingEvents.enqueue(data, socket: socket)
        let files = try PendingEvents.files(socket: socket)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: files[0]), data)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLEDOutputDoesNotLoseAnUnchangedDevicesPendingWrite() {
        let queue = DispatchQueue(label: "test-led-output")
        var written: [String: String] = [:]
        let output = LEDOutput(queue: queue, write: { program, file in
            written[file.lastPathComponent] = program
        }, onError: { _, error in XCTFail(error.localizedDescription) })
        let a = LEDTarget(file: URL(fileURLWithPath: "/unused/a"), program: "#00FF00")
        let b = LEDTarget(file: URL(fileURLWithPath: "/unused/b"), program: "#0000FF")
        let changedB = LEDTarget(file: b.file, program: "#FF0000")
        queue.suspend()
        output.apply(["a": a, "b": b])
        output.apply(["a": a, "b": changedB])
        output.apply(["a": a, "b": changedB])
        queue.resume()
        queue.sync {}
        XCTAssertEqual(written, ["a": a.program, "b": changedB.program])
        queue.suspend()
        output.apply(["a": b], force: true)
        output.apply([:])
        queue.resume()
        queue.sync {}
        XCTAssertEqual(written, ["a": a.program, "b": changedB.program])
    }

    func testIPCWaitsForPayloadAfterAcceptingAConnection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spn-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("events.sock")
        let server = UnixEventServer(socket: socket) { XCTFail($0) }
        try server.start(deliveryQueue: .global()) { $0 }
        defer { server.stop() }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        try NativeIPC.configure(fd, timeout: 1)
        var address = try NativeIPC.socketAddress(socket.path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        Thread.sleep(forTimeInterval: 0.1)
        let data = Data(#"{"action":"ping"}"#.utf8)
        try NativeIPC.write(data, to: fd)
        Darwin.shutdown(fd, SHUT_WR)
        XCTAssertEqual(try NativeIPC.read(from: fd, limit: 1024), data)
    }

    func testFreshTurnsClearOldQuestionsAndSnapshotsExposeExpiredRows() throws {
        for start in ["SessionStart", "UserPromptSubmit"] {
            let store = SessionStore()
            store.ingest(try event("PermissionRequest", extra: [
                "tool_use_id": .string("approval"), "message": .string("An old question?")
            ]))
            store.ingest(try event(start, offset: 1))
            let session = try XCTUnwrap(store.snapshot(at: now.addingTimeInterval(1)).sessions.first)
            XCTAssertTrue(session.pendingPermissions.isEmpty)
            XCTAssertNil(session.message)
            XCTAssertEqual(session.mode, start == "SessionStart" ? .idle : .working)
        }
        let store = SessionStore()
        store.doneVisible = 1
        store.ingest(try event("Stop", id: "done"))
        store.ingest(try event("UserPromptSubmit", id: "working"))
        let snapshot = store.snapshot(at: now.addingTimeInterval(2))
        XCTAssertEqual(snapshot.state, .working)
        XCTAssertEqual(snapshot.sessions.first { $0.sessionID == "done" }?.mode, .idle)
        XCTAssertEqual(store.persistentSessions.first { $0.sessionID == "done" }?.mode, .completed)
    }

    func testLongDevelopmentPathsRemainIsolatedAndSettingsAreValidated() throws {
        let root = URL(fileURLWithPath: "/tmp/" + String(repeating: "long-directory/", count: 12))
        let first = NativePaths(root: root)
        XCTAssertLessThan(first.socket.path.utf8.count, 104)
        XCTAssertNotEqual(first.socket, NativePaths().socket)
        XCTAssertNotEqual(first.socket, NativePaths(root: root.appendingPathComponent("other")).socket)
        XCTAssertEqual(first.socket, NativePaths(root: root).socket)
        var configuration = AppConfiguration()
        try configuration.validate()
        var remote = RemoteConfiguration()
        remote.target = "host.invalid"
        configuration.remotes = [remote, remote]
        XCTAssertThrowsError(try configuration.validate())
    }

    func testHookInstallationPreservesSymlinksAndKeepsBackupsOutOfLiveHooks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spn-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = URL(fileURLWithPath: "/usr/bin/true")
        let socket = root.appendingPathComponent("events.sock")
        let file = try HookConfiguration.file(for: .claude, home: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = root.appendingPathComponent("shared-settings.json")
        let original = Data(#"{"unrelated":"preserve me"}"#.utf8)
        try original.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let installed = try HookConfiguration.install(provider: .claude, home: root, helper: helper, socket: socket)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(installed.backup)), original)
        XCTAssertTrue(HookConfiguration.isInstalled(provider: .claude, home: root))

        let grok = try HookConfiguration.install(provider: .grok, home: root, helper: helper, socket: socket)
        let hooks = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: grok.file))["hooks"]
        XCTAssertNil(hooks?["Stop"]?.array?.first?["matcher"])
        XCTAssertEqual(hooks?["PreToolUse"]?.array?.first?["matcher"]?.string, "*")
        let removed = try HookConfiguration.install(provider: .grok, home: root, helper: helper, socket: socket, removing: true)
        XCTAssertNotEqual(try XCTUnwrap(removed.backup).deletingLastPathComponent(), grok.file.deletingLastPathComponent())
    }
}
