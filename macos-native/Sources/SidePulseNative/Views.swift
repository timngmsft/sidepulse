import AppKit
import SidePulseCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.snapshot.state.symbol)
                    .font(.system(size: 25, weight: .medium)).foregroundStyle(model.snapshot.state.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SidePulse Native").font(.headline)
                    Text(model.snapshot.state == .ask ? "An agent needs your attention" :
                         model.snapshot.state == .working ? "\(model.snapshot.activeCount) active agent\(model.snapshot.activeCount == 1 ? "" : "s")" :
                         model.snapshot.state == .done ? "Latest work completed" : "Ready for agent activity")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.keepingAwake { Image(systemName: "cup.and.saucer.fill").help("Keeping this Mac awake") }
            }.padding(18)
            Divider()
            if let notice = model.notice {
                HStack(alignment: .top) {
                    Image(systemName: "info.circle")
                    Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(12).background(Color.accentColor.opacity(0.08))
            }
            if model.mode.permitsSimulation {
                HStack(spacing: 8) {
                    Text("Preview").font(.caption).foregroundStyle(.secondary)
                    ForEach(DisplayState.allCases, id: \.self) { state in
                        Button(state.rawValue) { model.preview(state) }.buttonStyle(.bordered)
                    }
                }.padding(12)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.snapshot.sessions.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform.path").font(.system(size: 35)).foregroundStyle(.secondary)
                            Text("Your agents, at a glance").font(.headline)
                            Text(model.mode == .copilotTesting
                                 ? "Install GitHub Copilot hooks in Settings, then start a new Copilot CLI session."
                                 : "Install native hooks in Settings to receive activity from Codex, Claude, GitHub Copilot, and Grok.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Set Up Agent Hooks") {
                                model.settingsSection = .hooks
                                model.showSettings?()
                            }.buttonStyle(.borderedProminent)
                        }.frame(maxWidth: .infinity).padding(.vertical, 28)
                    } else {
                        ForEach(model.snapshot.listSections) { section in
                            HStack {
                                Text(section.title.uppercased())
                                Spacer()
                                Text("\(section.sessions.count)")
                            }.font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.top, 4)
                            ForEach(section.sessions) { session in
                                SessionRow(model: model, session: session)
                            }
                        }
                    }
                    if model.mode.permitsRemotes && !model.configuration.remotes.isEmpty {
                        Text("REMOTES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                        ForEach(model.configuration.remotes) { remote in
                            HStack {
                                Image(systemName: "network")
                                VStack(alignment: .leading) {
                                    Text(remote.displayName).font(.caption.weight(.medium))
                                    Text(model.remoteStatus[remote.id]?.summary ?? "Disabled")
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                            }
                        }
                    }
                }.padding(14)
            }.frame(minHeight: 180, maxHeight: 400)
            Divider()
            HStack(spacing: 8) {
                if let battery = model.battery {
                    Image(systemName: battery.charging ? "battery.100percent.bolt" : "battery.75percent")
                    Text("\(Int(battery.percent))%").monospacedDigit()
                }
                Spacer()
                Text(model.configuration.physicalLEDsEnabled && !model.development ? "\(model.devices.count) device\(model.devices.count == 1 ? "" : "s")" : "Hardware output off")
                    .foregroundStyle(.secondary)
            }.font(.caption).padding(.horizontal, 16).padding(.vertical, 10)
            HStack {
                Button("Settings...") { model.showSettings?() }
                Button("History") { model.showDashboard?() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }.buttonStyle(.borderless).font(.callout).padding(14)
        }.frame(width: 420).background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SessionRow: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    var mode: AgentMode {
        session.effectiveMode(at: Date(), staleAfter: model.configuration.staleAfterSeconds,
                              doneVisible: model.configuration.doneVisibleSeconds)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if mode.display == .done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                } else {
                    Circle().frame(width: 8, height: 8)
                }
            }.foregroundStyle(mode.display.color).frame(width: 12, height: 12).padding(.top, 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.callout.weight(.semibold)).lineLimit(1)
                    .help(session.cwd ?? session.title)
                HStack {
                    Text(session.providerTitle)
                    if let remoteID = session.remoteID,
                       let remote = model.configuration.remotes.first(where: { $0.id == remoteID }) {
                        Image(systemName: "network")
                        Text("\(remote.displayName) via Herdr").lineLimit(1)
                    }
                    Text("· \(session.statusLabel)")
                }.font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    if let reference = session.referenceLabel {
                        Text(reference).font(.system(.caption2, design: .monospaced))
                        Text("·")
                    }
                    Text(session.updatedAt, style: .time)
                }.font(.caption2).foregroundStyle(.secondary)
                    .help("Last activity: \(session.updatedAt.formatted())\n\(session.id)")
                if let message = session.message, mode.display == .ask {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
            }
            Spacer(minLength: 2)
            Menu {
                if session.remoteID == nil {
                    Button("Open Workspace") { model.openSession(session) }
                    Button("Open Terminal Here") { model.openTerminal(session) }
                    Button("Dismiss Session") { model.forget(session) }
                } else {
                    Button("Remote Settings...") {
                        model.settingsSection = .remotes
                        model.showSettings?()
                    }
                }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
        }.padding(11).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("session-\(session.id)")
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", hooks = "Agent Hooks", devices = "Devices", remotes = "Remotes", history = "History"
    var id: String { rawValue }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if let explanation = model.mode.explanation {
                Label(explanation, systemImage: "shield")
                    .font(.caption).padding(12).frame(maxWidth: .infinity).background(.orange.opacity(0.1))
            }
            Picker("Settings", selection: $model.settingsSection) {
                ForEach(SettingsSection.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(12)
            Group {
                switch model.settingsSection {
                case .general: general
                case .hooks: hooks
                case .devices: devices
                case .remotes: RemotesView(model: model).disabled(!model.mode.permitsRemotes)
                case .history: HistoryView(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let notice = model.notice {
                HStack {
                    Text(notice).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.notice = nil }
                }.padding(12).background(.quaternary.opacity(0.3))
            }
        }.frame(minWidth: 640, minHeight: 530).background(Color(nsColor: .windowBackgroundColor))
    }

    private func binding<T>(_ key: WritableKeyPath<AppConfiguration, T>) -> Binding<T> {
        Binding(get: { model.configuration[keyPath: key] }, set: { value in model.update { $0[keyPath: key] = value } })
    }

    private var general: some View {
        Form {
            Section("Application") {
                Toggle("Start at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                    .disabled(model.development)
                Toggle("Show agent status below the menu bar / notch", isOn: binding(\.screenBarEnabled))
                Text("Animations respect macOS Reduce Motion and pause when displays sleep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Power") {
                Picker("Keep Mac awake", selection: binding(\.awakePolicy)) {
                    ForEach(AwakePolicy.allCases) { Text($0.rawValue).tag($0) }
                }.disabled(model.development)
                HStack {
                    Text("Stop below \(Int(model.configuration.minimumBatteryPercent))% battery")
                    Slider(value: binding(\.minimumBatteryPercent), in: 5...50, step: 5)
                }
                Text("Uses a process-scoped macOS idle-sleep assertion. It does not change global power settings or override closed-lid sleep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Activity") {
                Picker("Forget stale activity after", selection: binding(\.staleAfterSeconds)) {
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                    Text("1 hour").tag(3600.0)
                }
                Picker("Show completion for", selection: binding(\.doneVisibleSeconds)) {
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("20 minutes").tag(1200.0)
                }
                HStack {
                    Button("Open Native Data Folder") { model.revealState() }
                    Button("Clear Sessions") { model.clearSessions() }
                }
            }
        }.formStyle(.grouped)
    }

    private var hooks: some View {
        Form {
            Section {
                Text("Agent hooks call a small bundled native executable. Neither Python nor the existing sidepulse command is used.")
                ForEach(Provider.hookProviders) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.title).font(.headline)
                            Text(model.mode.permitsHookChanges(for: provider)
                                 ? (model.installedHooks[provider] == true ? "Native hooks installed" : "Not installed")
                                 : "Disabled in this mode")
                                .font(.caption).foregroundStyle(.secondary)
                            if provider == .copilot && model.installedHooks[provider] == true {
                                if let latest = model.snapshot.sessions.filter({ $0.provider == .copilot })
                                    .max(by: { $0.observedAt < $1.observedAt }) {
                                    Text("Last event: \(latest.event)").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("Waiting for activity. Start a new Copilot CLI session.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        if model.installedHooks[provider] == true {
                            Button("Remove") { model.installHooks(provider, removing: true) }
                        }
                        Button(model.installedHooks[provider] == true ? "Update" : "Install") { model.installHooks(provider) }
                    }.disabled(!model.mode.permitsHookChanges(for: provider))
                }
                Text("Existing hooks are preserved. Configurations are backed up before changes. Restart the agent after installing; Codex may ask you to approve the new hooks.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.mode.permitsHookChanges(for: .copilot), let file = model.hookFiles[.copilot] {
                    Text("Copilot configuration: \(file.path)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }.formStyle(.grouped)
    }

    private var devices: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Enable physical LED output", isOn: binding(\.physicalLEDsEnabled)).disabled(model.development)
                Text("Leave this off while the original SidePulse app controls the same hardware.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Prevent SidePulse Pro software ejects while this app runs", isOn: binding(\.ejectPreventionEnabled))
                    .disabled(model.development)
                Divider()
                if model.devices.isEmpty {
                    Label("Connect a SidePulse Pro or SidePulse Dot to configure its LEDs.", systemImage: "externaldrive")
                        .foregroundStyle(.secondary).padding(.vertical, 30)
                }
                ForEach(model.devices) { device in DeviceSettingsView(model: model, device: device) }
            }.padding(20)
        }
    }
}

private struct DeviceSettingsView: View {
    @ObservedObject var model: AppModel
    let device: MountedDevice
    @State private var draft = ""
    var preference: DevicePreference { model.configuration.devices[device.id] ?? DevicePreference() }
    private func binding<T>(_ key: WritableKeyPath<DevicePreference, T>) -> Binding<T> {
        Binding(get: { preference[keyPath: key] }, set: { value in
            model.update {
                var preferences = $0.devices[device.id] ?? DevicePreference()
                preferences[keyPath: key] = value
                $0.devices[device.id] = preferences
            }
        })
    }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(device.name, systemImage: "externaldrive.fill").font(.headline)
                    Spacer()
                    Toggle("Enabled", isOn: binding(\.enabled)).labelsHidden()
                }
                Picker("Display", selection: binding(\.display)) {
                    ForEach(DeviceDisplay.allCases) { Text($0.rawValue).tag($0) }
                }
                HStack {
                    Text("Brightness")
                    Slider(value: binding(\.brightness), in: 0...1)
                    Text("\(Int(preference.brightness * 100))%").monospacedDigit().frame(width: 40)
                }
                if preference.display == .custom {
                    TextEditor(text: $draft).font(.system(.body, design: .monospaced)).frame(height: 100)
                        .onAppear { draft = preference.customProgram }
                    Button("Apply LED Program") {
                        do {
                            let program = LEDProgram.normalize(draft)
                            try LEDProgram.validate(program)
                            binding(\.customProgram).wrappedValue = program
                        } catch { model.report(error.localizedDescription) }
                    }
                    Text("LEDS.LED format: at most 512 UTF-8 bytes and 20 lines.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8)
        }
    }
}

struct RemotesView: View {
    @ObservedObject var model: AppModel
    @State private var editing: RemoteConfiguration?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Herdr remotes").font(.title2.weight(.semibold))
            Text("Monitor Herdr agents on a Mac or Linux host using your existing SSH configuration. Herdr must be installed and running there; no Python or remote SidePulse installation is needed.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.configuration.remotes) { remote in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(remote.displayName).font(.headline)
                                    Spacer()
                                    Button("Edit") { editing = remote }
                                    Button("Remove") { model.update { $0.remotes.removeAll { $0.id == remote.id } } }
                                }
                                Text(remote.target + (remote.normalizedSession.isEmpty ? "" : " / \(remote.normalizedSession)"))
                                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                RemoteConnectionDetail(connection: model.remoteStatus[remote.id] ?? HerdrConnectionStatus(.disabled))
                                HStack {
                                    if model.remoteStatus[remote.id]?.state == .authenticating {
                                        Button("Cancel Authentication") { model.cancelAuthentication(remote.id) }
                                    } else {
                                        Button("Authenticate in Terminal") { model.authenticate(remote) }.disabled(!remote.enabled)
                                        Button("Reconnect") { model.retryRemote(remote) }.disabled(!remote.enabled)
                                    }
                                    Spacer()
                                    Button(remote.enabled ? "Disable" : "Enable") {
                                        model.update { config in
                                            if let index = config.remotes.firstIndex(where: { $0.id == remote.id }) {
                                                config.remotes[index].enabled.toggle()
                                            }
                                        }
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                    }
                    if model.configuration.remotes.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "network").font(.system(size: 30)).foregroundStyle(.secondary)
                            Text("Keep remote work in the same status bar").font(.headline)
                            Text("Add an SSH alias or user@host, then test the connection before saving.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 35)
                    }
                }
            }
            HStack {
                Button("Add Remote") { editing = RemoteConfiguration() }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("add-herdr-remote")
                Spacer()
                Text("Working / Ask / Done match local agents.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).sheet(item: $editing) { remote in
            RemoteEditor(model: model, remote: remote) { result in
                model.update { config in
                    if let index = config.remotes.firstIndex(where: { $0.id == result.id }) { config.remotes[index] = result }
                    else { config.remotes.append(result) }
                }
            }
        }
    }
}

private struct RemoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State var remote: RemoteConfiguration
    @State private var error: String?
    @State private var testStatus: HerdrConnectionStatus?
    @State private var testing = false
    let save: (RemoteConfiguration) -> Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Herdr Remote").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $remote.name)
                TextField("SSH target", text: $remote.target, prompt: Text("user@host or SSH alias"))
                TextField("Herdr session", text: $remote.session, prompt: Text("Default session"))
                TextField("Herdr executable", text: $remote.herdrPath, prompt: Text("Auto-discover"))
                Toggle("Enabled", isOn: $remote.enabled)
            }
            Text("Leave the session blank for Herdr's default. Leave the executable blank to discover a compatible installation automatically.")
                .font(.caption).foregroundStyle(.secondary)
            if let testStatus {
                RemoteConnectionDetail(connection: testStatus)
                if testStatus.state == .authenticationRequired {
                    Text("Save this remote, then use Authenticate in Terminal to handle credentials or host-key confirmation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if testing {
                    Button("Cancel Test") {
                        model.cancelRemoteTest()
                        testing = false; testStatus = nil
                    }
                } else {
                    Button("Test Connection") {
                        error = nil; testing = true
                        model.testRemote(remote) { status, finished in
                            testStatus = status; testing = !finished
                        }
                    }.disabled(remote.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        var result = remote.normalized()
                        try result.validate()
                        let existing = model.configuration.remotes.first { $0.id == result.id }
                        if existing?.sameEndpoint(as: result) != true { result.resolvedHerdrPath = nil }
                        if let path = testStatus?.path { result.resolvedHerdrPath = path }
                        if save(result) { dismiss() }
                        else { error = model.notice ?? "Could not save the remote." }
                    }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520)
            .onChange(of: remote) { _ in
                model.cancelRemoteTest()
                testing = false; testStatus = nil; error = nil
            }
            .onDisappear { model.cancelRemoteTest() }
    }
}

private struct RemoteConnectionDetail: View {
    let connection: HerdrConnectionStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                if connection.state.isBusy { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: connection.state == .connected ? "checkmark.circle.fill" :
                            connection.state.isError ? "exclamationmark.triangle.fill" : "circle")
                        .foregroundStyle(connection.state == .connected ? Color.green :
                                            connection.state.isError ? Color.orange : Color.secondary)
                }
                Text(connection.summary).font(.callout.weight(.medium))
            }
            if !connection.message.isEmpty {
                Text(connection.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let path = connection.path {
                Text("Herdr: \(path)").font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 5) {
                if let platform = connection.platform { Text(platform == "Darwin" ? "macOS" : platform) }
                if let date = connection.lastSuccess {
                    if connection.platform != nil { Text("·") }
                    Text("Last update")
                    Text(date, style: .relative).help(date.formatted())
                }
                if let retry = connection.retryAt {
                    Text("· Retry")
                    Text(retry, style: .relative)
                }
            }.font(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("herdr-connection-\(connection.state.rawValue)")
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var hours = 6
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Activity history").font(.title2.weight(.semibold))
                Spacer()
                Picker("Range", selection: $hours) {
                    Text("1 hour").tag(1); Text("6 hours").tag(6); Text("24 hours").tag(24)
                }.frame(width: 120).labelsHidden()
            }
            Text("State changes and one-minute samples are kept locally, separately from the original SidePulse app.")
                .font(.callout).foregroundStyle(.secondary)
            Canvas { context, size in
                let end = Date()
                let start = end.addingTimeInterval(-Double(hours) * 3600)
                let entries = model.history.filter { $0.date >= start }
                for (index, entry) in entries.enumerated() {
                    let next = index + 1 < entries.count ? entries[index + 1].date : end
                    let x = entry.date.timeIntervalSince(start) / (Double(hours) * 3600) * size.width
                    let width = max(1, next.timeIntervalSince(entry.date) / (Double(hours) * 3600) * size.width)
                    let rectangle = CGRect(x: x, y: 12, width: width, height: 42)
                    context.fill(Path(rectangle), with: .color(entry.state.color))
                }
            }.frame(height: 70).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                ForEach(DisplayState.allCases, id: \.self) { state in
                    Label { Text(state.rawValue).font(.caption) } icon: { Circle().fill(state.color).frame(width: 7, height: 7) }
                }
                Spacer()
            }
            List(Array(model.history.suffix(60).reversed())) { entry in
                HStack {
                    Circle().fill(entry.state.color).frame(width: 8, height: 8)
                    Text(entry.state.rawValue)
                    Spacer()
                    Text(entry.date, style: .time).foregroundStyle(.secondary)
                    if let battery = entry.batteryPercent { Text("\(Int(battery))%").monospacedDigit().foregroundStyle(.secondary) }
                }
            }
            HStack {
                Button("Export History...") { model.exportHistory() }
                Button("Open Data Folder") { model.revealState() }
                Spacer()
            }
        }.padding(18)
    }
}
