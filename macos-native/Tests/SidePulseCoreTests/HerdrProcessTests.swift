import Foundation
import XCTest
@testable import SidePulseCore

final class HerdrProcessTests: XCTestCase {
    private func execute(_ script: String, timeout: TimeInterval = 3,
                         line: ((Result<Data, HerdrFailure>) -> Void)? = nil) throws -> HerdrProcessResult {
        let queue = DispatchQueue(label: "herdr.process.test")
        let ended = expectation(description: "Bounded command ended")
        var result: HerdrProcessResult?
        let job = HerdrProcess(queue: queue, log: { XCTFail($0) }, line: line) {
            result = $0; ended.fulfill()
        }
        queue.async {
            do { try job.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: timeout) }
            catch { XCTFail(error.localizedDescription); ended.fulfill() }
        }
        wait(for: [ended], timeout: timeout + 3)
        queue.sync { job.cancel() }
        return try XCTUnwrap(result)
    }

    func testCommandDrainsLargeStderrIndependentlyAndKeepsOnlyItsTail() throws {
        let result = try execute("/bin/dd if=/dev/zero bs=1024 count=200 1>&2 2>/dev/null; printf 'ok\\n'")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, Data("ok\n".utf8))
        XCTAssertEqual(result.diagnostics.utf8.count, 8192)
        XCTAssertNil(result.failure)
    }

    func testOversizedCommandOutputIsBounded() throws {
        let result = try execute("/bin/dd if=/dev/zero bs=1024 count=200 2>/dev/null")
        XCTAssertEqual(result.failure?.state, .incompatibleResponse)
        XCTAssertLessThanOrEqual(result.output.count, 131_072)
    }

    func testOversizedStreamingRecordIsDiscardedBeforeFollowingRecords() throws {
        var oversized = 0
        var records: [Data] = []
        let result = try execute("/bin/dd if=/dev/zero bs=1024 count=1025 2>/dev/null; printf '\\nvalid\\nfinal-without-newline'") {
            switch $0 {
            case .success(let data): records.append(data)
            case .failure(let failure):
                XCTAssertEqual(failure.state, .incompatibleResponse)
                oversized += 1
            }
        }
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(oversized, 1)
        XCTAssertEqual(records, [Data("valid".utf8), Data("final-without-newline".utf8)])
    }

    func testSilenceTimeoutTerminatesOwnedCommand() throws {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try execute("exec /bin/sleep 30", timeout: 0.15)
        XCTAssertEqual(result.failure?.state, .hostUnavailable)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }

    func testCancellationRemainsResponsiveDuringContinuousOutput() {
        let queue = DispatchQueue(label: "herdr.flood.test")
        let stopped = expectation(description: "Continuous output cancelled")
        let job = HerdrProcess(queue: queue, log: { XCTFail($0) }, line: { _ in }) { _ in
            XCTFail("Cancellation must not report a completed command.")
        }
        let start = ProcessInfo.processInfo.systemUptime
        queue.async {
            do {
                try job.start(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: ["noise"], timeout: nil)
            } catch { XCTFail(error.localizedDescription) }
        }
        queue.asyncAfter(deadline: .now() + 0.1) { job.cancel(); stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testPollCommandQuotesPathsAndContinuesAfterValidErrorExit() throws {
        let fixture = try HerdrFixture()
        defer { do { try fixture.remove() } catch { XCTFail(error.localizedDescription) } }
        let name = "Herdr's executable"
        try fixture.write(name, """
        #!/bin/sh
        printf '%s\\n' '{"id":"cli:agent:list","error":{"code":"server_not_running","message":"Start Herdr."}}'
        exit 1
        """, executable: true)
        var remote = RemoteConfiguration(); remote.target = "fixture"; remote.session = "default"
        let command = try HerdrCommands.agentList(path: fixture.root.appendingPathComponent(name).path,
                                                   remote: remote, polling: true)
        XCTAssertFalse(command.contains("--session"))
        let queue = DispatchQueue(label: "herdr.poll.script")
        let twice = expectation(description: "Error responses continue polling")
        var count = 0
        let job = HerdrProcess(queue: queue, log: { XCTFail($0) }, line: { record in
            do {
                guard case .failure(let failure) = try HerdrRecord.parse(record.get()) else {
                    return XCTFail("Expected a valid error envelope.")
                }
                XCTAssertEqual(failure.state, .notRunning)
                count += 1
                if count == 2 { twice.fulfill() }
            } catch { XCTFail(error.localizedDescription) }
        }) { _ in XCTFail("The polling loop exited instead of forwarding an error response.") }
        queue.async {
            do { try job.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec " + command], timeout: nil) }
            catch { XCTFail(error.localizedDescription) }
        }
        wait(for: [twice], timeout: 5)
        queue.sync { job.cancel() }
    }

    private func waitUntil(_ condition: () throws -> Bool, timeout: TimeInterval = 3) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("The authentication fixture timed out.")
    }

    func testTerminalAuthenticationOnlyKeepsAcknowledgedConnections() throws {
        for fails in [false, true] {
            let fixture = try HerdrFixture()
            defer { do { try fixture.remove() } catch { XCTFail(error.localizedDescription) } }
            if fails { try fixture.write("auth-fail", "") }
            var remote = RemoteConfiguration(); remote.target = "fixture"
            let attempt = try HerdrAuthentication(remote: remote, root: fixture.root, controlPath: fixture.control,
                                                   executable: fixture.ssh)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [attempt.command.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
            try process.run()
            try waitUntil { try attempt.exitStatus() != nil }
            XCTAssertEqual(try attempt.exitStatus(), fails ? 255 : 0)
            if !fails { try attempt.acknowledge() }
            try waitUntil { !process.isRunning }
            XCTAssertEqual(process.terminationStatus, fails ? 255 : 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: attempt.finished.path))
            XCTAssertEqual(FileManager.default.fileExists(atPath: attempt.accepted.path), !fails)
            XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("closed").path), fails)
            try attempt.removeFiles()
        }
    }

    func testCancellingTerminalAuthenticationStopsPendingSSHAndClosesOwnedMaster() throws {
        let fixture = try HerdrFixture()
        defer { do { try fixture.remove() } catch { XCTFail(error.localizedDescription) } }
        try fixture.write("auth-block", "")
        var remote = RemoteConfiguration(); remote.target = "fixture"
        let attempt = try HerdrAuthentication(remote: remote, root: fixture.root, controlPath: fixture.control,
                                               executable: fixture.ssh)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [attempt.command.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        try process.run()
        try waitUntil { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("pids").path) }
        try attempt.cancel()
        try waitUntil { !process.isRunning }
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertNotEqual(try attempt.exitStatus(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("closed").path))
        try attempt.removeFiles()
    }
}
