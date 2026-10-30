import AppKit
import Combine
import SwiftUI

/// Sunlight's menu bar icon (its sun rays), and with no Dock icon the only way into the app. A click
/// opens a small panel under it, Control Center's way (`MenuBarPanelView`): the Sunlight switch, Tidy,
/// Minimap, Layouts and More. A right-click opens More's rows as a plain menu, so Quit is one
/// right-click away. The panel never activates Sunlight: whatever app is in front keeps the focus,
/// and a row that opens a window activates the app itself, as the old menu's items did.
@MainActor
final class MenuBarItem: NSObject {
    let model = MenuBarPanelModel()
    /// Called as the panel opens, to pull the current state into the model.
    var onWillOpen: (() -> Void)?
    /// The right-click menu, built by the app delegate from its own validated items.
    var moreMenu: NSMenu?

    private let statusItem: NSStatusItem
    private var panel: MenuBarPanelWindow?
    private var hosting: NSHostingView<MenuBarPanelView>?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var modelObserver: AnyCancellable?
    private var litRays: Int?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = Self.raysGlyph()
            button.toolTip = "Sunlight"
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        modelObserver = model.objectWillChange.sink { [weak self] _ in
            // After the change lands: Layouts unfolding, or More opening, changes the panel's height.
            DispatchQueue.main.async { self?.fit(animated: true) }
        }
    }

    var isOpen: Bool { panel?.isVisible == true }

    // MARK: The icon

    /// Setup progress in the icon: `lit` of the eight rays full, the rest faint. nil once everything
    /// is done: the plain glyph.
    func showSetupProgress(lit: Int?) {
        guard lit != litRays else { return }
        litRays = lit
        statusItem.button?.image = Self.raysGlyph(lit: lit ?? SetupFlow.rays)
        statusItem.button?.toolTip = lit == nil ? "Sunlight" : "Sunlight: setup \(lit!) of \(SetupFlow.rays) rays"
    }

    /// The app icon's sun, pared down for the menu bar: the disc, eight long rays and a short one after
    /// each. A template image, so it follows the bar's light or dark appearance like the system's own
    /// items. `lit` long-and-short pairs are drawn full, the rest faint,
    /// which is how setup progress shows (`showSetupProgress`).
    static func raysGlyph(lit: Int = SetupFlow.rays) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 9 - 3.2, y: 9 - 3.2, width: 6.4, height: 6.4)).fill()
            for i in 0..<16 {
                let path = NSBezierPath()
                path.lineWidth = 1.5
                path.lineCapStyle = .round
                let angle = CGFloat(i) * 22.5 * .pi / 180, end: CGFloat = i.isMultiple(of: 2) ? 7.7 : 5.6
                path.move(to: NSPoint(x: 9 + sin(angle) * 4.9, y: 9 + cos(angle) * 4.9))
                path.line(to: NSPoint(x: 9 + sin(angle) * end, y: 9 + cos(angle) * end))
                (i / 2 < lit ? NSColor.black : NSColor.black.withAlphaComponent(0.3)).setStroke()
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sunlight"
        return image
    }

    // MARK: Opening and closing

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            close()
            showMoreMenu()
            return
        }
        if isOpen { close() } else { open() }
    }

    private func showMoreMenu() {
        guard let menu = moreMenu, let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    func open() {
        guard let button = statusItem.button, let barWindow = button.window else { return }
        onWillOpen?()
        model.screen = .main
        let panel = self.panel ?? makePanel()
        fit(animated: false)
        // Under the icon, right edges aligned, kept on the screen the bar is on.
        let anchor = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = barWindow.screen ?? NSScreen.main
        var x = anchor.maxX - panel.frame.width
        let y = anchor.minY - MenuBarItem.gap - panel.frame.height
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 1
        }
        button.highlight(true)
        watchForDismissal()
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        stopWatching()
        statusItem.button?.highlight(false)
        panel.orderOut(nil)
        panel.alphaValue = 1
        model.screen = .main
    }

    /// Between the bar and the panel, as Control Center hangs.
    private static let gap: CGFloat = 6
    private static let cornerRadius: CGFloat = 26

    private func makePanel() -> MenuBarPanelWindow {
        let hosting = NSHostingView(rootView: MenuBarPanelView(model: model, dismiss: { [weak self] in self?.close() }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.hosting = hosting
        let container = MenuBarItem.glassContainer(holding: hosting, cornerRadius: Self.cornerRadius)
        let panel = MenuBarPanelWindow(content: container)
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if self.model.screen == .more {
                withAnimation(.easeOut(duration: 0.15)) { self.model.screen = .main }
            } else {
                self.close()
            }
        }
        panel.onDismiss = { [weak self] in self?.close() }
        self.panel = panel
        return panel
    }

    /// Liquid Glass on macOS 26 and later; the popover material before it, so the panel looks native
    /// on both. Either way the view holds `content` and rounds its corners. The green button's popover
    /// (`TilePopover`) sits in one too.
    static func glassContainer(holding content: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    /// Sizes the panel to its content, keeping its top edge where it is.
    private func fit(animated: Bool) {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        guard frame != panel.frame else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated, panel.isVisible, !reduce {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: {
                MainActor.assumeIsolated { panel.invalidateShadow() }
            }
        } else {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    /// A click anywhere else closes the panel, as it closes Control Center. Our own events (the canvas,
    /// the icon) come through the local monitor; everyone else's through the global one. A click on the
    /// icon itself is swallowed, or it would open the panel straight back.
    private func watchForDismissal() {
        stopWatching()
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mouse) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window === panel { return event }
            self.close()
            return event.window === self.statusItem.button?.window ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouse) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    private func stopWatching() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }
}

/// The panel's window: borderless, floating, and non-activating, so opening it leaves the app in front
/// where it is. It takes key events all the same (tab between rows, space, esc).
@MainActor
final class MenuBarPanelWindow: NSPanel {
    /// Esc: back from More, or closed.
    var onCancel: (() -> Void)?
    /// A ⌘ shortcut: closed, and the shortcut dropped.
    var onDismiss: (() -> Void)?

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: MenuBarPanelView.width + 24, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// While the panel is open it is the key window, so a ⌘ shortcut typed then would reach Sunlight's
    /// hidden main menu rather than the app in front: ⌘Q quit Sunlight on the first try. Any ⌘ shortcut
    /// closes the panel instead and goes no further, as Control Center closes.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            onDismiss?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // esc, should nothing in the content take it
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}
