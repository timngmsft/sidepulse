import Foundation
import XCTest
@testable import SidePulseCore

final class LEDOutputTests: XCTestCase {
    private final class Record<Value> {
        private let lock = NSLock()
        private var storage: [Value] = []
        var values: [Value] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func append(_ value: Value) {
            lock.lock(); defer { lock.unlock() }
            storage.append(value)
        }
    }

    private let file = URL(fileURLWithPath: "/unused/device/LEDS.LED")
    private var target: LEDTarget { LEDTarget(file: file, program: "#00A0B3") }

    func testDisabledOutputReleasesOnlyOwnedDevicesOnce() {
        let queue = DispatchQueue(label: "test-led-release")
        let writes = Record<String>()
        let output = LEDOutput(queue: queue, write: { program, _ in writes.append(program) },
                               onError: { _, error in XCTFail(error.localizedDescription) })
        let attached = ["owned": file, "unused": URL(fileURLWithPath: "/unused/other/LEDS.LED")]
        output.apply([:], connected: attached)
        queue.sync {}
        XCTAssertTrue(writes.values.isEmpty, "Disabled or preview output must never acquire a device.")
        output.apply(["owned": target], connected: attached)
        queue.sync {}
        XCTAssertEqual(writes.values, [target.program])
        XCTAssertEqual(output.diagnostics["writeAttempts"]?.number, 1)
        XCTAssertEqual(output.diagnostics["completedWrites"]?.number, 1)
        XCTAssertEqual(output.diagnostics["lastFile"]?.string, file.path)

        queue.suspend()
        output.apply([:], connected: attached)
        output.apply([:], connected: attached)
        queue.resume()
        queue.sync {}
        XCTAssertEqual(writes.values, [target.program, "off"])
        XCTAssertEqual(output.diagnostics["desiredCount"]?.number, 0)
        XCTAssertEqual(output.diagnostics["completedWrites"]?.number, 2)

        output.apply([:], connected: attached, force: true)
        queue.sync {}
        XCTAssertEqual(writes.values, [target.program, "off"], "A released device must remain untouched.")
    }

    func testUnplugCancelsPendingWritesAndReconnectRestoresOutput() {
        let queue = DispatchQueue(label: "test-led-reconnect")
        let writes = Record<String>()
        let output = LEDOutput(queue: queue, write: { program, _ in writes.append(program) },
                               onError: { _, error in XCTFail(error.localizedDescription) })
        queue.suspend()
        output.apply(["device": target], connected: ["device": file])
        output.apply([:], connected: [:])
        queue.resume()
        queue.sync {}
        XCTAssertTrue(writes.values.isEmpty, "Unplugging must not write an off command to a stale mount path.")

        output.apply(["device": target], connected: ["device": file], force: true)
        queue.sync {}
        XCTAssertEqual(writes.values, [target.program])
    }

    func testReenablingSupersedesAPendingRelease() {
        let queue = DispatchQueue(label: "test-led-reenable")
        let writes = Record<String>()
        let output = LEDOutput(queue: queue, write: { program, _ in writes.append(program) },
                               onError: { _, error in XCTFail(error.localizedDescription) })
        output.apply(["device": target], connected: ["device": file])
        queue.sync {}
        queue.suspend()
        output.apply([:], connected: ["device": file])
        output.apply(["device": target], connected: ["device": file])
        queue.resume()
        queue.sync {}
        XCTAssertEqual(writes.values, [target.program, target.program])
    }

    func testFailedWritesRecoverWithoutAnotherAgentEvent() {
        let recovered = expectation(description: "Latest program retried")
        let attempts = Record<String>()
        let errors = Record<String>()
        let output = LEDOutput(write: { program, _ in
            attempts.append(program)
            if attempts.values.count < 3 { throw NativeError("Temporarily unavailable") }
            recovered.fulfill()
        }, retryDelays: [0.01, 0.02], onError: { _, error in errors.append(error.localizedDescription) })
        output.apply(["device": target])
        wait(for: [recovered], timeout: 2)
        XCTAssertEqual(attempts.values, Array(repeating: target.program, count: 3))
        XCTAssertEqual(errors.values, ["Temporarily unavailable"], "Retries must not flood the UI with the same error.")
        withExtendedLifetime(output) {}
    }

    func testNewStateCancelsAnOldRetry() {
        let queue = DispatchQueue(label: "test-led-superseded-retry")
        let failed = expectation(description: "Old write failed")
        let writes = Record<String>()
        let output = LEDOutput(queue: queue, write: { program, _ in
            writes.append(program)
            if program == "#FF0000" { throw NativeError("Old write failed") }
        }, retryDelays: [0.05], onError: { _, _ in failed.fulfill() })
        output.apply(["device": LEDTarget(file: file, program: "#FF0000")])
        wait(for: [failed], timeout: 2)
        output.apply(["device": target])
        Thread.sleep(forTimeInterval: 0.1)
        queue.sync {}
        XCTAssertEqual(writes.values, ["#FF0000", target.program])
    }

    func testKeepaliveOnlyTouchesOwnedActiveDevicesAndPauses() {
        let queue = DispatchQueue(label: "test-led-keepalive")
        let touched = expectation(description: "Owned volume kept active")
        let touches = Record<URL>()
        let output = LEDOutput(queue: queue, write: { _, _ in }, touch: { root in
            touches.append(root)
            if touches.values.count == 1 { touched.fulfill() }
        }, keepAliveInterval: 0.02, onError: { _, error in XCTFail(error.localizedDescription) })
        let attached = ["device": file, "unused": URL(fileURLWithPath: "/unused/other/LEDS.LED")]
        output.apply(["device": target], connected: attached)
        wait(for: [touched], timeout: 2)
        output.apply(["device": target], connected: attached, keepAlive: false)
        queue.sync {}
        let paused = touches.values
        XCTAssertTrue(paused.allSatisfy { $0 == file.deletingLastPathComponent() })
        Thread.sleep(forTimeInterval: 0.06)
        queue.sync {}
        XCTAssertEqual(touches.values, paused)

        output.apply([:], connected: attached)
        queue.sync {}
        Thread.sleep(forTimeInterval: 0.06)
        queue.sync {}
        XCTAssertEqual(touches.values, paused, "Released devices must not get keepalive writes.")
    }

    func testShutdownWritesOffAndCompletesAfterTheWrite() {
        let finished = expectation(description: "Output safely drained")
        let queue = DispatchQueue(label: "test-led-shutdown")
        let writes = Record<String>()
        let output = LEDOutput(queue: queue, write: { program, _ in writes.append(program) },
                               onError: { _, error in XCTFail(error.localizedDescription) })
        output.apply(["device": target])
        queue.sync {}
        output.stop { drained in
            XCTAssertTrue(drained)
            XCTAssertEqual(writes.values, [self.target.program, "off"])
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        output.apply(["device": target])
        queue.sync {}
        XCTAssertEqual(writes.values, [target.program, "off"])
    }

    func testShutdownDoesNotWaitForAPendingReleaseRetry() {
        let releaseFailed = expectation(description: "Initial release failed")
        let finished = expectation(description: "Shutdown retries off immediately")
        let queue = DispatchQueue(label: "test-led-shutdown-retry")
        let writes = Record<String>()
        let output = LEDOutput(queue: queue, write: { program, _ in
            writes.append(program)
            if program == "off" && writes.values.filter({ $0 == "off" }).count == 1 {
                throw NativeError("Release failed")
            }
        }, retryDelays: [10], onError: { _, _ in releaseFailed.fulfill() })
        output.apply(["device": target], connected: ["device": file])
        queue.sync {}
        output.apply([:], connected: ["device": file])
        wait(for: [releaseFailed], timeout: 2)
        output.stop { drained in
            XCTAssertTrue(drained)
            XCTAssertEqual(writes.values, [self.target.program, "off", "off"])
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testShutdownDeadlineDoesNotBlockAndRepliesOnlyOnce() {
        let timedOut = expectation(description: "Bounded shutdown")
        let queue = DispatchQueue(label: "test-led-shutdown-deadline")
        let replies = Record<Bool>()
        let writes = Record<String>()
        let output = LEDOutput(queue: queue, write: { program, _ in writes.append(program) },
                               onError: { _, error in XCTFail(error.localizedDescription) })
        queue.suspend()
        output.apply(["device": target])
        output.stop(timeout: 0.02) { drained in
            replies.append(drained)
            timedOut.fulfill()
        }
        wait(for: [timedOut], timeout: 2)
        XCTAssertEqual(replies.values, [false])
        queue.resume()
        queue.sync {}
        XCTAssertEqual(replies.values, [false])
        XCTAssertEqual(writes.values, ["off"], "Shutdown must supersede queued active programs.")
    }

    func testProgramWritesPreserveTheFileAndKeepalivePreservesContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spn-led-\(UUID().uuidString)")
        try NativeIPC.preparePrivateDirectory(root)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not remove LED fixture: \(error)") }
        }
        let file = root.appendingPathComponent("LEDS.LED")
        try Data("#FF0000\nrepeat".utf8).write(to: file)
        let original = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)
        try LEDProgram.write("off", to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "off")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber, original)

        let keepalive = root.appendingPathComponent("keepalive")
        try Data("preserve".utf8).write(to: keepalive)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: keepalive.path)
        try LEDProgram.keepAlive(at: root)
        XCTAssertEqual(try String(contentsOf: keepalive, encoding: .utf8), "preserve")
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: keepalive.path)[.modificationDate] as? Date)
        XCTAssertLessThan(Date().timeIntervalSince(modified), 5)
    }
}
