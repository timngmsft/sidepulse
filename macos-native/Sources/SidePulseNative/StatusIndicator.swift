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

private enum MenuBarLEDLayout {
    static let count = 5
    static let segmentWidth: CGFloat = 4
    static let gap: CGFloat = 3
    static let height: CGFloat = 8
    static let edgePadding: CGFloat = 2
    static let width = CGFloat(count) * segmentWidth + CGFloat(count - 1) * gap
    static let compactWidth = width + edgePadding * 2
    static let imageSize = NSSize(width: compactWidth, height: 18)
}

@MainActor
final class LEDStripView: NSView {
    private let count: Int
    private let gap: CGFloat
    private var lights: [CALayer] = []
    private(set) var state = DisplayState.idle
    private var animationRevision = 0
    private var completion: DispatchWorkItem?

    init(frame: NSRect, count: Int, gap: CGFloat) {
        self.count = count
        self.gap = gap
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
        needsLayout = true
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
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
    var segmentCount: Int { lights.count }
    var segmentFrames: [JSONValue] {
        lights.map {
            .object(["x": .number($0.frame.minX), "y": .number($0.frame.minY),
                     "width": .number($0.frame.width), "height": .number($0.frame.height)])
        }
    }
    var presentationOpacities: [JSONValue] {
        lights.map { .number(Double($0.presentation()?.opacity ?? -1)) }
    }
}

@MainActor
final class StatusItemController {
    private let model: AppModel
    private let item: NSStatusItem
    private let strip: LEDStripView
    private let drawingCell: NSButtonCell
    private let labeledWidth: CGFloat
    private var alignment: MenuBarAlignment
    private var textEnabled: Bool
    private var contentFrame = NSRect.zero
    private var titleFrame = NSRect.zero
    private var imageFrame = NSRect.zero
    private let popover = NSPopover()
    private var subscriptions: Set<AnyCancellable> = []
    private var modelUpdates = 0
    private var observers: [NSObjectProtocol] = []
    private var state = DisplayState.idle
    private var screensSleeping = false
    private let actionTarget: StatusButtonTarget
    private var screenPanel: NSPanel?
    private var screenStrip: LEDStripView?

    init(model: AppModel) throws {
        self.model = model
        alignment = model.configuration.menuBarAlignment
        textEnabled = model.configuration.menuBarTextEnabled
        let item = NSStatusBar.system.statusItem(withLength: MenuBarLEDLayout.compactWidth)
        guard let button = item.button, let cell = button.cell as? NSButtonCell else {
            NSStatusBar.system.removeStatusItem(item)
            throw NativeError("Could not create the native menu bar button.")
        }
        button.image = NSImage(size: MenuBarLEDLayout.imageSize)
        button.imagePosition = .imageLeft
        button.title = " Working"
        button.font = .menuBarFont(ofSize: 0)
        labeledWidth = ceil(cell.cellSize.width)
        item.length = textEnabled ? labeledWidth : MenuBarLEDLayout.compactWidth
        guard let drawingCell = cell.copy() as? NSButtonCell else {
            NSStatusBar.system.removeStatusItem(item)
            throw NativeError("Could not prepare the native menu bar text renderer.")
        }
        self.item = item
        self.drawingCell = drawingCell
        strip = LEDStripView(frame: NSRect(x: 0, y: 0, width: MenuBarLEDLayout.width, height: MenuBarLEDLayout.height),
                             count: MenuBarLEDLayout.count, gap: MenuBarLEDLayout.gap)
        actionTarget = StatusButtonTarget()
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.addSubview(strip)
        button.target = actionTarget
        button.action = #selector(StatusButtonTarget.clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        actionTarget.action = { [weak self] in self?.togglePopover() }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 520)
        popover.contentViewController = NSHostingController(rootView: DashboardView(model: model))
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.objectWillChange.sink { [weak self] _ in
            self?.modelUpdates += 1
        }.store(in: &subscriptions)
        model.$snapshot.map(\.state).removeDuplicates().sink { [weak self] state in
            self?.setState(state)
        }.store(in: &subscriptions)
        model.$configuration.map(\.screenBarEnabled).removeDuplicates().sink { [weak self] enabled in
            self?.updateScreenBar(enabled: enabled)
        }.store(in: &subscriptions)
        model.$configuration.map(\.menuBarAlignment).removeDuplicates().sink { [weak self] alignment in
            self?.alignment = alignment
            self?.renderContent()
        }.store(in: &subscriptions)
        model.$configuration.map(\.menuBarTextEnabled).removeDuplicates().sink { [weak self] enabled in
            self?.textEnabled = enabled
            self?.renderContent()
        }.store(in: &subscriptions)
        button.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                               object: button, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.renderContent() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification,
                                                               object: button.window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.renderContent() }
        })
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
                self.renderContent()
                self.updateScreenBar(enabled: self.model.configuration.screenBarEnabled)
            }
        })
        model.renderDiagnostics = { [weak self] in self?.diagnostics ?? [:] }
    }

    private var motion: Bool { !screensSleeping && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private func setState(_ next: DisplayState) {
        let changed = state != next
        state = next
        item.button?.toolTip = "SidePulse Native: \(state.rawValue)"
        item.button?.setAccessibilityLabel("SidePulse Native: \(state.rawValue)")
        renderContent()
        strip.update(state: state, motion: motion, transition: changed)
        screenStrip?.update(state: state, motion: motion, transition: changed)
    }
    private func renderContent() {
        guard let button = item.button else { return }
        drawingCell.title = textEnabled ? " \(state.rawValue)" : ""
        let desiredWidth = textEnabled ? labeledWidth : MenuBarLEDLayout.compactWidth
        if item.length != desiredWidth { item.length = desiredWidth }
        let size = button.bounds.size
        if !textEnabled {
            button.image = nil
            imageFrame = .zero
            titleFrame = .zero
            contentFrame = NSRect(origin: .zero, size: size)
            positionStrip(center: NSPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let width = min(ceil(drawingCell.cellSize.width), size.width)
        let x: CGFloat
        switch alignment {
        case .left: x = 0
        case .center: x = (size.width - width) / 2
        case .right: x = size.width - width
        }
        contentFrame = NSRect(x: x, y: 0, width: width, height: size.height)
        let scale = button.window?.backingScaleFactor ?? 1
        guard let context = CGContext(data: nil, width: Int(ceil(size.width * scale)),
                                      height: Int(ceil(size.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            model.report("Could not allocate the menu bar drawing context.")
            return
        }
        context.scaleBy(x: scale, y: scale)
        if button.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        // Status buttons ignore text alignment. Keep their native font/layout, then let a template image
        // supply the explicit content position and AppKit's normal appearance/highlight tint.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: button.isFlipped)
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            drawingCell.drawInterior(withFrame: contentFrame, in: button)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let bitmap = context.makeImage() else {
            model.report("Could not create the menu bar label image.")
            return
        }
        let image = NSImage(cgImage: bitmap, size: size)
        image.isTemplate = true
        image.accessibilityDescription = state.rawValue
        button.image = image
        guard let canvas = button.cell?.imageRect(forBounds: button.bounds) else {
            model.report("Could not position the menu bar content.")
            return
        }
        imageFrame = canvas
        let rectangle = drawingCell.imageRect(forBounds: contentFrame).offsetBy(dx: canvas.minX, dy: canvas.minY)
        titleFrame = drawingCell.titleRect(forBounds: contentFrame).offsetBy(dx: canvas.minX, dy: canvas.minY)
        positionStrip(center: NSPoint(x: rectangle.midX, y: rectangle.midY))
    }
    private func positionStrip(center: NSPoint) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        strip.frame = NSRect(x: center.x - MenuBarLEDLayout.width / 2, y: center.y - MenuBarLEDLayout.height / 2,
                             width: MenuBarLEDLayout.width, height: MenuBarLEDLayout.height)
        strip.layoutSubtreeIfNeeded()
        CATransaction.commit()
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
        let view = LEDStripView(frame: NSRect(origin: .zero, size: frame.size), count: 8, gap: 2)
        panel.contentView = view
        view.update(state: state, motion: motion, transition: false)
        screenPanel = panel; screenStrip = view
        if !screensSleeping { panel.orderFrontRegardless() }
    }
    var diagnostics: [String: JSONValue] {
        ["label": .string(drawingCell.title.trimmingCharacters(in: .whitespaces)),
         "width": .number(item.length), "segments": .number(Double(strip.segmentCount)),
         "textEnabled": .bool(textEnabled),
         "modelUpdates": .number(Double(modelUpdates)),
         "buttonWidth": .number(Double(item.button?.bounds.width ?? 0)),
         "segmentFrames": .array(strip.segmentFrames),
         "tooltip": .string(item.button?.toolTip ?? ""),
         "accessibilityLabel": .string(item.button?.accessibilityLabel() ?? ""),
         "alignment": .string(alignment.rawValue),
         "contentX": .number(contentFrame.minX), "contentWidth": .number(contentFrame.width),
         "stripX": .number(strip.frame.minX), "titleX": .number(titleFrame.minX),
         "titleWidth": .number(titleFrame.width), "fontSize": .number(Double(drawingCell.font?.pointSize ?? 0)),
         "fontName": .string(drawingCell.font?.fontName ?? ""),
         "imageX": .number(imageFrame.minX), "imageWidth": .number(imageFrame.width),
         "template": .bool(item.button?.image?.isTemplate == true),
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
