import Darwin
import Foundation
import XCTest
@testable import SidePulseCore

final class HerdrFixture {
    let root: URL
    var ssh: URL { root.appendingPathComponent("ssh") }
    var control: URL { root.appendingPathComponent("control") }

    init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("spn-herdr-\(UUID().uuidString.prefix(8))")
        try NativeIPC.preparePrivateDirectory(self.root)
        try write("discovery", "SIDEPULSE_REMOTE_OS=Linux\nSIDEPULSE_HERDR_CANDIDATE=/bad-herdr\nSIDEPULSE_HERDR_CANDIDATE=/good-herdr\n")
        try write("probe", Self.snapshot("working"))
        try write("live", Self.snapshot("working"))
        try write("ssh", """
        #!/bin/sh
        root=\(HookConfiguration.shellQuote(self.root.path))
        printf '%s\\n' "$$" >> "$root/pids"
        printf '%s\\n' "$*" >> "$root/calls"
        case "$*" in *" -O exit "*) printf 'closed\\n' >> "$root/closed"; exit 0;; esac
        if [ "$1" = "-M" ]; then
          if [ -f "$root/auth-block" ]; then while :; do sleep 0.05; done; fi
          if [ -f "$root/auth-fail" ]; then exit 255; fi
          exit 0
        fi
        if [ -f "$root/unreachable" ]; then printf 'Connection refused\\n' >&2; exit 255; fi
        if [ -f "$root/auth-required" ]; then printf 'Permission denied (publickey).\\n' >&2; exit 255; fi
        for argument do command=$argument; done
        case "$command" in
          *SIDEPULSE_REMOTE_OS=*) cat "$root/discovery";;
          *"while :;"*)
            if [ -f "$root/stream" ]; then exec /bin/sh "$root/stream"; fi
            while :; do cat "$root/live"; printf '\\n'; sleep 0.05; done;;
          *bad-herdr*) printf 'not the Herdr protocol\\n';;
          *"agent list"*) cat "$root/probe"; printf '\\n';;
          *) printf 'Unexpected fixture invocation\\n' >&2; exit 99;;
        esac
        """, executable: true)
    }

    func write(_ name: String, _ text: String, executable: Bool = false) throws {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url, options: .atomic)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    func remove() throws {
        let file = root.appendingPathComponent("pids")
        if FileManager.default.fileExists(atPath: file.path) {
            let pids = try read("pids").split(separator: "\n").compactMap { Int32($0) }
            let deadline = Date().addingTimeInterval(2)
            while pids.contains(where: { kill($0, 0) == 0 }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            XCTAssertFalse(pids.contains { kill($0, 0) == 0 }, "An owned SSH fixture survived cancellation.")
        }
        try FileManager.default.removeItem(at: root)
    }

    static func snapshot(_ state: String, agent: String = "copilot", terminal: String = "terminal-one") -> String {
        #"{"id":"cli:agent:list","result":{"type":"agent_list","agents":[{"agent":""# + agent +
        #"","agent_status":""# + state + #"","terminal_id":""# + terminal +
        #"","terminal_title":"Remote task","foreground_cwd":"/remote/project"}]}}"#
    }
}

final class HerdrTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_789_000_000)
    private var remote: RemoteConfiguration {
        var remote = RemoteConfiguration()
        remote.name = "Fixture"; remote.target = "fixture-host"
        return remote
    }

    private func fixture() throws -> HerdrFixture {
        let fixture = try HerdrFixture()
        addTeardownBlock { try fixture.remove() }
        return fixture
    }

    private func monitor(_ fixture: HerdrFixture, remote: RemoteConfiguration? = nil,
                         once: Bool = false, timing: HerdrTiming = HerdrTiming(),
                         update: @escaping (HerdrUpdate) -> Void) -> HerdrMonitor {
        let monitor = HerdrMonitor(configuration: remote ?? self.remote, controlPath: fixture.control, once: once,
                                   executable: fixture.ssh, timing: timing, log: { _ in }, update: update)
        addTeardownBlock { monitor.stop() }
        monitor.start()
        return monitor
    }

    func testProtocolValidatesWholeSnapshotAndSupportsRemoteOnlyAgents() throws {
        let good = HerdrFixture.snapshot("WORKING", agent: "OpenCode")
        let record = try HerdrRecord.parse(Data(good.utf8))
        guard case .agents(let observations) = record else { return XCTFail("Expected an agent list") }
        XCTAssertEqual(observations.first?.agent, "opencode")
        let reducer = HerdrReducer()
        let remote = self.remote
        let session = try XCTUnwrap(reducer.apply(observations, remote: remote, at: date).first)
        XCTAssertEqual(session.provider, .herdr)
        XCTAssertEqual(session.providerTitle, "opencode")
        XCTAssertEqual(session.referenceLabel, "Terminal terminal-one")
        XCTAssertFalse(ApplicationMode.standard.permitsHookChanges(for: .herdr))
        XCTAssertThrowsError(try EventNormalizer.normalize(HookEnvelope(provider: .herdr, line: .object([:]))))
        XCTAssertThrowsError(try HookConfiguration.file(for: .herdr, home: URL(fileURLWithPath: "/unused")))
        var root = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(good.utf8)).object)
        let row = root["result"]?["agents"]?.array?.first
        root["result"] = .object(["type": .string("agent_list"), "agents": .array([try XCTUnwrap(row), try XCTUnwrap(row)])])
        XCTAssertThrowsError(try HerdrRecord.parse(JSONEncoder().encode(JSONValue.object(root))))
        for bad in [
            good.replacingOccurrences(of: #""foreground_cwd":"/remote/project""#, with: #""foreground_cwd":42"#),
            good.replacingOccurrences(of: #""terminal_id":"terminal-one""#, with: #""terminal_id":null"#),
            good.replacingOccurrences(of: "cli:agent:list", with: "unexpected"),
            #"{"id":"cli:agent:list","error":{"code":32,"message":"bad"}}"#
        ] {
            XCTAssertThrowsError(try reducer.apply(Data(bad.utf8), remote: remote, at: date))
        }
        XCTAssertEqual(try reducer.apply(Data(good.utf8), remote: remote, at: date.addingTimeInterval(5)).first?.updatedAt, date)
    }

    func testStructuredAndLegacyAgentSessionReferences() throws {
        let base = HerdrFixture.snapshot("working")
        for (value, expected) in [
            (#""legacy-id""#, "legacy-id"),
            (#"{"kind":"id","value":"native-id"}"#, "native-id"),
            (#"{"kind":"path","value":"/remote/transcript"}"#, nil),
            ("null", nil)
        ] as [(String, String?)] {
            let json = base.replacingOccurrences(of: #""terminal_title":"Remote task""#, with: #""agent_session":"# + value)
            let result = try HerdrReducer().apply(Data(json.utf8), remote: remote, at: date)
            XCTAssertEqual(result.first?.sessionID, expected)
        }
        let invalid = base.replacingOccurrences(of: #""terminal_title":"Remote task""#, with: #""agent_session":{"kind":"id","value":42}"#)
        XCTAssertThrowsError(try HerdrRecord.parse(Data(invalid.utf8)))
    }

    func testCompletionBaselineIdentityAndConfiguredRetention() throws {
        let reducer = HerdrReducer()
        reducer.doneVisible = 60
        let remote = self.remote
        func apply(_ state: String, _ offset: TimeInterval) throws -> [AgentSession] {
            try reducer.apply(Data(HerdrFixture.snapshot(state).utf8), remote: remote, at: date.addingTimeInterval(offset))
        }
        XCTAssertTrue(try apply("idle", 0).isEmpty)
        XCTAssertTrue(try apply("done", 1).isEmpty)
        let working = try XCTUnwrap(apply("working", 2).first)
        let moved = HerdrFixture.snapshot("working").replacingOccurrences(of: "Remote task", with: "Renamed")
        let renamed = try XCTUnwrap(reducer.apply(Data(moved.utf8), remote: remote, at: date.addingTimeInterval(3)).first)
        XCTAssertEqual(renamed.id, working.id)
        XCTAssertEqual(renamed.updatedAt, working.updatedAt)
        XCTAssertEqual(try apply("blocked", 4).first?.mode, .waiting)
        let done = try XCTUnwrap(apply("done", 5).first)
        XCTAssertEqual(done.mode, .completed)
        reducer.reconnecting()
        XCTAssertEqual(try apply("idle", 8).first?.updatedAt, done.updatedAt)
        XCTAssertEqual(try apply("unknown", 9).first?.updatedAt, done.updatedAt)
        XCTAssertTrue(try apply("done", 66).isEmpty)
        _ = try apply("working", 70)
        reducer.reconnecting()
        XCTAssertTrue(try apply("idle", 71).isEmpty, "A reconnect must not invent a completion.")
        _ = try apply("working", 72)
        XCTAssertTrue(try reducer.apply(Data(#"{"id":"cli:agent:list","result":{"type":"agent_list","agents":[]}}"#.utf8), remote: remote).isEmpty)
        XCTAssertTrue(try apply("done", 73).isEmpty)
    }

    func testRemoteFreshnessAndLocalPriorityStayIndependent() throws {
        let store = SessionStore()
        store.staleAfter = 60
        let local = try EventNormalizer.normalize(HookEnvelope(provider: .copilot, line: .object([
            "hook_event_name": .string("PermissionRequest"), "session_id": .string("local")
        ])), receivedAt: date)
        store.ingest(local)
        let remote = self.remote
        var row = try XCTUnwrap(HerdrReducer().apply(Data(HerdrFixture.snapshot("working").utf8), remote: remote, at: date).first)
        row.updatedAt = date.addingTimeInterval(-7200)
        XCTAssertEqual(row.effectiveMode(at: date, staleAfter: 60, doneVisible: 60), .working)
        store.reconcile(remoteID: remote.id, sessions: [row])
        XCTAssertEqual(store.snapshot(at: date).state, .ask)
        XCTAssertEqual(store.persistentSessions.count, 1)
        row.mode = .waiting
        XCTAssertEqual(row.effectiveMode(at: date, staleAfter: 60, doneVisible: 60), .idle)
        row.mode = .completed
        XCTAssertEqual(row.effectiveMode(at: date, staleAfter: 60, doneVisible: 60), .idle)
        row.mode = .working
        XCTAssertEqual(row.effectiveMode(at: date.addingTimeInterval(15.1), staleAfter: 60, doneVisible: 60), .idle)
        store.reconcile(remoteID: remote.id, sessions: [])
        XCTAssertEqual(store.snapshot(at: date).state, .ask)
        XCTAssertEqual(SessionStore(sessions: [row]).snapshot(at: date).sessions.count, 0)
    }

    func testRemoteConfigurationCompatibilityValidationAndControlIsolation() throws {
        var remote = self.remote
        let encoded = try JSONEncoder().encode(remote)
        XCTAssertNil(try JSONDecoder().decode(RemoteConfiguration.self, from: encoded).resolvedHerdrPath)
        remote.resolvedHerdrPath = "/cached/herdr"
        XCTAssertEqual(try JSONDecoder().decode(RemoteConfiguration.self, from: JSONEncoder().encode(remote)), remote)
        remote.session = " default "; remote.target = " fixture-host "
        let normalized = remote.normalized()
        XCTAssertEqual(normalized.session, "")
        try normalized.validate()
        remote = normalized
        let root = URL(fileURLWithPath: "/tmp/isolated")
        let original = HerdrCommands.controlPath(root: root, remote: remote, nonce: "generation")
        var renamed = remote; renamed.name = "A new name"
        XCTAssertTrue(renamed.sameEndpoint(as: remote))
        XCTAssertEqual(original, HerdrCommands.controlPath(root: root, remote: renamed, nonce: "generation"))
        renamed.target = "another-host"
        XCTAssertFalse(renamed.sameEndpoint(as: remote))
        XCTAssertNotEqual(original, HerdrCommands.controlPath(root: root, remote: renamed, nonce: "generation"))
        XCTAssertNotEqual(original, HerdrCommands.controlPath(root: root, remote: remote, nonce: "replacement"))
        XCTAssertLessThan(original.path.utf8.count, 104)
        for session in ["with space", "x;exit", "../x", "x\nx"] {
            remote.session = session
            XCTAssertThrowsError(try remote.validate())
        }
        remote.session = "workspace-2.dev"
        try remote.validate()
        let command = try HerdrCommands.agentList(path: "/opt/Herdr's bin/herdr", remote: remote, polling: true)
        XCTAssertTrue(command.contains("| cat || exit"))
        XCTAssertTrue(command.contains("exit 127"))
        XCTAssertFalse(command.contains("\n"))
        let arguments = HerdrCommands.sshArguments(remote: remote, controlPath: original, command: command)
        XCTAssertEqual(arguments.suffix(2), [remote.target, command])
        XCTAssertEqual(arguments[arguments.count - 3], "--")
        XCTAssertTrue(arguments.contains("BatchMode=yes"))
    }

    func testDiscoveryTriesCompatibleCandidatesAndStreamsAllStates() throws {
        let fixture = try fixture()
        let done = expectation(description: "Stable remote completion")
        var modes: [AgentMode] = []
        var completionDate: Date?
        var settled = false
        var final: HerdrConnectionStatus?
        _ = monitor(fixture) { update in
            guard let mode = update.sessions?.first?.mode else { return }
            final = update.connection
            do {
                if modes.last != mode {
                    modes.append(mode)
                    if mode == .working { try fixture.write("live", HerdrFixture.snapshot("blocked")) }
                    if mode == .waiting { try fixture.write("live", HerdrFixture.snapshot("idle")) }
                }
                if mode == .completed {
                    if let completionDate, !settled {
                        XCTAssertEqual(update.sessions?.first?.updatedAt, completionDate)
                        settled = true
                        done.fulfill()
                    } else if completionDate == nil { completionDate = update.sessions?.first?.updatedAt }
                }
            } catch { XCTFail(error.localizedDescription) }
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(modes, [.working, .waiting, .completed])
        XCTAssertEqual(final?.path, "/good-herdr")
        XCTAssertEqual(final?.platform, "Linux")
        XCTAssertEqual(final?.agentCount, 1)
        let calls = try fixture.read("calls")
        XCTAssertTrue(calls.contains("bad-herdr"))
        XCTAssertEqual(calls.components(separatedBy: "while :;").count - 1, 1)
    }

    func testServerNotRunningAndUnknownErrorAreCompatibleAndRecover() throws {
        let fixture = try fixture()
        try fixture.write("probe", #"{"id":"cli:agent:list","error":{"code":"server_not_running","message":"Start the session."}}"#)
        try fixture.write("live", #"{"id":"cli:agent:list","error":{"code":"server_not_running","message":"Start the session."}}"#)
        let unavailable = expectation(description: "Session not running")
        let recovering = expectation(description: "Typed remote error")
        let connected = expectation(description: "Recovered on the same stream")
        var sawUnavailable = false, sawError = false, sawConnected = false
        _ = monitor(fixture) { update in
            if update.connection.state == .notRunning && !sawUnavailable {
                sawUnavailable = true; unavailable.fulfill()
                do { try fixture.write("live", #"{"id":"cli:agent:list","error":{"code":"temporarily_busy","message":"Retry soon."}}"#) }
                catch { XCTFail(error.localizedDescription) }
            }
            if update.connection.state == .remoteError && !sawError {
                sawError = true; recovering.fulfill()
                do { try fixture.write("live", HerdrFixture.snapshot("working")) }
                catch { XCTFail(error.localizedDescription) }
            }
            if update.connection.state == .connected && !sawConnected { sawConnected = true; connected.fulfill() }
        }
        wait(for: [unavailable, recovering, connected], timeout: 5)
        XCTAssertEqual(try fixture.read("calls").components(separatedBy: "while :;").count - 1, 1)
    }

    func testConnectionFailuresHaveActionableStatesAndDoNotRetryAuthentication() throws {
        for (file, text, expected) in [
            ("auth-required", "", HerdrConnectionState.authenticationRequired),
            ("discovery", "SIDEPULSE_REMOTE_OS=FreeBSD\n", .unsupportedPlatform),
            ("discovery", "SIDEPULSE_REMOTE_OS=Linux\n", .notInstalled)
        ] {
            let fixture = try fixture()
            try fixture.write(file, text)
            let finished = expectation(description: expected.rawValue)
            var status: HerdrConnectionStatus?
            let worker = monitor(fixture, once: true) { update in
                if update.finished { status = update.connection; finished.fulfill() }
            }
            wait(for: [finished], timeout: 3)
            worker.stop()
            XCTAssertEqual(status?.state, expected)
            XCTAssertNil(status?.retryAt)
            XCTAssertEqual(try fixture.read("calls").split(separator: "\n").count, 1)
        }
    }

    func testInvalidStreamCannotKeepStaleAgentsAlive() throws {
        let fixture = try fixture()
        var remote = self.remote
        remote.herdrPath = "/good-herdr"
        try fixture.write("live", "still not JSON")
        var timing = HerdrTiming()
        timing.outputTimeout = 0.2; timing.grace = 0.35
        let invalid = expectation(description: "Incompatible output deadline")
        let cleared = expectation(description: "Grace removes stale activity")
        var sawInvalid = false, sawCleared = false
        _ = monitor(fixture, remote: remote, timing: timing) { update in
            if update.connection.state == .incompatibleResponse && !sawInvalid {
                sawInvalid = true; invalid.fulfill()
                XCTAssertNil(update.connection.retryAt)
            }
            if update.sessions == [] && !sawCleared { sawCleared = true; cleared.fulfill() }
        }
        wait(for: [invalid, cleared], timeout: 4)
        XCTAssertEqual(try fixture.read("calls").components(separatedBy: "while :;").count - 1, 1)
    }

    func testReconnectRearmsBaselineAndRotatesOwnedControlPath() throws {
        let fixture = try fixture()
        let root = HookConfiguration.shellQuote(fixture.root.path)
        try fixture.write("stream", """
        root=\(root)
        if [ ! -f "$root/failed-once" ]; then
          touch "$root/failed-once"
          printf 'Connection reset by peer\\n' >&2
          exit 255
        fi
        while :; do cat "$root/live"; printf '\\n'; sleep 0.05; done
        """)
        var timing = HerdrTiming(); timing.retryDelays = [0.1, 0.2]
        let retried = expectation(description: "Reconnected baseline")
        var failed = false, settled = false
        var initialControl: URL?
        var replacement: URL?
        _ = monitor(fixture, timing: timing) { update in
            if initialControl == nil { initialControl = update.controlPath }
            XCTAssertFalse(update.sessions?.contains(where: { $0.mode == .completed }) == true)
            if update.connection.state == .hostUnavailable && !failed {
                failed = true
                replacement = update.controlPath
                do {
                    try fixture.write("probe", HerdrFixture.snapshot("idle"))
                    try fixture.write("live", HerdrFixture.snapshot("idle"))
                } catch { XCTFail(error.localizedDescription) }
            }
            if failed && update.connection.state == .connected && update.sessions == [] && !settled {
                settled = true; retried.fulfill()
            }
        }
        wait(for: [retried], timeout: 5)
        XCTAssertNotEqual(initialControl, replacement)
    }

    func testIncompatibleStreamRediscoversOnlyOnce() throws {
        let fixture = try fixture()
        try fixture.write("live", "incompatible output")
        var timing = HerdrTiming()
        timing.outputTimeout = 0.15; timing.retryDelays = [0.05]
        let stopped = expectation(description: "Persistent incompatibility requires user action")
        var reported = false
        _ = monitor(fixture, timing: timing) { update in
            if update.connection.state == .incompatibleResponse && update.connection.retryAt == nil && !reported {
                reported = true; stopped.fulfill()
            }
        }
        wait(for: [stopped], timeout: 5)
        XCTAssertEqual(try fixture.read("calls").components(separatedBy: "while :;").count - 1, 2)
    }

    func testMovedBinaryIsRediscoveredAndInvalidOverrideIsReported() throws {
        let fixture = try fixture()
        let root = HookConfiguration.shellQuote(fixture.root.path)
        try fixture.write("stream", """
        root=\(root)
        if [ ! -f "$root/moved" ]; then
          touch "$root/moved"
          printf 'SIDEPULSE_REMOTE_OS=Linux\\nSIDEPULSE_HERDR_CANDIDATE=/new-herdr\\n' > "$root/discovery"
          exit 127
        fi
        while :; do cat "$root/live"; printf '\\n'; sleep 0.05; done
        """)
        let moved = expectation(description: "New executable discovered")
        var reported = false
        let worker = monitor(fixture) { update in
            if update.connection.state == .connected && update.connection.path == "/new-herdr" && !reported {
                reported = true; moved.fulfill()
            }
        }
        wait(for: [moved], timeout: 5)
        worker.stop()
        var remote = self.remote; remote.herdrPath = "/bad-herdr"
        let invalid = expectation(description: "Bad path override")
        _ = monitor(fixture, remote: remote, once: true) { update in
            if update.finished {
                XCTAssertEqual(update.connection.state, .invalidPath)
                invalid.fulfill()
            }
        }
        wait(for: [invalid], timeout: 3)
    }
}
