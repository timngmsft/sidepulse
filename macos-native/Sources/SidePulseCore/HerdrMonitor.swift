import Foundation

public struct HerdrTiming: Sendable {
    public var commandTimeout: TimeInterval = 15
    public var outputTimeout: TimeInterval = 10
    public var grace: TimeInterval = HerdrReducer.graceSeconds
    public var retryDelays: [TimeInterval] = [1, 2, 5, 15, 30]
    public init() {}
}

public struct HerdrUpdate: Sendable {
    public var connection: HerdrConnectionStatus
    public var sessions: [AgentSession]?
    public var controlPath: URL
    public var finished: Bool
}

private final class HerdrDelivery {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let callback: (HerdrUpdate) -> Void
    private var pending: HerdrUpdate?
    private var scheduled = false

    init(queue: DispatchQueue, callback: @escaping (HerdrUpdate) -> Void) {
        self.queue = queue; self.callback = callback
    }

    func post(_ update: HerdrUpdate) {
        lock.lock()
        var latest = update
        if latest.sessions == nil { latest.sessions = pending?.sessions }
        pending = latest
        let enqueue = !scheduled
        scheduled = true
        lock.unlock()
        if enqueue {
            queue.async {
                self.lock.lock()
                let update = self.pending
                self.pending = nil; self.scheduled = false
                self.lock.unlock()
                if let update { self.callback(update) }
            }
        }
    }

    func cancel() { lock.lock(); pending = nil; lock.unlock() }
}

public final class HerdrMonitor {
    public let configuration: RemoteConfiguration
    private let queue: DispatchQueue
    private let delivery: HerdrDelivery
    private let executable: URL
    private let once: Bool
    private let ownsControl: Bool
    private let timing: HerdrTiming
    private let log: (String) -> Void
    private let reducer = HerdrReducer()
    private var controlPath: URL
    private var command: HerdrProcess?
    private var retiredControls: Set<URL> = []
    private var timer: DispatchSourceTimer?
    private var stopped = true
    private var polling = false
    private var status = HerdrConnectionStatus(.connecting)
    private var candidates: [String] = []
    private var candidateFailure: HerdrFailure?
    private var attempt = 0
    private var retryAfter: TimeInterval?
    private var lastValid = 0.0
    private var lastOutput = 0.0
    private var lastSnapshot: TimeInterval?
    private var invalidDiagnostic: String?
    private var rediscovered = false

    public init(configuration: RemoteConfiguration, controlPath: URL, once: Bool = false,
                ownsControl: Bool = true, executable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
                timing: HerdrTiming = HerdrTiming(), deliveryQueue: DispatchQueue = .main,
                log: @escaping (String) -> Void, update: @escaping (HerdrUpdate) -> Void) {
        self.configuration = configuration; self.controlPath = controlPath
        self.once = once; self.ownsControl = ownsControl; self.executable = executable
        self.timing = timing; self.log = log
        delivery = HerdrDelivery(queue: deliveryQueue, callback: update)
        queue = DispatchQueue(label: "io.sidepulse.native.herdr.\(configuration.id).\(UUID().uuidString)", qos: .utility)
    }

    public func start() {
        queue.async {
            guard self.stopped else { return }
            self.stopped = false
            do {
                try self.configuration.validate()
                guard self.timing.commandTimeout > 0, self.timing.outputTimeout > 0, self.timing.grace > 0,
                      !self.timing.retryDelays.isEmpty, self.timing.retryDelays.allSatisfy({ $0 > 0 }) else {
                    throw NativeError("Invalid Herdr connection timing.")
                }
                try NativeIPC.preparePrivateDirectory(self.controlPath.deletingLastPathComponent())
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: min(0.25, self.timing.outputTimeout / 4, self.timing.grace / 4))
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer
                timer.resume()
                self.connect()
            } catch { self.fail(HerdrFailure(.remoteError, error.localizedDescription)) }
        }
    }

    public func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            delivery.cancel()
            timer?.cancel(); timer = nil
            command?.cancel(); command = nil
            if ownsControl { closeMaster(controlPath) }
        }
    }

    public func setCompletionDuration(_ duration: TimeInterval) {
        queue.async { self.reducer.doneVisible = duration }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func connect() {
        guard !stopped else { return }
        retryAfter = nil; polling = false
        reducer.reconnecting()
        status.state = once ? .testing : .connecting
        status.message = ""; status.retryAt = nil
        publish()
        run(HerdrCommands.discovery(override: configuration.herdrPath)) { [weak self] result in
            guard let self else { return }
            if let failure = self.processFailure(result) { self.fail(failure); return }
            do {
                let discovery = try HerdrCommands.parseDiscovery(result.output)
                self.status.platform = discovery.platform
                if !self.configuration.herdrPath.isEmpty { self.candidates = [self.configuration.herdrPath] }
                else {
                    self.candidates = discovery.paths
                    if !self.rediscovered, let cached = self.status.path ?? self.configuration.resolvedHerdrPath {
                        self.candidates.removeAll { $0 == cached }
                        self.candidates.insert(cached, at: 0)
                    }
                }
                self.candidateFailure = nil
                self.probeNext()
            } catch { self.fail(self.asFailure(error)) }
        }
    }

    private func probeNext() {
        guard !stopped else { return }
        guard !candidates.isEmpty else {
            fail(candidateFailure ?? HerdrFailure(.notInstalled, "Install Herdr on the remote or provide its absolute executable path."))
            return
        }
        let path = candidates.removeFirst()
        do {
            let script = try HerdrCommands.agentList(path: path, remote: configuration, polling: false)
            run(script) { [weak self] result in
                guard let self else { return }
                if let failure = result.failure { self.fail(failure); return }
                if result.status == 255 { self.fail(HerdrCommands.transportFailure(code: result.status, diagnostics: result.diagnostics)); return }
                if let record = self.compatibleRecord(result.output) {
                    self.status.path = path
                    self.accept(record)
                    if self.once { self.finishProbe() }
                    else { self.startPolling(path: path) }
                } else {
                    let detail = String(decoding: result.output.suffix(1000), as: UTF8.self)
                    let state: HerdrConnectionState = self.configuration.herdrPath.isEmpty
                        ? (result.status == 127 ? .notInstalled : .incompatibleResponse) : .invalidPath
                    let failure = HerdrFailure(state, "\(path) did not return a compatible Herdr agent list. \(detail)")
                    self.log(failure.message)
                    self.candidateFailure = failure
                    self.probeNext()
                }
            }
        } catch {
            let failure = asFailure(error)
            log("Skipping invalid Herdr candidate: \(failure.message)")
            candidateFailure = failure
            probeNext()
        }
    }

    private func compatibleRecord(_ data: Data) -> HerdrRecord? {
        for line in data.split(separator: 10) {
            do { return try HerdrRecord.parse(Data(line)) }
            catch { invalidDiagnostic = String(error.localizedDescription.prefix(1000)) }
        }
        return nil
    }

    private func startPolling(path: String) {
        guard !stopped else { return }
        do {
            let script = try HerdrCommands.agentList(path: path, remote: configuration, polling: true)
            polling = true; invalidDiagnostic = nil
            lastValid = now; lastOutput = now
            run(script, stream: true) { [weak self] result in
                guard let self else { return }
                self.polling = false
                if result.status == 127 && self.configuration.herdrPath.isEmpty {
                    self.status.path = nil; self.rediscovered = true
                    self.connect()
                } else if result.status == 127 {
                    self.fail(HerdrFailure(.invalidPath, "The configured Herdr executable is no longer available."))
                } else {
                    self.fail(self.processFailure(result) ?? HerdrFailure(.hostUnavailable, "The remote SSH stream ended."))
                }
            }
        } catch { fail(asFailure(error)) }
    }

    private func run(_ script: String, stream: Bool = false, completion: @escaping (HerdrProcessResult) -> Void) {
        guard !stopped else { return }
        let job = HerdrProcess(queue: queue, log: log, line: stream ? { [weak self] in self?.receive($0) } : nil) { [weak self] result in
            guard let self, !self.stopped else { return }
            self.command = nil
            completion(result)
        }
        command = job
        do {
            try job.start(executable: executable,
                          arguments: HerdrCommands.sshArguments(remote: configuration, controlPath: controlPath, command: script),
                          timeout: stream ? nil : timing.commandTimeout)
        } catch {
            command = nil
            fail(HerdrFailure(.hostUnavailable, "Could not start SSH: \(error.localizedDescription)"))
        }
    }

    private func receive(_ result: Result<Data, HerdrFailure>) {
        guard !stopped else { return }
        lastOutput = now
        do {
            let record = try HerdrRecord.parse(result.get())
            lastValid = now; invalidDiagnostic = nil
            accept(record)
        } catch {
            invalidDiagnostic = String(error.localizedDescription.prefix(1000))
            checkOutputDeadline()
        }
    }

    private func accept(_ record: HerdrRecord) {
        switch record {
        case .failure(let failure):
            status.state = failure.state; status.message = failure.message; status.retryAt = nil
            publish()
        case .agents(let observations):
            expireGrace()
            let date = Date()
            let sessions = reducer.apply(observations, remote: configuration, at: date)
            lastSnapshot = now
            status.state = .connected; status.message = ""; status.retryAt = nil
            status.lastSuccess = date; status.agentCount = observations.count
            if polling { attempt = 0; rediscovered = false }
            publish(sessions: once ? nil : sessions)
        }
    }

    private func tick() {
        guard !stopped else { return }
        expireGrace()
        if polling { checkOutputDeadline() }
        else if command == nil, let retryAfter, now >= retryAfter { connect() }
    }

    private func checkOutputDeadline() {
        guard polling else { return }
        if now - lastValid >= timing.outputTimeout, let invalidDiagnostic {
            fail(HerdrFailure(.incompatibleResponse, "Remote output stopped matching the Herdr protocol. \(invalidDiagnostic)"))
        } else if now - lastOutput >= timing.outputTimeout {
            fail(HerdrFailure(.hostUnavailable, "Herdr stopped sending status updates."))
        }
    }

    private func expireGrace() {
        guard let lastSnapshot, now - lastSnapshot >= timing.grace else { return }
        self.lastSnapshot = nil
        reducer.reconnecting(preservePublished: false)
        publish(sessions: [])
    }

    private func fail(_ failure: HerdrFailure) {
        guard !stopped else { return }
        command?.cancel(); command = nil; polling = false
        status.state = failure.state; status.message = failure.message; status.retryAt = nil
        log("\(configuration.displayName): \(failure.message)")
        if once { finishProbe(); return }
        let rediscover = failure.state == .incompatibleResponse && configuration.herdrPath.isEmpty && !rediscovered
        if failure.state == .hostUnavailable || rediscover {
            if rediscover { rediscovered = true; status.path = nil }
            let delay = timing.retryDelays[min(attempt, timing.retryDelays.count - 1)]
            attempt += 1
            retryAfter = now + delay; status.retryAt = Date().addingTimeInterval(delay)
            if ownsControl {
                let retired = controlPath
                controlPath = retired.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                closeMaster(retired)
            }
        } else { retryAfter = nil }
        publish()
    }

    private func finishProbe() {
        timer?.cancel(); timer = nil
        publish(finished: true)
        if ownsControl { closeMaster(controlPath) }
    }

    private func processFailure(_ result: HerdrProcessResult) -> HerdrFailure? {
        if let failure = result.failure { return failure }
        return result.status == 0 ? nil : HerdrCommands.transportFailure(code: result.status, diagnostics: result.diagnostics)
    }

    private func asFailure(_ error: Error) -> HerdrFailure {
        (error as? HerdrFailure) ?? HerdrFailure(.incompatibleResponse, error.localizedDescription)
    }

    private func publish(sessions: [AgentSession]? = nil, finished: Bool = false) {
        let update = HerdrUpdate(connection: status, sessions: sessions, controlPath: controlPath, finished: finished)
        delivery.post(update)
    }

    private func closeMaster(_ path: URL) {
        guard FileManager.default.fileExists(atPath: path.path), retiredControls.insert(path).inserted else { return }
        HerdrControlConnection.close(remote: configuration, path: path, executable: executable, log: log)
    }
}
