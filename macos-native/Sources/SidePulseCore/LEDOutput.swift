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
    }
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let write: (String, URL) throws -> Void
    private let onError: (String, Error) -> Void
    private var desired: [String: Intent] = [:]
    private var revision = 0

    public init(queue: DispatchQueue = DispatchQueue(label: "io.sidepulse.native.led-output", qos: .utility),
                write: @escaping (String, URL) throws -> Void = { try LEDProgram.write($0, to: $1) },
                onError: @escaping (String, Error) -> Void) {
        self.queue = queue; self.write = write; self.onError = onError
    }

    public func apply(_ targets: [String: LEDTarget], force: Bool = false) {
        var pending: [(String, Intent)] = []
        lock.lock()
        desired = desired.filter { targets[$0.key] != nil }
        for (id, target) in targets {
            guard force || desired[id]?.target != target else { continue }
            revision += 1
            let intent = Intent(target: target, revision: revision)
            desired[id] = intent
            pending.append((id, intent))
        }
        lock.unlock()
        for (id, intent) in pending {
            queue.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let current = self.desired[id] == intent
                self.lock.unlock()
                guard current else { return }
                do { try self.write(intent.target.program, intent.target.file) }
                catch {
                    self.lock.lock()
                    if self.desired[id] == intent { self.desired.removeValue(forKey: id) }
                    self.lock.unlock()
                    self.onError(id, error)
                }
            }
        }
    }
}
