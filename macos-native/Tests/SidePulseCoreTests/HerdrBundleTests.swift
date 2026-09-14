import Foundation
import XCTest
@testable import SidePulseCore

final class HerdrBundleTests: XCTestCase {
    func testStandaloneRemotesSettingsAggregationAndLifecycle() throws {
        guard let path = ProcessInfo.processInfo.environment["SIDEPULSE_NATIVE_APP"] else {
            throw XCTSkip("Set SIDEPULSE_NATIVE_APP to exercise the native remote UI.")
        }
        let app = URL(fileURLWithPath: path, isDirectory: true)
        let root = app.deletingLastPathComponent().appendingPathComponent("herdr-smoke-\(UUID().uuidString.prefix(8))")
        let fixture = try HerdrFixture(root: root)
        let paths = NativePaths(root: root)
        var first = RemoteConfiguration()
        first.name = "Work Mac"; first.target = "fixture-one"
        var second = RemoteConfiguration()
        second.name = "Build Host"; second.target = "fixture-two"
        var configuration = AppConfiguration()
        configuration.remotes = [first, second]
        try Persistence.save(configuration, to: paths.configuration)
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/SidePulseNative")
        process.arguments = ["--copilot-testing", "--state-dir", root.path, "--test-ssh", fixture.ssh.path, "--show-remotes"]
        process.standardOutput = FileHandle.nullDevice
        let errorFile = root.appendingPathComponent("app-errors")
        try Data().write(to: errorFile)
        let errors = try FileHandle(forWritingTo: errorFile)
        process.standardError = errors
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            do {
                try errors.close()
                try fixture.remove()
                let socketDirectory = paths.socket.deletingLastPathComponent()
                if socketDirectory != root && FileManager.default.fileExists(atPath: socketDirectory.path) {
                    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: socketDirectory.path).isEmpty)
                    try FileManager.default.removeItem(at: socketDirectory)
                }
            } catch { XCTFail("Could not clean up the isolated Herdr application: \(error)") }
        }
        try process.run()
        let readyDeadline = Date().addingTimeInterval(10)
        var ready = false
        while process.isRunning && Date() < readyDeadline {
            if (try? NativeIPC.request(Data(#"{"action":"ping"}"#.utf8), socket: paths.socket, timeout: 0.2)) != nil {
                ready = true; break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let launchErrors = try String(contentsOf: errorFile, encoding: .utf8)
        XCTAssertTrue(ready, launchErrors)
        guard ready else { return }

        func request(_ action: String, values: [String: JSONValue] = [:]) throws -> JSONValue {
            var message = values
            message["action"] = .string(action)
            let result = try NativeIPC.request(JSONEncoder().encode(JSONValue.object(message)), socket: paths.socket)
            let value = try JSONDecoder().decode(JSONValue.self, from: result)
            XCTAssertEqual(value["ok"]?.bool, true, value["error"]?.string ?? action)
            return value
        }
        func waitFor(_ condition: (JSONValue) -> Bool, timeout: TimeInterval = 8,
                     file: StaticString = #filePath, line: UInt = #line) throws -> JSONValue {
            let deadline = Date().addingTimeInterval(timeout)
            var latest = try request("snapshot")
            while !condition(latest) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
                latest = try request("snapshot")
            }
            XCTAssertTrue(condition(latest), "Unexpected remote snapshot: \(latest)", file: file, line: line)
            return latest
        }
        func saveRemotes() throws {
            let values = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode([first, second]))
            _ = try request("set-test-remotes", values: ["remotes": values])
        }
        func remoteSessions(_ snapshot: JSONValue) -> [JSONValue] {
            snapshot["sessions"]?.array?.filter { $0["remoteID"]?.string != nil } ?? []
        }
        func streamCount() throws -> Int { try fixture.read("calls").components(separatedBy: "while :;").count - 1 }
        func waitForStreams(_ expected: Int) throws -> Int {
            // A successful preflight publishes Connected before the polling process starts.
            let deadline = Date().addingTimeInterval(3)
            var count = try streamCount()
            while count < expected && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
                count = try streamCount()
            }
            return count
        }

        let connected = try waitFor {
            $0["remotes"]?[first.id]?["state"]?.string == "connected" &&
            $0["remotes"]?[second.id]?["state"]?.string == "connected" &&
            remoteSessions($0).count == 2 && $0["ui"]?["label"]?.string == "Working"
        }
        XCTAssertEqual(connected["remotesAllowed"]?.bool, true)
        XCTAssertEqual(connected["systemChangesAllowed"]?.bool, false)
        XCTAssertEqual(connected["ui"]?["width"]?.number, 96)
        for provider in Provider.allCases {
            XCTAssertEqual(connected["hookChangesAllowed"]?[provider.rawValue]?.bool, provider == .copilot)
        }
        XCTAssertEqual(Set(remoteSessions(connected).compactMap { $0["remoteID"]?.string }), [first.id, second.id])
        let secondAge = remoteSessions(connected).first { $0["remoteID"]?.string == second.id }?["updatedAt"]
        _ = try waitFor { $0["remotes"]?[second.id]?["lastSuccess"]?.string != nil }
        Thread.sleep(forTimeInterval: 0.15)
        let capture = try request("capture-remotes")
        let image = try XCTUnwrap(capture["path"]?.string)
        XCTAssertGreaterThan(try Data(contentsOf: URL(fileURLWithPath: image)).count, 1000)
        if let destination = ProcessInfo.processInfo.environment["SIDEPULSE_REMOTE_CAPTURE"] {
            try FileManager.default.copyItem(atPath: image, toPath: destination)
        }
        let streams = try waitForStreams(2)
        XCTAssertEqual(streams, 2)

        _ = try request("capture-settings")
        let beforeHeartbeat = try request("snapshot")
        let modelUpdates = try XCTUnwrap(beforeHeartbeat["ui"]?["modelUpdates"]?.number)
        Thread.sleep(forTimeInterval: 1.1)
        let afterHeartbeat = try request("snapshot")
        XCTAssertNotEqual(afterHeartbeat["remotes"]?[first.id]?["lastSuccess"],
                          beforeHeartbeat["remotes"]?[first.id]?["lastSuccess"])
        XCTAssertNotEqual(remoteSessions(afterHeartbeat).first { $0["remoteID"]?.string == first.id }?["observedAt"],
                          remoteSessions(beforeHeartbeat).first { $0["remoteID"]?.string == first.id }?["observedAt"])
        XCTAssertEqual(afterHeartbeat["ui"]?["modelUpdates"]?.number, modelUpdates,
                       "Unchanged remote heartbeats must not invalidate the application-wide UI model.")
        XCTAssertEqual(afterHeartbeat["ui"]?["label"]?.string, "Working")

        first.name = "Renamed remote"
        try saveRemotes()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(try streamCount(), streams, "A display-name edit must not restart SSH.")
        first.enabled = false
        try saveRemotes()
        let disabled = try waitFor {
            $0["remotes"]?[first.id]?["state"]?.string == "disabled" &&
            remoteSessions($0).count == 1 && remoteSessions($0).first?["remoteID"]?.string == second.id
        }
        XCTAssertEqual(remoteSessions(disabled).first?["updatedAt"], secondAge)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(remoteSessions(try request("snapshot")).count, 1, "Old callbacks must not restore a disabled source.")

        first.target = "fixture-replacement"; first.enabled = true
        try saveRemotes()
        let replaced = try waitFor { remoteSessions($0).count == 2 && $0["remotes"]?[first.id]?["state"]?.string == "connected" }
        XCTAssertEqual(remoteSessions(replaced).first { $0["remoteID"]?.string == second.id }?["updatedAt"], secondAge)
        XCTAssertEqual(try waitForStreams(streams + 1), streams + 1, "Endpoint edits must not restart unrelated remotes.")

        let question = HookEnvelope(provider: .copilot, line: .object([
            "hook_event_name": .string("Notification"), "notification_type": .string("elicitation_dialog"),
            "session_id": .string("native-herdr-local"), "session_title": .string("Local Copilot"),
            "message": .string("Choose a fixture option")
        ]))
        let accepted = try NativeIPC.request(JSONEncoder().encode(question), socket: paths.socket)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: accepted)["ok"]?.bool, true)
        try fixture.write("probe", HerdrFixture.snapshot("idle"))
        try fixture.write("live", HerdrFixture.snapshot("idle"))
        let completed = try waitFor {
            remoteSessions($0).count == 2 && remoteSessions($0).allSatisfy { $0["mode"]?.string == "completed" }
        }
        XCTAssertEqual(completed["state"]?.string, "Ask", "Remote completions must not hide a local question.")
        XCTAssertEqual(completed["ui"]?["width"]?.number, 96)

        _ = try request("test-sleep")
        let asleep = try waitFor { remoteSessions($0).isEmpty && $0["remotes"]?[first.id]?["state"]?.string == "paused" }
        XCTAssertEqual(asleep["state"]?.string, "Ask")
        let sleepingStreams = try streamCount()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(try streamCount(), sleepingStreams)
        _ = try request("test-wake")
        let awake = try waitFor {
            $0["remotes"]?[first.id]?["state"]?.string == "connected" &&
            $0["remotes"]?[second.id]?["state"]?.string == "connected"
        }
        XCTAssertTrue(remoteSessions(awake).isEmpty, "Wake must establish a fresh baseline instead of replaying Done.")
        XCTAssertEqual(awake["state"]?.string, "Ask")
        let persisted = try XCTUnwrap(Persistence.load(AppConfiguration.self, from: paths.configuration))
        XCTAssertTrue(persisted.remotes.allSatisfy { $0.resolvedHerdrPath == "/good-herdr" })
        XCTAssertFalse(persisted.physicalLEDsEnabled)
        XCTAssertEqual(persisted.awakePolicy, .never)

        _ = try request("quit")
        let exitDeadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertFalse(process.isRunning)
        let sessions = try XCTUnwrap(Persistence.load([AgentSession].self, from: paths.sessions))
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionID, "native-herdr-local")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socket.path))
    }
}
