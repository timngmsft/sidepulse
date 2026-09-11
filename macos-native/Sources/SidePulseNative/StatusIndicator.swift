import AppKit
import Combine
import QuartzCore
import SidePulseCore
import SwiftUI

extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255,
                  green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

extension DisplayState {
    var color: Color { Color(nsColor: NSColor(hex: colorHex)) }
    var symbol: String {
        switch self {
        case .idle: return "circle"
        case .working: return "waveform.path"
        case .ask: return "questionmark.circle.fill"
        case .done: return "checkmark.circle.fill"
        }
    }
}

@MainActor
final class LEDStripView: NSView {
    private let count: Int
    private var lights: [CALayer] = []
    private(set) var state = DisplayState.idle
    private var animationRevision = 0
    private var completion: DispatchWorkItem?

    init(frame: NSRect, count: Int = 4) {
        self.count = count
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<count {
            let light = CALayer()
            light.cornerRadius = 1.5
            light.shadowRadius = 1.5
            light.shadowOpacity = 0.3
            light.shadowOffset = .zero
            layer?.addSublayer(light)
            lights.append(light)
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        let gap: CGFloat = count == 4 ? 3 : 2
        let width = max(2, (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, light) in lights.enumerated() {
            light.frame = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: bounds.height)
        }
        CATransaction.commit()
    }
    func update(state: DisplayState, motion: Bool, transition: Bool) {
        self.state = state
        animationRevision += 1
        completion?.cancel(); completion = nil
        let color = NSColor(hex: state.colorHex).cgColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, light) in lights.enumerated() {
            light.removeAllAnimations()
            light.backgroundColor = color
            light.shadowColor = color
            light.opacity = state == .done ? 0.72 : state == .idle ? 0.35 : 0.8
            guard motion else { continue }
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            switch state {
            case .working:
                light.opacity = 0.28
                animation.values = [1, 0.28, 0.28, 1]
                animation.keyTimes = [0, 0.25, 0.75, 1]
                animation.duration = 1.5
                animation.timeOffset = Double((count - index) % count) * 1.5 / Double(count)
                animation.repeatCount = .infinity
                animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
            case .ask:
                light.opacity = 0.35
                animation.values = [0.35, 1, 0.35]
                animation.keyTimes = [0, 0.5, 1]
                animation.duration = 1.6
                animation.repeatCount = .infinity
            case .done where transition:
                animation.values = [0.72, 1, 0.72]
                animation.keyTimes = [0, 0.5, 1]
                animation.duration = 0.75
            default: continue
            }
            light.add(animation, forKey: "status")
        }
        CATransaction.commit()
        if state == .done && motion && transition {
            let revision = animationRevision
            let finish = DispatchWorkItem { [weak self] in
                guard let self, self.animationRevision == revision else { return }
                self.lights.forEach { $0.removeAllAnimations() }
                self.completion = nil
            }
            completion = finish
            // Hidden or clipped status items may not receive animation-completion callbacks.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: finish)
        }
    }
    var animationCount: Int { lights.filter { !($0.animationKeys()?.isEmpty ?? true) }.count }
    var presentationOpacities: [JSONValue] {
        lights.map { .number(Double($0.presentation()?.opacity ?? -1)) }
    }
}

@MainActor
final class StatusItemController {
    private let model: AppModel
    private let item: NSStatusItem
    private let strip: LEDStripView
    private let popover = NSPopover()
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var state = DisplayState.idle
    private var screensSleeping = false
    private let actionTarget: StatusButtonTarget
    private var screenPanel: NSPanel?
    private var screenStrip: LEDStripView?

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: 89)
        strip = LEDStripView(frame: NSRect(x: 10, y: 7, width: 25, height: 8))
        actionTarget = StatusButtonTarget()
        if let button = item.button {
            button.image = NSImage(size: NSSize(width: 29, height: 18))
            button.imagePosition = .imageLeft
            button.title = " Working"
            button.font = .menuBarFont(ofSize: 0)
            item.length = ceil(button.cell?.cellSize.width ?? 89)
            button.addSubview(strip)
            button.target = actionTarget
            button.action = #selector(StatusButtonTarget.clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        actionTarget.action = { [weak self] in self?.togglePopover() }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 520)
        popover.contentViewController = NSHostingController(rootView: DashboardView(model: model))
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.$snapshot.map(\.state).removeDuplicates().sink { [weak self] state in
            self?.setState(state)
        }.store(in: &subscriptions)
        model.$configuration.map(\.screenBarEnabled).removeDuplicates().sink { [weak self] enabled in
            self?.updateScreenBar(enabled: enabled)
        }.store(in: &subscriptions)
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshMotion() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensSleeping = true; self?.refreshMotion() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensSleeping = false; self?.refreshMotion() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateScreenBar(enabled: self.model.configuration.screenBarEnabled)
            }
        })
        model.renderDiagnostics = { [weak self] in self?.diagnostics ?? [:] }
    }

    private var motion: Bool { !screensSleeping && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private func setState(_ next: DisplayState) {
        let changed = state != next
        state = next
        item.button?.title = " \(state.rawValue)"
        item.button?.toolTip = "SidePulse Native: \(state.rawValue)"
        item.button?.setAccessibilityLabel("SidePulse Native: \(state.rawValue)")
        if let button = item.button, let rectangle = button.cell?.imageRect(forBounds: button.bounds) {
            strip.frame = NSRect(x: rectangle.midX - 12.5, y: rectangle.midY - 4, width: 25, height: 8)
        }
        strip.update(state: state, motion: motion, transition: changed)
        screenStrip?.update(state: state, motion: motion, transition: changed)
    }
    private func refreshMotion() {
        strip.update(state: state, motion: motion, transition: false)
        screenStrip?.update(state: state, motion: motion, transition: false)
        if screensSleeping { screenPanel?.orderOut(nil) }
        else if model.configuration.screenBarEnabled { screenPanel?.orderFrontRegardless() }
    }
    private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            model.refreshHooks()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    private func updateScreenBar(enabled: Bool) {
        screenPanel?.orderOut(nil)
        screenPanel = nil; screenStrip = nil
        guard enabled, let screen = NSScreen.main else { return }
        let width: CGFloat = 220
        let height: CGFloat = 5
        let depth = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - depth - height,
                           width: width, height: height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.level = .statusBar; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = LEDStripView(frame: NSRect(origin: .zero, size: frame.size), count: 8)
        panel.contentView = view
        view.update(state: state, motion: motion, transition: false)
        screenPanel = panel; screenStrip = view
        if !screensSleeping { panel.orderFrontRegardless() }
    }
    var diagnostics: [String: JSONValue] {
        ["label": .string(item.button?.title.trimmingCharacters(in: .whitespaces) ?? ""),
         "width": .number(item.length), "segments": .number(4),
         "animations": .number(Double(strip.animationCount)),
         "presentationOpacities": .array(strip.presentationOpacities),
         "visible": .bool(strip.window?.isVisible == true && !strip.isHiddenOrHasHiddenAncestor),
         "stripWidth": .number(strip.bounds.width), "stripHeight": .number(strip.bounds.height),
         "reduceMotion": .bool(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)]
    }
    var captureView: NSView? { item.button }
    func stop() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        subscriptions.removeAll()
        screenPanel?.orderOut(nil)
        popover.close()
        NSStatusBar.system.removeStatusItem(item)
    }
}

@MainActor
private final class StatusButtonTarget: NSObject {
    var action: (() -> Void)?
    @objc func clicked(_ sender: Any?) { action?() }
}
