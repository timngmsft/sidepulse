import AppKit
import SidePulseCore
import SwiftUI

@main
enum NativeMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var status: StatusItemController?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let root: URL?
        if let index = args.firstIndex(of: "--state-dir"), args.indices.contains(index + 1) {
            root = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else { root = nil }
        do {
            let paths = NativePaths(root: root)
            let firstLaunch = !FileManager.default.fileExists(atPath: paths.configuration.path)
            let mode: ApplicationMode = args.contains("--copilot-testing") ? .copilotTesting :
                args.contains("--development") ? .preview : .standard
            let testSSH: URL?
            if let index = args.firstIndex(of: "--test-ssh") {
                guard mode == .copilotTesting, let root, args.indices.contains(index + 1) else {
                    throw NativeError("--test-ssh requires --copilot-testing and an isolated --state-dir.")
                }
                let executable = URL(fileURLWithPath: args[index + 1]).resolvingSymlinksInPath()
                guard executable.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                      FileManager.default.isExecutableFile(atPath: executable.path) else {
                    throw NativeError("The test SSH executable must be inside the isolated state directory.")
                }
                testSSH = executable
            } else { testSSH = nil }
            let model = try AppModel(paths: paths, mode: mode, testSSHExecutable: testSSH)
            self.model = model
            configureMenu()
            status = try StatusItemController(model: model)
            model.showSettings = { [weak self] in self?.openSettings() }
            model.showDashboard = { [weak self] in self?.openHistory() }
            model.captureWindow = { [weak self] kind in
                guard let self else { throw NativeError("Application is closing.") }
                return try self.capture(kind: kind)
            }
            try model.start()
            if args.contains("--show-remotes") {
                model.settingsSection = .remotes
                openSettings()
            } else if args.contains("--show-hooks") {
                model.settingsSection = .hooks
                openSettings()
            } else if firstLaunch || args.contains("--show-window") { openWelcome() }
        } catch {
            FileHandle.standardError.write(Data("SidePulse Native startup: \(error.localizedDescription)\n".utf8))
            let alert = NSAlert()
            alert.messageText = "SidePulse Native could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
        status?.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWelcome()
        return false
    }

    private func configureMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let application = NSMenu(title: "SidePulse Native")
        appItem.submenu = application
        application.addItem(withTitle: "About SidePulse Native", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        application.addItem(.separator())
        let settings = application.addItem(withTitle: "Settings...", action: #selector(settingsMenuAction(_:)), keyEquivalent: ",")
        settings.target = self
        application.addItem(.separator())
        application.addItem(withTitle: "Quit SidePulse Native", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
                                      ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        NSApp.mainMenu = menu
    }

    @objc private func settingsMenuAction(_ sender: NSMenuItem) { openSettings() }

    private func window<V: View>(title: String, size: NSSize, root: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentMinSize = size
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.center()
        return window
    }
    private func show(_ window: NSWindow?) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func openWelcome() {
        guard let model else { return }
        if welcomeWindow == nil {
            welcomeWindow = window(title: "SidePulse Native", size: NSSize(width: 420, height: 500), root: DashboardView(model: model))
            welcomeWindow?.styleMask.remove(.resizable)
        }
        show(welcomeWindow)
    }
    private func openSettings() {
        guard let model else { return }
        if settingsWindow == nil {
            settingsWindow = window(title: "SidePulse Native Settings", size: NSSize(width: 690, height: 600), root: SettingsView(model: model))
        }
        show(settingsWindow)
    }
    private func openHistory() {
        guard let model else { return }
        if historyWindow == nil {
            historyWindow = window(title: "SidePulse Native History", size: NSSize(width: 650, height: 440), root: HistoryView(model: model))
        }
        show(historyWindow)
    }

    private func capture(kind: String) throws -> URL {
        guard let model, model.development else { throw NativeError("Window capture is only available in development mode.") }
        let view: NSView?
        switch kind {
        case "capture-settings": model.settingsSection = .general; openSettings(); view = settingsWindow?.contentView?.superview
        case "capture-hooks": model.settingsSection = .hooks; openSettings(); view = settingsWindow?.contentView?.superview
        case "capture-devices": model.settingsSection = .devices; openSettings(); view = settingsWindow?.contentView?.superview
        case "capture-remotes": model.settingsSection = .remotes; openSettings(); view = settingsWindow?.contentView?.superview
        case "capture-history": openHistory(); view = historyWindow?.contentView?.superview
        case "capture-status": view = status?.captureView
        default: openWelcome(); view = welcomeWindow?.contentView?.superview
        }
        guard let view,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NativeError("Could not capture the native window.")
        }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NativeError("Could not encode the native window image.")
        }
        let url = model.paths.root.appendingPathComponent("\(kind).png")
        try data.write(to: url, options: .atomic)
        return url
    }
}
