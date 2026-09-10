import AppKit
import DiskArbitration
import IOKit.ps
import IOKit.pwr_mgt
import SidePulseCore

struct BatteryState: Equatable {
    var percent: Double
    var plugged: Bool
    var charging: Bool
    var watts: Int?

    static func read() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Double,
                  let maximum = description[kIOPSMaxCapacityKey] as? Double, maximum > 0 else { continue }
            let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
            return BatteryState(
                percent: max(0, min(100, current / maximum * 100)),
                plugged: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                charging: description[kIOPSIsChargingKey] as? Bool ?? false,
                watts: adapter?["Watts"] as? Int
            )
        }
        return nil
    }
}

@MainActor
final class AwakeService {
    private var assertion: IOPMAssertionID = 0
    var isHolding: Bool { assertion != 0 }

    func update(shouldHold: Bool) throws {
        if shouldHold && assertion == 0 {
            var identifier: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "SidePulse Native agent activity" as CFString, &identifier
            )
            guard result == kIOReturnSuccess else { throw NativeError("macOS could not create a keep-awake assertion (\(result)).") }
            assertion = identifier
        } else if !shouldHold && assertion != 0 {
            let result = IOPMAssertionRelease(assertion)
            guard result == kIOReturnSuccess else { throw NativeError("macOS could not release the keep-awake assertion (\(result)).") }
            assertion = 0
        }
    }
}

struct MountedDevice: Identifiable, Equatable {
    var id: String
    var name: String
    var root: URL
    var count: Int
}

final class DeviceService {
    var onError: (@MainActor (String) -> Void)?
    private lazy var output = LEDOutput { [weak self] id, error in
        Task { @MainActor in self?.onError?("LED output (\(id)): \(error.localizedDescription)") }
    }

    func discover() -> [MountedDevice] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeUUIDStringKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        return volumes.compactMap { url in
            let name = url.lastPathComponent
            let normalized = name.lowercased().filter(\.isLetter)
            guard normalized.contains("sidepulsepro") || normalized.contains("sidepulsedot") ||
                    normalized == "pulsedot" else { return nil }
            let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey])
            return MountedDevice(id: values?.volumeUUIDString ?? url.path, name: name, root: url,
                                 count: normalized.contains("dot") ? 2 : 8)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func apply(devices: [MountedDevice], programs: [String: String], force: Bool = false) {
        var targets: [String: LEDTarget] = [:]
        for device in devices {
            guard let program = programs[device.id] else { continue }
            targets[device.id] = LEDTarget(file: device.root.appendingPathComponent("LEDS.LED"), program: program)
        }
        output.apply(targets, force: force)
    }
}

// Disk Arbitration callbacks are scheduled on the main run loop.
final class EjectGuard {
    private var session: DASession?
    private var enabled = false
    private var protectedDisks: Set<String> = []
    func setEnabled(_ value: Bool, volumes: [URL] = []) throws {
        enabled = value
        if !value {
            if let session { DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) }
            session = nil
            protectedDisks.removeAll()
            return
        }
        guard let created = session ?? DASessionCreate(kCFAllocatorDefault) else { throw NativeError("Disk Arbitration is unavailable.") }
        var disks: Set<String> = []
        for volume in volumes {
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, created, volume as CFURL),
                  let whole = DADiskCopyWholeDisk(disk), let name = DADiskGetBSDName(whole) else {
                throw NativeError("Could not identify the SidePulse Pro disk at \(volume.path).")
            }
            disks.insert(String(cString: name))
        }
        protectedDisks = disks
        guard session == nil else { return }
        let approval: DADiskEjectApprovalCallback = { disk, context in
            guard let context else { return nil }
            let owner = Unmanaged<EjectGuard>.fromOpaque(context).takeUnretainedValue()
            guard owner.enabled,
                  let whole = DADiskCopyWholeDisk(disk), let name = DADiskGetBSDName(whole),
                  owner.protectedDisks.contains(String(cString: name)) else { return nil }
            let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted),
                                               "SidePulse Native is keeping this SidePulse Pro attached." as CFString)
            return Unmanaged.passRetained(dissenter)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskUnmountApprovalCallback(created, nil, approval, context)
        DARegisterDiskEjectApprovalCallback(created, nil, approval, context)
        DASessionScheduleWithRunLoop(created, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        session = created
    }
}

final class RemoteWorker {
    let configuration: RemoteConfiguration
    let controlPath: URL
    private let queue: DispatchQueue
    private var process: Process?
    private var pipe: Pipe?
    private var timer: DispatchSourceTimer?
    private var buffer = Data()
    private var diagnostics = ""
    private var lastMessage = Date()
    private var retryAt = Date()
    private var stopped = true
    private let reducer = HerdrReducer()
    private let update: ([AgentSession]?, String?) -> Void

    init(configuration: RemoteConfiguration, controlPath: URL,
         update: @escaping ([AgentSession]?, String?) -> Void) {
        self.configuration = configuration; self.controlPath = controlPath
        self.update = update
        queue = DispatchQueue(label: "io.sidepulse.native.remote.\(configuration.id)", qos: .utility)
    }

    func start() {
        queue.async {
            self.stopped = false
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 2)
            timer.setEventHandler { [weak self] in
                guard let self, !self.stopped else { return }
                if self.process == nil && Date() >= self.retryAt { self.connect() }
                else if self.process != nil && Date().timeIntervalSince(self.lastMessage) > 12 {
                    self.fail("Remote did not send a status update; reconnecting.")
                }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            timer?.cancel(); timer = nil
            pipe?.fileHandleForReading.readabilityHandler = nil
            if let process, process.isRunning { process.terminate() }
            process = nil; pipe = nil
        }
        closeControlConnection()
    }

    private func connect() {
        do {
            let command = try HerdrReducer.command(for: configuration)
            let child = Process()
            let pipe = Pipe()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            child.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                               "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                               "-o", "ControlMaster=auto", "-o", "ControlPersist=no",
                               "-S", controlPath.path, "--", configuration.target, command]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = pipe; child.standardError = pipe
            buffer.removeAll(); diagnostics = ""; lastMessage = Date()
            reducer.reconnecting()
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                self?.queue.async { self?.consume(data, from: child) }
            }
            child.terminationHandler = { [weak self] process in
                self?.queue.async {
                    guard let self, self.process === process else { return }
                    self.fail(self.diagnostics.isEmpty ? "SSH connection ended." : self.diagnostics)
                }
            }
            self.pipe = pipe; self.process = child
            try child.run()
            report(nil, "Connecting")
        } catch { fail(error.localizedDescription) }
    }

    private func consume(_ data: Data, from child: Process) {
        guard process === child, !stopped else { return }
        if data.isEmpty { pipe?.fileHandleForReading.readabilityHandler = nil; return }
        guard buffer.count + data.count <= NativeIPC.requestLimit else { fail("Remote response exceeded 1 MiB."); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let text = String(data: line, encoding: .utf8) else { fail("Remote sent invalid UTF-8."); return }
            if !text.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
                diagnostics = String((diagnostics + "\n" + text).suffix(1500))
                continue
            }
            do {
                let sessions = try reducer.apply(line, remote: configuration)
                lastMessage = Date()
                report(sessions, nil)
            } catch {
                lastMessage = Date()
                report(nil, error.localizedDescription)
            }
        }
    }

    private func fail(_ message: String) {
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; pipe = nil; buffer.removeAll()
        retryAt = Date().addingTimeInterval(10)
        report(nil, String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500)))
    }
    private func report(_ sessions: [AgentSession]?, _ error: String?) {
        DispatchQueue.main.async { self.update(sessions, error) }
    }
    private func closeControlConnection() {
        guard FileManager.default.fileExists(atPath: controlPath.path) else { return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        child.arguments = ["-S", controlPath.path, "-O", "exit", "--", configuration.target]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        do { try child.run() }
        catch { report(nil, "Could not close SSH connection: \(error.localizedDescription)") }
    }
}
