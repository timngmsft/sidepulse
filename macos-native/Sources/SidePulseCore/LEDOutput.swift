import Foundation

public struct LEDTarget: Equatable, Sendable {
    public var file: URL
    public var program: String
    public init(file: URL, program: String) { self.file = file; self.program = program }
}

public final class LEDOutput {
    private struct Intent: Equatable {
        var target: LEDTarget
        var revision: Int
        var releasing: Bool
    }
    private final class ShutdownReply {
        private let lock = NSLock()
        private var completion: ((Bool) -> Void)?

        init(_ completion: @escaping (Bool) -> Void) { self.completion = completion }

        func finish(_ drained: Bool) {
            lock.lock()
            let callback = completion
            completion = nil
            lock.unlock()
            callback?(drained)
        }
    }
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let write: (String, URL) throws -> Void
    private let touch: (URL) throws -> Void
    private let retryDelays: [TimeInterval]
    private let onError: (String, Error) -> Void
    private var desired: [String: Intent] = [:]
    private var connected: [String: URL] = [:]
    private var revision = 0
    private var stopped = false
    private var keepAliveEnabled = true
    private var keepAliveTimer: DispatchSourceTimer?
    private var writeAttempts = 0
    private var completedWrites = 0
    private var lastFile: URL?

    public init(queue: DispatchQueue = DispatchQueue(label: "io.sidepulse.native.led-output", qos: .utility),
                write: @escaping (String, URL) throws -> Void = { try LEDProgram.write($0, to: $1) },
                touch: @escaping (URL) throws -> Void = { try LEDProgram.keepAlive(at: $0) },
                keepAliveInterval: TimeInterval = 60,
                retryDelays: [TimeInterval] = [1, 2, 5, 15, 30],
                onError: @escaping (String, Error) -> Void) {
        precondition(keepAliveInterval.isFinite && keepAliveInterval > 0)
        precondition(!retryDelays.isEmpty && retryDelays.allSatisfy { $0.isFinite && $0 > 0 })
        self.queue = queue; self.write = write; self.onError = onError
        self.touch = touch; self.retryDelays = retryDelays
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + keepAliveInterval, repeating: keepAliveInterval,
                       leeway: .milliseconds(Int(min(5, keepAliveInterval / 10) * 1000)))
        timer.setEventHandler { [weak self] in self?.keepAlive() }
        timer.resume()
        keepAliveTimer = timer
    }

    deinit { keepAliveTimer?.cancel() }

    public var diagnostics: [String: JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return [
            "stopped": .bool(stopped),
            "connectedCount": .number(Double(connected.count)),
            "desiredCount": .number(Double(desired.count)),
            "writeAttempts": .number(Double(writeAttempts)),
            "completedWrites": .number(Double(completedWrites)),
            "lastFile": lastFile.map { .string($0.path) } ?? .null,
            "programs": .object(desired.mapValues { .string($0.target.program) })
        ]
    }

    public func apply(_ targets: [String: LEDTarget], connected: [String: URL]? = nil,
                      force: Bool = false, keepAlive: Bool = true) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        self.connected = connected ?? targets.mapValues(\.file)
        keepAliveEnabled = keepAlive
        let pending = updateTargets(targets, force: force)
        lock.unlock()
        enqueue(pending)
    }

    // Called with the lock held. A final off command stays owned until it is written,
    // so a subsequent update cannot cancel a queued release or repeatedly touch a released device.
    private func updateTargets(_ targets: [String: LEDTarget], force: Bool) -> [(String, Intent)] {
        var pending: [(String, Intent)] = []
        for (id, previous) in desired {
            guard let file = connected[id] else { desired.removeValue(forKey: id); continue }
            guard targets[id] == nil else { continue }
            if previous.releasing && previous.target.file == file && !force { continue }
            revision += 1
            let intent = Intent(target: LEDTarget(file: file, program: "off"), revision: revision, releasing: true)
            desired[id] = intent
            pending.append((id, intent))
        }
        for (id, target) in targets {
            guard connected[id] == target.file else { continue }
            guard force || desired[id]?.target != target || desired[id]?.releasing == true else { continue }
            revision += 1
            let intent = Intent(target: target, revision: revision, releasing: false)
            desired[id] = intent
            pending.append((id, intent))
        }
        return pending
    }

    private func enqueue(_ pending: [(String, Intent)]) {
        for (id, intent) in pending {
            queue.async { [weak self] in self?.performWrite(id, intent: intent, attempt: 0) }
        }
    }

    private func performWrite(_ id: String, intent: Intent, attempt: Int) {
        lock.lock()
        let current = desired[id] == intent
        if current { writeAttempts += 1; lastFile = intent.target.file }
        lock.unlock()
        guard current else { return }
        do {
            try write(intent.target.program, intent.target.file)
            lock.lock()
            completedWrites += 1
            if intent.releasing && desired[id] == intent { desired.removeValue(forKey: id) }
            lock.unlock()
        } catch {
            lock.lock()
            let relevant = desired[id] == intent
            let retry = relevant && !stopped
            lock.unlock()
            guard relevant else { return }
            if attempt == 0 || !retry { onError(id, error) }
            if retry {
                let delay = retryDelays[min(attempt, retryDelays.count - 1)]
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.performWrite(id, intent: intent, attempt: attempt + 1)
                }
            }
        }
    }

    private func keepAlive() {
        lock.lock()
        guard !stopped, keepAliveEnabled else { lock.unlock(); return }
        let active = desired.filter { !$0.value.releasing }
        lock.unlock()
        for (id, intent) in active {
            lock.lock()
            let current = !stopped && keepAliveEnabled && desired[id] == intent
            lock.unlock()
            guard current else { continue }
            do { try touch(intent.target.file.deletingLastPathComponent()) }
            catch { onError(id, NativeError("Could not keep the SidePulse volume active: \(error.localizedDescription)")) }
        }
    }

    public func stop(timeout: TimeInterval = 2, completion: @escaping (Bool) -> Void) {
        precondition(timeout.isFinite && timeout > 0)
        lock.lock()
        let pending = stopped ? [] : updateTargets([:], force: true)
        stopped = true
        keepAliveTimer?.cancel()
        lock.unlock()
        enqueue(pending)
        let reply = ShutdownReply(completion)
        queue.async { reply.finish(true) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { reply.finish(false) }
    }
}
