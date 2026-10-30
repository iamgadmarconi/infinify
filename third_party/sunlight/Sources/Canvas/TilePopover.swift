import AppKit
import SwiftUI

/// The popover a window's green button offers when the pointer rests on it or it's held down, as
/// macOS's own: Move & Resize (halves, quarters, thirds) and Fill & Arrange (fill, centre, and this
/// window sharing its area with the ones used before it), then Full Screen. It closes once the pointer
/// has been off both the button and the popover for a moment, on a choice, on a click elsewhere, or Esc.
///
/// Its own panel rather than an `NSPopover`: a non-activating one at pop-up-menu level, so it shows
/// over the canvas and the real windows whether or not Sunlight is the active app (an `NSPopover` from
/// the canvas didn't appear on hover).
@MainActor
final class TilePopover: NSObject {
    enum Choice: Equatable {
        case tile(Tiling.Preset)
        case share(Tiling.Share)
        case fullScreen
    }

    /// How long the pointer rests on the green button before the popover comes, and how long a press
    /// is held: macOS's feel.
    static let hoverDelay: TimeInterval = 0.4
    static let holdDelay: TimeInterval = 0.3
    /// Off both the button and the popover this long, it closes.
    static let leaveDelay: TimeInterval = 0.35

    private var panel: TilePanel?
    private(set) weak var proxy: WindowProxy?
    /// The green button, in screen points (bottom-left origin), with a little room round it.
    private var buttonOnScreen: CGRect = .null
    private var watch: Timer?
    private var awaySince: Date?
    private var monitors: [Any] = []
    private weak var previousKey: NSWindow?

    var isShown: Bool { panel?.isVisible == true }

    /// `rect` is the green button in `view`'s coordinates. `others`: how many other windows there are
    /// to share the area with; the layouts that need more are dimmed.
    func show(for proxy: WindowProxy, relativeTo rect: CGRect, of view: NSView, others: Int,
              choose: @escaping (WindowProxy, Choice) -> Void) {
        if isShown, self.proxy === proxy { return }
        close()
        guard let window = view.window else { return }
        self.proxy = proxy
        buttonOnScreen = window.convertToScreen(view.convert(rect, to: nil)).insetBy(dx: -4, dy: -4)

        let content = TilePopoverView(others: others) { [weak self, weak proxy] choice in
            self?.close()
            if let proxy { choose(proxy, choice) }
        }
        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // Liquid Glass on macOS 26 and later, the popover material before it: the menu bar panel's.
        let container = MenuBarItem.glassContainer(holding: hosting, cornerRadius: 12)
        container.frame = CGRect(origin: .zero, size: size)

        // Under the button, its left edge a little before the button's, kept on the screen.
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var origin = CGPoint(x: buttonOnScreen.minX - 12, y: buttonOnScreen.minY - 4 - size.height)
        origin.x = min(max(origin.x, screen.minX + 6), screen.maxX - size.width - 6)
        if origin.y < screen.minY + 6 { origin.y = buttonOnScreen.maxY + 4 }   // no room below: above

        let panel = TilePanel(contentRect: CGRect(origin: origin, size: size),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = container
        panel.onCancel = { [weak self] in self?.close() }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        previousKey = NSApp.keyWindow
        panel.makeKey()   // hover and Esc in the panel; the canvas gets the keyboard back on close
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        self.panel = panel

        // A click anywhere else closes it, as a popover.
        let outside: (NSEvent) -> Void = { [weak self] event in
            guard let self, let panel = self.panel, event.window !== panel else { return }
            self.close()
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { outside($0); return $0 }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in
            MainActor.assumeIsolated { outside(e) }
        }) {
            monitors.append(m)
        }
        // Off the button and the panel for `leaveDelay`, it goes.
        awaySince = nil
        watch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer() }
        }
    }

    private func checkPointer() {
        guard let panel else { return }
        let p = NSEvent.mouseLocation
        if panel.frame.insetBy(dx: -8, dy: -8).contains(p) || buttonOnScreen.contains(p)
            || bridge(to: panel.frame).contains(p) {
            awaySince = nil
        } else if let since = awaySince {
            if Date().timeIntervalSince(since) >= TilePopover.leaveDelay { close() }
        } else {
            awaySince = Date()
        }
    }

    /// The strip between the button and the panel, so moving from one to the other doesn't close it.
    private func bridge(to frame: CGRect) -> CGRect {
        let b = buttonOnScreen
        let x = min(b.minX, frame.minX), width = max(b.maxX, frame.maxX) - x
        if frame.maxY <= b.minY { return CGRect(x: x, y: frame.maxY, width: width, height: b.minY - frame.maxY) }
        if frame.minY >= b.maxY { return CGRect(x: x, y: b.maxY, width: width, height: frame.minY - b.maxY) }
        return .null
    }

    func close() {
        watch?.invalidate()
        watch = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        if let panel {
            let wasKey = panel.isKeyWindow
            panel.orderOut(nil)
            if wasKey, let previousKey, previousKey.isVisible { previousKey.makeKey() }
        }
        panel = nil
        proxy = nil
    }
}

/// A borderless panel that can still take the keyboard (Esc) and the pointer's hover.
private final class TilePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The popover's content: rows of little screens with the slot lit, as macOS draws them.
struct TilePopoverView: View {
    let others: Int
    let choose: (TilePopover.Choice) -> Void

    /// What the pointer is on, named under the rows (macOS shows only a tooltip, which is slow to come).
    @State private var hovered: String?

    private static let halves: [Tiling.Preset] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]
    private static let quarters: [Tiling.Preset] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    private static let thirds: [Tiling.Preset] = [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds]
    private static let sides: [Tiling.Share] = [.leftRight, .rightLeft]
    private static let stacks: [Tiling.Share] = [.topBottom, .bottomTop, .threeColumns, .quarters]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header("Move & Resize")
            row(Self.halves.map(presetTile))
            row(Self.quarters.map(presetTile))
            row(Self.thirds.map(presetTile))
            header("Fill & Arrange").padding(.top, 4)
            row([presetTile(.full), presetTile(.center)] + Self.sides.map(shareTile))
            row(Self.stacks.map(shareTile))
            // Over a line of its own height, so a long name can't widen the panel.
            Color.clear
                .frame(height: 14)
                .overlay(alignment: .leading) {
                    Text(hovered ?? " ")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            Divider()
            FullScreenRow { choose(.fullScreen) }
        }
        .padding(10)
        .fixedSize()   // as wide as the widest row
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func row(_ tiles: [SlotTile]) -> some View {
        HStack(spacing: 4) {
            ForEach(tiles) { tile in
                SlotButton(tile: tile, hovered: $hovered) { choose(tile.choice) }
            }
        }
    }

    private func presetTile(_ preset: Tiling.Preset) -> SlotTile {
        // Centre keeps the window's size: drawn as a smaller window in the middle.
        let cell = preset.unit ?? CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        return SlotTile(id: preset.rawValue, title: preset.title, cells: [cell], choice: .tile(preset), enabled: true)
    }

    private func shareTile(_ share: Tiling.Share) -> SlotTile {
        SlotTile(id: share.rawValue, title: share.title, cells: share.cells, choice: .share(share),
                 enabled: others >= share.cells.count - 1)
    }
}

/// One choice: a little screen with its cells, this window's lit.
struct SlotTile: Identifiable {
    let id: String
    let title: String
    let cells: [CGRect]
    let choice: TilePopover.Choice
    let enabled: Bool
}

private struct SlotButton: View {
    let tile: SlotTile
    @Binding var hovered: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            SlotIcon(cells: tile.cells, lit: isHovered && tile.enabled)
                .frame(width: 30, height: 20)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered && tile.enabled ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()   // no focus ring on the first choice as the panel opens
        .disabled(!tile.enabled)
        .opacity(tile.enabled ? 1 : 0.35)
        .help(tile.title)
        .accessibilityLabel(tile.title)
        .onHover { inside in
            isHovered = inside
            let label = tile.enabled ? tile.title : "\(tile.title) needs more windows"
            if inside { hovered = label } else if hovered == label { hovered = nil }
        }
    }
}

/// A screen outline with each cell inset: the first (this window) solid, the others (the windows it
/// shares with) faint.
private struct SlotIcon: View {
    let cells: [CGRect]
    let lit: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(lit ? Color.white : Color.primary.opacity(0.55), lineWidth: 1)
                ForEach(Array(cells.enumerated()), id: \.offset) { i, cell in
                    let inner = CGRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4)
                    let r = CGRect(x: inner.minX + cell.minX * inner.width, y: inner.minY + cell.minY * inner.height,
                                   width: cell.width * inner.width, height: cell.height * inner.height).insetBy(dx: 0.75, dy: 0.75)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(lit ? Color.white.opacity(i == 0 ? 1 : 0.45) : Color.primary.opacity(i == 0 ? 0.7 : 0.25))
                        .frame(width: max(1, r.width), height: max(1, r.height))
                        .offset(x: r.minX, y: r.minY)
                }
            }
        }
    }
}

private struct FullScreenRow: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16)
                Text("Full Screen")
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(isHovered ? Color.white : Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(isHovered ? Color.accentColor : Color.clear))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
    }
}
