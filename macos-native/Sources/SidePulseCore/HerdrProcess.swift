import Darwin
import Foundation

struct HerdrProcessResult {
    var status: Int32
    var output: Data
    var diagnostics: String
    var failure: HerdrFailure?
}

final class HerdrProcess {
    private let queue: DispatchQueue
    private let log: (String) -> Void
    private let completion: (HerdrProcessResult) -> Void
    private let line: ((Result<Data, HerdrFailure>) -> Void)?
    private let process = Process()
    private var readers: [Int32: DispatchSourceRead] = [:]
    private var deadline: DispatchWorkItem?
    private var output = Data()
    private var diagnostics = Data()
    private var pending = Data()
    private var discarding = false
    private var exited: Int32?
    private var finished = false

    init(queue: DispatchQueue, log: @escaping (String) -> Void,
         line: ((Result<Data, HerdrFailure>) -> Void)? = nil,
         completion: @escaping (HerdrProcessResult) -> Void) {
        self.queue = queue; self.log = log; self.line = line; self.completion = completion
    }

    func start(executable: URL, arguments: [String], timeout: TimeInterval?) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        do {
            for handle in [stdout.fileHandleForWriting, stderr.fileHandleForWriting] {
                guard fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                    throw NativeError("Could not isolate SSH output handles: \(String(cString: strerror(errno)))")
                }
            }
            try watch(stdout.fileHandleForReading, stderr: false)
            try watch(stderr.fileHandleForReading, stderr: true)
            process.terminationHandler = { [weak self] child in
                self?.queue.async { [weak self] in
                    self?.exited = child.terminationStatus
                    self?.finishIfDrained()
                }
            }
            try process.run()
            try stdout.fileHandleForWriting.close()
            try stderr.fileHandleForWriting.close()
        } catch {
            cancel()
            throw error
        }
        if let timeout {
            let deadline = DispatchWorkItem { [weak self] in
                self?.fail(HerdrFailure(.hostUnavailable, "SSH command timed out."))
            }
            self.deadline = deadline
            queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        deadline?.cancel(); deadline = nil
        for reader in readers.values { reader.cancel() }
        readers.removeAll()
        terminate()
    }

    private func watch(_ handle: FileHandle, stderr: Bool) throws {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            throw NativeError("Could not configure the SSH output pipe: \(String(cString: strerror(errno)))")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.read(fd, stderr: stderr) }
        source.setCancelHandler { [log] in
            do { try handle.close() }
            catch { log("Could not close SSH output pipe: \(error.localizedDescription)") }
        }
        readers[fd] = source
        source.resume()
    }

    private func read(_ fd: Int32, stderr: Bool) {
        guard !finished else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        // Bounded reads on the owner queue provide backpressure without an unbounded callback queue.
        for _ in 0..<8 {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                consume(Data(bytes.prefix(count)), stderr: stderr)
                if finished { return }
            } else if count == 0 {
                readers.removeValue(forKey: fd)?.cancel()
                if !stderr && !pending.isEmpty && !discarding {
                    let last = pending; pending.removeAll(); line?(.success(last))
                }
                finishIfDrained()
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if errno != EINTR {
                fail(HerdrFailure(.hostUnavailable, "Could not read SSH output: \(String(cString: strerror(errno)))"))
                return
            }
        }
    }

    private func consume(_ data: Data, stderr: Bool) {
        if stderr {
            diagnostics.append(data)
            if diagnostics.count > 8192 { diagnostics = Data(diagnostics.suffix(8192)) }
        } else if line == nil {
            guard output.count + data.count <= 131_072 else {
                fail(HerdrFailure(.incompatibleResponse, "SSH command output exceeds 128 KiB."))
                return
            }
            output.append(data)
        } else {
            var start = data.startIndex
            while start < data.endIndex {
                let newline = data[start...].firstIndex(of: 10)
                let end = newline ?? data.endIndex
                if !discarding {
                    if pending.count + data.distance(from: start, to: end) > NativeIPC.requestLimit {
                        pending.removeAll(keepingCapacity: false)
                        discarding = true
                        line?(.failure(HerdrFailure(.incompatibleResponse, "Herdr response exceeds 1 MiB.")))
                    } else { pending.append(data[start..<end]) }
                }
                if let newline {
                    if !discarding {
                        let record = pending; pending.removeAll(keepingCapacity: true)
                        line?(.success(record))
                    }
                    discarding = false
                    start = data.index(after: newline)
                } else { break }
                if finished { return }
            }
        }
    }

    private func finishIfDrained() {
        guard !finished, let exited, readers.isEmpty else { return }
        finish(status: exited, failure: nil)
    }

    private func fail(_ failure: HerdrFailure) {
        guard !finished else { return }
        finish(status: exited ?? -1, failure: failure)
        terminate()
    }

    private func finish(status: Int32, failure: HerdrFailure?) {
        finished = true
        deadline?.cancel(); deadline = nil
        for reader in readers.values { reader.cancel() }
        readers.removeAll()
        completion(HerdrProcessResult(status: status, output: output,
                                      diagnostics: String(decoding: diagnostics, as: UTF8.self), failure: failure))
    }

    private func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        queue.asyncAfter(deadline: .now() + 0.5) { [process, log] in
            if process.isRunning && kill(process.processIdentifier, SIGKILL) != 0 && errno != ESRCH {
                log("Could not stop owned SSH process: \(String(cString: strerror(errno)))")
            }
        }
    }
}
