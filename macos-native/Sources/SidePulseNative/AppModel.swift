import AppKit
import Combine
import ServiceManagement
import SidePulseCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var configuration: AppConfiguration
    @Published private(set) var snapshot: MonitorSnapshot
    @Published private(set) var devices: [MountedDevice] = []
    @Published private(set) var battery: BatteryState?
    @Published private(set) var history: [HistoryEntry] = []
    @Published var notice: String?
    let remoteStatus = RemoteStatusModel()
    @Published var installedHooks: [Provider: Bool] = [:]
    @Published private(set) var hookFiles: [Provider: URL] = [:]
    @Published private(set) var keepingAwake = false
    @Published var settingsSection = SettingsSection.general
    let paths: NativePaths
    let mode: ApplicationMode
    var development: Bool { mode.restrictsSystemChanges }
    private let store: SessionStore
    private let devicesService = DeviceService()
    private let awake = AwakeService()
    private let ejectGuard = EjectGuard()
    private var server: UnixEventServer?
    private var tickTimer: Timer?
    private var batteryTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var remoteWorkers: [String: HerdrMonitor] = [:]
    private var remoteGenerations: [String: UUID] = [:]
    private var remoteControlPaths: [String: URL] = [:]
    private var remoteAuthentications: [String: HerdrAuthentication] = [:]
    private var retiredAuthentications: [String: HerdrAuthentication] = [:]
    private var remoteTest: HerdrMonitor?
    private var remoteTestToken: UUID?
    private let testSSHExecutable: URL?
    private var sleeping = false
    private var quitting = false
    private var lastHistory = Date.distantPast
    var showSettings: (() -> Void)?
    var showDashboard: (() -> Void)?
    var renderDiagnostics: (() -> [String: JSONValue])?
    var captureWindow: ((String) throws -> URL)?

    init(paths: NativePaths, mode: ApplicationMode, testSSHExecutable: URL? = nil) throws {
        self.paths = paths; self.mode = mode
        self.testSSHExecutable = testSSHExecutable
        try paths.prepare()
        let loaded = try Persistence.load(AppConfiguration.self, from: paths.configuration) ?? AppConfiguration()
        try loaded.validate()
        configuration = loaded
        let sessions = try Persistence.load([AgentSession].self, from: paths.sessions) ?? []
        store = SessionStore(sessions: sessions)
        store.staleAfter = loaded.staleAfterSeconds
        store.doneVisible = loaded.doneVisibleSeconds
        snapshot = store.snapshot()
        history = try Persistence.load([HistoryEntry].self, from: paths.history) ?? []
    }

    var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SidePulseHook") }
    var loginEnabled: Bool { [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) }
    var dashboardEmptyState: DashboardEmptyState? {
        guard snapshot.sessions.isEmpty else { return nil }
        return DashboardEmptyState(mode: mode, installedHooks: installedHooks, hasRemotes: !configuration.remotes.isEmpty)
    }

    func start() throws {
        devicesService.onError = { [weak self] message in self?.report(message) }
        let server = UnixEventServer(socket: paths.socket) { [weak self] message in
            DispatchQueue.main.async { self?.log(message) }
        }
        try server.start { [weak self] data in
            guard let self else { return Data(#"{"ok":false,"error":"App is closing."}"#.utf8) }
            return self.handle(data)
        }
        self.server = server
        if !FileManager.default.fileExists(atPath: paths.configuration.path) {
            try Persistence.save(configuration, to: paths.configuration)
        }
        drainPendingEvents()
        refreshHooks()
        refreshDevices()
        refreshBattery()
        synchronizeRemotes()
        applyServices()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDevices() }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemWake() }
        })
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drainPendingEvents(); self?.checkAuthentications(); self?.refresh() }
        }
        tickTimer?.tolerance = 0.2
        if let tickTimer { RunLoop.main.add(tickTimer, forMode: .common) }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshBattery() }
        }
        batteryTimer?.tolerance = 5
        if let batteryTimer { RunLoop.main.add(batteryTimer, forMode: .common) }
        log("Started standalone native app; socket=\(paths.socket.path)")
        if notice == nil { notice = mode.explanation }
    }

    func stop(completion: (@MainActor () -> Void)? = nil) {
        guard !quitting else { completion?(); return }
        quitting = true
        tickTimer?.invalidate(); batteryTimer?.invalidate()
        server?.stop(); server = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        cancelRemoteTest()
        for id in Array(remoteAuthentications.keys) { cancelAuthentication(id, reconnect: false) }
        remoteGenerations.removeAll()
        for worker in remoteWorkers.values { worker.stop() }
        remoteWorkers.removeAll()
        do {
            try awake.update(shouldHold: false)
            try ejectGuard.setEnabled(false)
            try Persistence.save(store.persistentSessions, to: paths.sessions)
            try Persistence.save(history, to: paths.history)
        } catch { log(error.localizedDescription) }
        devicesService.stop { completion?() }
    }

    @discardableResult
    func update(_ change: (inout AppConfiguration) -> Void) -> Bool {
        var next = configuration
        change(&next)
        do {
            try next.validate()
            try Persistence.save(next, to: paths.configuration)
            let remotesChanged = next.remotes != configuration.remotes
            configuration = next
            store.staleAfter = next.staleAfterSeconds
            store.doneVisible = next.doneVisibleSeconds
            if remotesChanged { synchronizeRemotes() }
            for worker in remoteWorkers.values { worker.setCompletionDuration(next.doneVisibleSeconds) }
            applyServices()
            refresh()
            return true
        } catch { report(error.localizedDescription); return false }
    }

    func setLogin(_ enabled: Bool) {
        guard !development else { report("Login registration is disabled for the isolated development instance."); return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval {
                notice = "Approve SidePulse Native in System Settings > General > Login Items to finish enabling startup."
            }
            objectWillChange.send()
        } catch { report("Login item: \(error.localizedDescription)") }
    }

    func installHooks(_ provider: Provider, removing: Bool = false) {
        guard mode.permitsHookChanges(for: provider) else {
            report(mode.explanation ?? "Hook installation is unavailable in this mode.")
            return
        }
        guard let file = hookFiles[provider] else { report("The hook configuration path is not available."); return }
        let alert = NSAlert()
        alert.messageText = removing ? "Remove native \(provider.title) hooks?" : "Install native \(provider.title) hooks?"
        alert.informativeText = "Configuration: \(file.path)\n\nOnly SidePulse Native entries will be changed. Other hooks are preserved and existing configuration is backed up first. Restart the agent afterward."
        alert.addButton(withTitle: removing ? "Remove" : "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let result = try HookConfiguration.install(provider: provider, home: FileManager.default.homeDirectoryForCurrentUser,
                                                       helper: helper, socket: paths.socket, removing: removing)
            refreshHooks()
            notice = "\(provider.title) hooks \(removing ? "removed" : "installed"). Restart the agent\(provider == .codex ? " and approve the hooks in Codex if prompted" : "")."
            if let backup = result.backup { log("Hook backup: \(backup.path)") }
        } catch { report(error.localizedDescription) }
    }

    func refreshHooks() {
        for provider in Provider.hookProviders where mode != .copilotTesting || provider == .copilot {
            do {
                hookFiles[provider] = try HookConfiguration.file(for: provider, home: FileManager.default.homeDirectoryForCurrentUser)
                installedHooks[provider] = try HookConfiguration.isInstalled(provider: provider, home: FileManager.default.homeDirectoryForCurrentUser)
            } catch {
                installedHooks[provider] = nil
                report("Could not check \(provider.title) hooks: \(error.localizedDescription)")
            }
        }
    }

    func forget(_ session: AgentSession) {
        store.remove(id: session.id)
        persistSessions()
        refresh()
    }

    func clearSessions() {
        store.clear()
        persistSessions()
        refresh()
    }

    func preview(_ state: DisplayState) {
        guard mode.permitsSimulation else { report("Simulated states are only available in preview mode."); return }
        if state == .idle { clearSessions(); return }
        do {
            let event = try EventNormalizer.normalize(HookEnvelope(provider: .codex, line: .object([
                "hook_event_name": .string("Stop"), "session_id": .string("native-preview"),
                "session_title": .string("Native UI preview"), "sidepulse_status": .string(state.rawValue),
                "last_assistant_message": .string(state == .ask ? "Which environment should I use?" : "Preview activity.")
            ])))
            store.clear()
            store.ingest(event)
            persistSessions()
            refresh()
        } catch { report(error.localizedDescription) }
    }

    func openSession(_ session: AgentSession) {
        guard session.remoteID == nil else { report("Remote sessions are managed by Herdr on their remote machine."); return }
        if let cwd = session.cwd {
            NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
        } else { report("This agent did not provide a workspace path.") }
    }

    func openTerminal(_ session: AgentSession) {
        guard session.remoteID == nil, let cwd = session.cwd else {
            report("No local workspace is available for this session."); return
        }
        openCommand("cd \(HookConfiguration.shellQuote(cwd))\nexec \"$SHELL\" -l", name: "workspace")
    }

    func authenticate(_ remote: RemoteConfiguration) {
        guard mode.permitsRemotes, !sleeping, remote.enabled,
              configuration.remotes.contains(where: { $0.id == remote.id && $0.sameEndpoint(as: remote) }) else {
            report("Enable and save the remote before authenticating."); return
        }
        cancelAuthentication(remote.id, reconnect: false)
        retireRemote(remote.id)
        do {
            let attempt = try HerdrAuthentication(remote: remote, root: paths.root,
                                                  controlPath: HerdrCommands.controlPath(root: paths.root, remote: remote),
                                                  executable: testSSHExecutable ?? URL(fileURLWithPath: "/usr/bin/ssh"))
            remoteAuthentications[remote.id] = attempt
            remoteStatus[remote.id] = HerdrConnectionStatus(.authenticating, message: "Credentials and host-key prompts stay in Terminal.")
            NSWorkspace.shared.open([attempt.command],
                                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                guard let error else { return }
                Task { @MainActor in
                    guard let self, self.remoteAuthentications[remote.id]?.token == attempt.token else { return }
                    self.cancelAuthentication(remote.id, reconnect: false)
                    self.remoteStatus[remote.id] = HerdrConnectionStatus(.remoteError, message: error.localizedDescription)
                    self.report("Could not open SSH authentication: \(error.localizedDescription)")
                }
            }
        } catch {
            remoteStatus[remote.id] = HerdrConnectionStatus(.remoteError, message: error.localizedDescription)
            report(error.localizedDescription)
        }
    }

    func retryRemote(_ remote: RemoteConfiguration) {
        cancelAuthentication(remote.id, reconnect: false)
        retireRemote(remote.id)
        synchronizeRemotes()
    }

    func testRemote(_ draft: RemoteConfiguration, completion: @escaping (HerdrConnectionStatus, Bool) -> Void) {
        cancelRemoteTest()
        guard mode.permitsRemotes, !sleeping else {
            completion(HerdrConnectionStatus(.disabled, message: "Remote connections are unavailable in this mode."), true); return
        }
        let remote = draft.normalized()
        do { try remote.validate() }
        catch { completion(HerdrConnectionStatus(.remoteError, message: error.localizedDescription), true); return }
        let saved = configuration.remotes.first { $0.id == remote.id && $0.sameEndpoint(as: remote) }
        let existing = saved.flatMap { remoteControlPaths[$0.id] }
        let control = existing ?? HerdrCommands.controlPath(root: paths.root, remote: remote)
        let token = UUID()
        remoteTestToken = token
        let worker = HerdrMonitor(configuration: remote, controlPath: control, once: true, ownsControl: existing == nil,
                                  executable: testSSHExecutable ?? URL(fileURLWithPath: "/usr/bin/ssh"),
                                  log: remoteLogger) { [weak self] update in
            guard let self, self.remoteTestToken == token, !self.quitting else { return }
            completion(update.connection, update.finished)
            if update.finished { self.cancelRemoteTest() }
        }
        remoteTest = worker
        worker.start()
    }

    func cancelRemoteTest() {
        remoteTestToken = nil
        remoteTest?.stop(); remoteTest = nil
    }

    func cancelAuthentication(_ id: String, reconnect: Bool = true) {
        guard let attempt = remoteAuthentications.removeValue(forKey: id) else { return }
        do { try attempt.cancel() }
        catch { report("Could not cancel SSH authentication: \(error.localizedDescription)") }
        closeAuthenticationControl(attempt)
        retiredAuthentications[attempt.token] = attempt
        if reconnect {
            notice = "Authentication cancelled. The Terminal window can be closed."
            synchronizeRemotes()
        }
    }

    func exportHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SidePulse-Native-history.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Persistence.save(history, to: url) }
        catch { report(error.localizedDescription) }
    }

    func revealState() { NSWorkspace.shared.open(paths.root) }

    private func openCommand(_ contents: String, name: String) {
        do {
            let file = paths.root.appendingPathComponent("\(name).command")
            try Data(("#!/bin/sh\nset -e\n" + contents + "\n").utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: configuration) { [weak self] _, error in
                if let error { Task { @MainActor in self?.report(error.localizedDescription) } }
            }
        } catch { report(error.localizedDescription) }
    }

    private func handle(_ data: Data) -> Data {
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            if let action = value["action"]?.string {
                switch action {
                case "ping":
                    return try JSONEncoder().encode(JSONValue.object(["ok": .bool(true), "app": .string("SidePulse Native")]))
                case "snapshot":
                    let encoded = try JSONCoding.encoder().encode(store.snapshot())
                    var object = try JSONDecoder().decode(JSONValue.self, from: encoded).object ?? [:]
                    object["ui"] = .object(renderDiagnostics?() ?? [:])
                    object["mode"] = .string(mode.rawValue)
                    object["dashboardEmptyState"] = dashboardEmptyState.map { .string($0.rawValue) } ?? .null
                    object["installedHooks"] = .object(Dictionary(uniqueKeysWithValues: Provider.hookProviders.map {
                        ($0.rawValue, installedHooks[$0].map(JSONValue.bool) ?? .null)
                    }))
                    object["hookChangesAllowed"] = .object(Dictionary(uniqueKeysWithValues: Provider.allCases.map {
                        ($0.rawValue, .bool(mode.permitsHookChanges(for: $0)))
                    }))
                    object["systemChangesAllowed"] = .bool(!mode.restrictsSystemChanges)
                    object["remotesAllowed"] = .bool(mode.permitsRemotes)
                    object["remotes"] = try JSONDecoder().decode(JSONValue.self, from: JSONCoding.encoder().encode(remoteStatus.values))
                    object["hardware"] = .object([
                        "enabled": .bool(configuration.physicalLEDsEnabled),
                        "allowed": .bool(!development),
                        "devices": .array(devices.map { device in
                            let preference = configuration.devices[device.id] ?? DevicePreference()
                            return .object([
                                "name": .string(device.name), "path": .string(device.root.path),
                                "ledCount": .number(Double(device.count)), "enabled": .bool(preference.enabled),
                                "display": .string(preference.display.rawValue), "brightness": .number(preference.brightness)
                            ])
                        }),
                        "output": .object(devicesService.diagnostics)
                    ])
                    object["ok"] = .bool(true)
                    return try JSONEncoder().encode(JSONValue.object(object))
                case "clear" where development:
                    clearSessions()
                case "set-menu-alignment" where mode.permitsSimulation:
                    guard let raw = value["alignment"]?.string, let alignment = MenuBarAlignment(rawValue: raw) else {
                        throw NativeError("Menu bar alignment must be Left, Center, or Right.")
                    }
                    guard update({ $0.menuBarAlignment = alignment }) else { throw NativeError("Could not save menu bar alignment.") }
                case "set-menu-text" where mode.permitsSimulation:
                    guard let enabled = value["enabled"]?.bool else {
                        throw NativeError("Status text visibility requires a boolean enabled field.")
                    }
                    guard update({ $0.menuBarTextEnabled = enabled }) else { throw NativeError("Could not save status text visibility.") }
                case "set-test-remotes" where testSSHExecutable != nil:
                    guard let remotes = value["remotes"] else { throw NativeError("Missing test remotes.") }
                    let decoded = try JSONDecoder().decode([RemoteConfiguration].self, from: JSONEncoder().encode(remotes))
                    guard update({ $0.remotes = decoded }) else { throw NativeError("Could not save test remotes.") }
                case "test-sleep" where testSSHExecutable != nil:
                    systemSleep()
                case "test-wake" where testSSHExecutable != nil:
                    systemWake()
                case _ where development && ["capture", "capture-settings", "capture-history", "capture-status",
                                               "capture-hooks", "capture-devices", "capture-remotes"].contains(action):
                    guard let captureWindow else { throw NativeError("Window capture is not available.") }
                    let file = try captureWindow(action)
                    return try JSONEncoder().encode(JSONValue.object(["ok": .bool(true), "path": .string(file.path)]))
                case "show-settings" where development:
                    showSettings?()
                case "quit" where development:
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                default: throw NativeError("Unsupported native request.")
                }
            } else {
                let envelope = try JSONDecoder().decode(HookEnvelope.self, from: data)
                let event = try EventNormalizer.normalize(envelope)
                if store.ingest(event) { persistSessions(); refresh() }
            }
            return Data(#"{"ok":true}"#.utf8)
        } catch {
            log("Event rejected: \(error.localizedDescription)")
            return (try? JSONEncoder().encode(JSONValue.object(["ok": .bool(false), "error": .string(error.localizedDescription)])))
                ?? Data(#"{"ok":false,"error":"Could not encode error."}"#.utf8)
        }
    }

    private func persistSessions() {
        do { try Persistence.save(store.persistentSessions, to: paths.sessions) }
        catch { report("Could not save agent state: \(error.localizedDescription)") }
    }

    private func drainPendingEvents() {
        guard !quitting, !sleeping else { return }
        do {
            let files = try PendingEvents.files(socket: paths.socket)
            guard !files.isEmpty else { return }
            var accepted: [URL] = []
            for file in files {
                do {
                    let envelope = try JSONDecoder().decode(HookEnvelope.self, from: Data(contentsOf: file))
                    store.ingest(try EventNormalizer.normalize(envelope))
                    accepted.append(file)
                } catch {
                    try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("rejected"))
                    report("An offline hook event was rejected: \(error.localizedDescription)")
                }
            }
            try Persistence.save(store.persistentSessions, to: paths.sessions)
            for file in accepted { try FileManager.default.removeItem(at: file) }
            refresh()
        } catch { report("Offline event queue: \(error.localizedDescription)") }
    }

    private func refresh() {
        guard !quitting, !sleeping else { return }
        let next = store.snapshot()
        if !next.hasSamePresentation(as: snapshot) { snapshot = next; applyServices() }
        if history.last?.state != next.state || Date().timeIntervalSince(lastHistory) >= 60 {
            lastHistory = Date()
            history.append(HistoryEntry(date: lastHistory, state: next.state, activeCount: next.activeCount, batteryPercent: battery?.percent))
            history = Array(history.suffix(1440))
            do { try Persistence.save(history, to: paths.history) }
            catch { report("Could not save history: \(error.localizedDescription)") }
        }
    }

    private func refreshDevices() {
        devices = devicesService.discover()
        applyServices(forceDeviceRefresh: true)
    }

    private func refreshBattery() {
        let next = BatteryState.read()
        if battery != next { battery = next; applyServices() }
    }

    private func applyServices(forceDeviceRefresh: Bool = false) {
        let working = store.snapshot().sessions.contains {
            $0.mode.isWorking
            && (configuration.awakePolicy != .local || $0.remoteID == nil)
        }
        let requested = configuration.awakePolicy == .always ||
            (configuration.awakePolicy != .never && working)
        let lowBattery = battery.map { !$0.plugged && $0.percent < configuration.minimumBatteryPercent } ?? false
        do {
            try awake.update(shouldHold: requested && !lowBattery && !sleeping && !development)
            if keepingAwake != awake.isHolding { keepingAwake = awake.isHolding }
            let protected = devices.filter { $0.name.lowercased().filter(\.isLetter).contains("sidepulsepro") }
            try ejectGuard.setEnabled(configuration.ejectPreventionEnabled && !development, volumes: protected.map(\.root))
        } catch { report(error.localizedDescription) }
        applyDevicePrograms(force: forceDeviceRefresh)
    }

    private func applyDevicePrograms(force: Bool = false) {
        guard !quitting else { return }
        var programs: [String: String] = [:]
        if configuration.physicalLEDsEnabled && !development {
            for device in devices {
                let preferences = configuration.devices[device.id] ?? DevicePreference()
                guard preferences.enabled else { continue }
                if sleeping { programs[device.id] = "off"; continue }
                switch preferences.display {
                case .agent:
                    programs[device.id] = LEDProgram.status(snapshot.state, count: device.count, brightness: preferences.brightness)
                case .battery:
                    if let battery {
                        programs[device.id] = LEDProgram.battery(percent: battery.percent, charging: battery.charging,
                                                                count: device.count, brightness: preferences.brightness)
                    }
                case .custom: programs[device.id] = preferences.customProgram
                }
            }
        }
        devicesService.apply(devices: devices, programs: programs, force: force, keepAlive: !sleeping)
    }

    private var remoteLogger: (String) -> Void {
        { [weak self] message in DispatchQueue.main.async { self?.log(message) } }
    }

    private func synchronizeRemotes() {
        for id in Array(remoteWorkers.keys) {
            let saved = configuration.remotes.first { $0.id == id }
            let matches = saved.map { $0.enabled && remoteWorkers[id]?.configuration.sameEndpoint(as: $0) == true } ?? false
            if !mode.permitsRemotes || sleeping || !matches { retireRemote(id) }
        }
        for (id, attempt) in remoteAuthentications {
            if !configuration.remotes.contains(where: { $0.id == id && $0.enabled && $0.sameEndpoint(as: attempt.remote) }) {
                cancelAuthentication(id, reconnect: false)
            }
        }
        remoteStatus.retain(Set(configuration.remotes.map(\.id)))
        for remote in configuration.remotes {
            if !remote.enabled || !mode.permitsRemotes { remoteStatus[remote.id] = HerdrConnectionStatus(.disabled) }
            else if sleeping { remoteStatus[remote.id] = HerdrConnectionStatus(.paused) }
            else if remoteWorkers[remote.id] == nil && remoteAuthentications[remote.id] == nil { startRemote(remote) }
        }
        refresh()
    }

    private func startRemote(_ remote: RemoteConfiguration, controlPath: URL? = nil) {
        let token = UUID()
        remoteGenerations[remote.id] = token
        let control = controlPath ?? HerdrCommands.controlPath(root: paths.root, remote: remote)
        remoteControlPaths[remote.id] = control
        remoteStatus[remote.id] = HerdrConnectionStatus(.connecting)
        let worker = HerdrMonitor(configuration: remote, controlPath: control,
                                  executable: testSSHExecutable ?? URL(fileURLWithPath: "/usr/bin/ssh"),
                                  log: remoteLogger) { [weak self] update in
            guard let self, !self.quitting, self.remoteGenerations[remote.id] == token else { return }
            if self.remoteStatus[remote.id] != update.connection { self.remoteStatus[remote.id] = update.connection }
            self.remoteControlPaths[remote.id] = update.controlPath
            if let path = update.connection.path,
               let index = self.configuration.remotes.firstIndex(where: { $0.id == remote.id }),
               self.configuration.remotes[index].resolvedHerdrPath != path {
                var next = self.configuration
                next.remotes[index].resolvedHerdrPath = path
                do {
                    try Persistence.save(next, to: self.paths.configuration)
                    self.configuration = next
                } catch { self.report("Could not save detected Herdr path: \(error.localizedDescription)") }
            }
            if let sessions = update.sessions {
                self.store.reconcile(remoteID: remote.id, sessions: sessions)
                self.refresh()
            }
        }
        remoteWorkers[remote.id] = worker
        worker.setCompletionDuration(configuration.doneVisibleSeconds)
        worker.start()
    }

    private func retireRemote(_ id: String) {
        remoteGenerations.removeValue(forKey: id)
        remoteControlPaths.removeValue(forKey: id)
        remoteWorkers.removeValue(forKey: id)?.stop()
        store.reconcile(remoteID: id, sessions: [])
    }

    private func checkAuthentications() {
        for (id, attempt) in remoteAuthentications {
            do {
                guard ProcessInfo.processInfo.systemUptime - attempt.startedAt < 660 else {
                    throw NativeError("SSH authentication timed out.")
                }
                if let code = try attempt.exitStatus() {
                    guard code == 0 else {
                        cancelAuthentication(id, reconnect: false)
                        remoteStatus[id] = HerdrConnectionStatus(.authenticationRequired, message: "SSH authentication exited with status \(code). See Terminal for details.")
                        continue
                    }
                    guard let saved = configuration.remotes.first(where: {
                        $0.id == id && $0.enabled && $0.sameEndpoint(as: attempt.remote)
                    }), !sleeping, !quitting else {
                        cancelAuthentication(id, reconnect: false); continue
                    }
                    if !FileManager.default.fileExists(atPath: attempt.accepted.path) {
                        if !FileManager.default.fileExists(atPath: attempt.acknowledgement.path) {
                            try attempt.acknowledge()
                        } else if FileManager.default.fileExists(atPath: attempt.finished.path) {
                            throw NativeError("The SSH connection was not accepted in time. Authenticate again.")
                        }
                        continue
                    }
                    remoteAuthentications.removeValue(forKey: id)
                    retiredAuthentications[attempt.token] = attempt
                    startRemote(saved, controlPath: attempt.controlPath)
                } else if ProcessInfo.processInfo.systemUptime - attempt.startedAt >= 600 {
                    cancelAuthentication(id, reconnect: false)
                    remoteStatus[id] = HerdrConnectionStatus(.authenticationRequired, message: "SSH authentication timed out.")
                }
            } catch {
                cancelAuthentication(id, reconnect: false)
                remoteStatus[id] = HerdrConnectionStatus(.remoteError, message: error.localizedDescription)
                report(error.localizedDescription)
            }
        }
        for (token, attempt) in retiredAuthentications where FileManager.default.fileExists(atPath: attempt.finished.path) {
            do {
                if FileManager.default.fileExists(atPath: attempt.cancellation.path) { closeAuthenticationControl(attempt) }
                try attempt.removeFiles()
                retiredAuthentications.removeValue(forKey: token)
            } catch { report("Could not remove SSH authentication files: \(error.localizedDescription)") }
        }
    }

    private func closeAuthenticationControl(_ attempt: HerdrAuthentication) {
        HerdrControlConnection.close(remote: attempt.remote, path: attempt.controlPath,
                                     executable: testSSHExecutable ?? URL(fileURLWithPath: "/usr/bin/ssh"), log: remoteLogger)
    }

    private func systemSleep() {
        sleeping = true
        cancelRemoteTest()
        for id in Array(remoteAuthentications.keys) { cancelAuthentication(id, reconnect: false) }
        synchronizeRemotes()
        applyServices()
    }
    private func systemWake() {
        sleeping = false
        synchronizeRemotes()
        refreshBattery(); refreshDevices(); refresh()
    }

    func report(_ message: String) { notice = message; log(message) }
    private func log(_ message: String) {
        let clean = message.replacingOccurrences(of: "\n", with: " ")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(clean)\n"
        do {
            if !FileManager.default.fileExists(atPath: paths.log.path) {
                try Data().write(to: paths.log)
            }
            let handle = try FileHandle(forWritingTo: paths.log)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            if size > 512_000 { try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0) }
            try handle.write(contentsOf: Data(line.utf8))
        } catch { FileHandle.standardError.write(Data("SidePulse Native log error: \(error)\n".utf8)) }
    }
}
