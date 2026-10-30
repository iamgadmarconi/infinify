import AppKit

/// The ⌘Tab icon strip and its caption, on the overlay while ⌘ is held.
///
/// It never animates on its own. Every move — the highlight sliding to the next icon, the icon growing,
/// the icons scrolling, the caption following, the chip highlight — is `from + (to − from) × progress`,
/// where progress is the camera flight's spring (`CanvasView.onFlightProgress`). The strip and the
/// canvas start from where they are and share one curve, so they land together, overshoot together,
/// and a step taken mid-flight bends both the same way. Only the fade in and out runs on its own clock:
/// there's no camera move to pair it with.
@MainActor
final class SwitcherHUD {
    /// One icon: an app with windows on the canvas.
    struct Entry {
        let name: String
        let icon: NSImage
        /// Its windows' titles, in the cycle's order.
        let windows: [String]
    }

    /// The pointer moved onto an icon (`window` nil) or one of the caption's window chips.
    var onHover: ((_ app: Int, _ window: Int?) -> Void)?
    /// A click on an icon or a chip: go there.
    var onPick: ((_ app: Int, _ window: Int?) -> Void)?

    private let strip = SwitcherStripView()
    private let caption = SwitcherCaptionView()
    private var entries: [Entry] = []
    private var layout: SwitcherStripLayout?
    private(set) var isActive = false

    /// The animated values, and the ends of the current move.
    private struct Pose: Equatable {
        var highlight: CGFloat = 0   // a fractional icon index
        var scroll: CGFloat = 0
        var chip: CGFloat = 0        // a fractional index among the chips shown
    }
    private var pose = Pose()
    private var from = Pose()
    private var to = Pose()
    private var selected = (app: 0, window: 0)
    private var chipStart = 0

    init() {
        strip.onHover = { [weak self] i in self?.onHover?(i, nil) }
        strip.onPick = { [weak self] i in self?.onPick?(i, nil) }
        caption.onHoverChip = { [weak self] c in
            guard let self else { return }
            self.onHover?(self.selected.app, self.chipStart + c)
        }
        caption.onPickChip = { [weak self] c in
            guard let self else { return }
            self.onPick?(self.selected.app, self.chipStart + c)
        }
    }

    /// The strip's geometry while it shows, so the minimap can step aside.
    var activeLayout: SwitcherStripLayout? { isActive ? layout : nil }
    /// How many icons it shows.
    var count: Int { entries.count }

    /// Fades in on `overlay` with `entries`, the given icon highlighted, at rest.
    func show(_ entries: [Entry], app: Int, window: Int, edge: SwitcherEdge, area: CGRect, in overlay: NSView) {
        self.entries = entries
        let layout = SwitcherStripLayout(edge: edge, count: entries.count, area: area)
        self.layout = layout
        isActive = true
        if strip.superview !== overlay {
            overlay.addSubview(strip)
            overlay.addSubview(caption)
        }
        strip.configure(entries.map(\.icon), layout: layout, scale: overlay.window?.backingScaleFactor ?? 2)
        selected = (app, window)
        let range = chipRange(app: app, window: window)
        let rest = target(app: app, window: window, layout: layout)
        pose = rest
        from = rest
        to = rest
        caption.configure(entries.indices.contains(app) ? entries[app] : nil, chips: range, selected: window)
        apply()
        strip.isHidden = false
        caption.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            strip.animator().alphaValue = 1
            caption.animator().alphaValue = 1
        }
    }
    /// A new selection. The move to it plays out over the next flight's progress.
    func select(app: Int, window: Int) {
        guard isActive, let layout, entries.indices.contains(app) else { return }
        let appChanged = app != selected.app
        let oldStart = chipStart
        selected = (app, window)
        let range = chipRange(app: app, window: window)
        let next = target(app: app, window: window, layout: layout)
        from = pose
        if appChanged || range.lowerBound != oldStart {
            // New chips: the chip highlight starts on its chip rather than sliding in from other chips.
            from.chip = next.chip
            caption.configure(entries[app], chips: range, selected: window)
        } else {
            caption.select(window: window)
        }
        to = next
    }

    /// The flight's spring: 0 where the move began, 1 where it ends, a little past 1 at the overshoot.
    func progress(_ t: CGFloat) {
        guard isActive else { return }
        pose = Pose(highlight: from.highlight + (to.highlight - from.highlight) * t,
                    scroll: from.scroll + (to.scroll - from.scroll) * t,
                    chip: from.chip + (to.chip - from.chip) * t)
        if t == 1 { from = to }
        apply()
    }

    func hide() {
        guard isActive else { return }
        isActive = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            strip.animator().alphaValue = 0
            caption.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isActive else { return }
                self.strip.isHidden = true
                self.caption.isHidden = true
            }
        })
    }

    // MARK: -

    private func chipRange(app: Int, window: Int) -> Range<Int> {
        guard entries.indices.contains(app) else { return 0..<0 }
        let n = entries[app].windows.count
        let range = n > 1 ? SwitcherStripLayout.chipRange(count: n, selected: window) : 0..<0
        chipStart = range.lowerBound
        return range
    }

    private func target(app: Int, window: Int, layout: SwitcherStripLayout) -> Pose {
        let i = CGFloat(app)
        return Pose(highlight: i, scroll: layout.scroll(centering: i), chip: CGFloat(window - chipStart))
    }

    private func apply() {
        guard let layout else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.apply(highlight: pose.highlight, scroll: pose.scroll)
        caption.apply(chip: pose.chip)
        let along = layout.center(of: pose.highlight) - pose.scroll
        caption.frame = layout.captionFrame(size: caption.preferredSize, along: along).integral
        CATransaction.commit()
    }
}

// MARK: - The strip

/// The card of icons. Layers only, positioned by hand each frame; no implicit animations.
@MainActor
private final class SwitcherStripView: NSView {
    var onHover: ((Int) -> Void)?
    var onPick: ((Int) -> Void)?

    private let clip = CALayer()       // the card's inside; masks the scrolling icons
    private let content = CALayer()    // scrolled
    private let pill = CALayer()       // behind the highlighted icon
    private var icons: [CALayer] = []
    private var fade: CAGradientLayer?
    private var layout: SwitcherStripLayout?
    private var hovered: Int?
    private var scroll: CGFloat = 0
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        alphaValue = 0
        isHidden = true
        let l = layer!
        l.backgroundColor = Chrome.card.cgColor
        l.cornerRadius = 22
        l.cornerCurve = .continuous
        l.borderWidth = 1
        l.borderColor = Chrome.hairline.cgColor
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.4
        l.shadowRadius = 14
        l.shadowOffset = CGSize(width: 0, height: -3)
        l.masksToBounds = false
        clip.masksToBounds = true
        clip.cornerRadius = 22
        clip.cornerCurve = .continuous
        l.addSublayer(clip)
        clip.addSublayer(content)
        Chrome.glass(behind: self, radius: 22, layersAbove: [clip])
        pill.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
        pill.cornerRadius = 18
        pill.cornerCurve = .continuous
        content.addSublayer(pill)
        for layer in [clip, content, pill] { layer.actions = Self.noActions }
    }

    required init?(coder: NSCoder) { fatalError() }

    static let noActions: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
                                                "frame": NSNull(), "contents": NSNull(), "hidden": NSNull(),
                                                "sublayerTransform": NSNull()]

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    func configure(_ images: [NSImage], layout: SwitcherStripLayout, scale: CGFloat) {
        self.layout = layout
        hovered = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = layout.cardFrame.integral
        clip.frame = bounds
        content.frame = CGRect(origin: .zero, size: layout.edge.isRow
                               ? CGSize(width: layout.contentLength, height: bounds.height)
                               : CGSize(width: bounds.width, height: layout.contentLength))
        icons.forEach { $0.removeFromSuperlayer() }
        icons = images.enumerated().map { i, image in
            let icon = CALayer()
            icon.actions = Self.noActions
            icon.contentsScale = scale
            // Drawn at the size it's shown at the largest, so the grown icon stays sharp.
            icon.contents = image.bitmap(pixels: Int((SwitcherStripLayout.icon * SwitcherStripLayout.selectedScale * scale).rounded(.up)))
            icon.contentsGravity = .resizeAspect
            icon.frame = layout.slot(i)
            content.addSublayer(icon)
            return icon
        }
        let pad: CGFloat = 8
        pill.frame = CGRect(origin: .zero, size: CGSize(width: SwitcherStripLayout.icon + 2 * pad,
                                                        height: SwitcherStripLayout.icon + 2 * pad))
        if layout.overflows {
            let g = fade ?? CAGradientLayer()
            g.actions = Self.noActions
            let f = Double(SwitcherStripLayout.fade / layout.length)
            g.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            g.locations = [0, NSNumber(value: f), NSNumber(value: 1 - f), 1]
            g.startPoint = .zero
            g.endPoint = layout.edge.isRow ? CGPoint(x: 1, y: 0) : CGPoint(x: 0, y: 1)
            g.frame = clip.bounds
            fade = g
            clip.mask = g
        } else {
            clip.mask = nil
        }
        CATransaction.commit()
        updateTracking()
    }

    func apply(highlight: CGFloat, scroll: CGFloat) {
        guard let layout else { return }
        self.scroll = scroll
        let isRow = layout.edge.isRow
        content.frame.origin = isRow ? CGPoint(x: -scroll, y: 0) : CGPoint(x: 0, y: -scroll)
        let c = layout.center(of: highlight)
        let mid = layout.thickness / 2
        pill.position = isRow ? CGPoint(x: c, y: mid) : CGPoint(x: mid, y: c)
        let grow = SwitcherStripLayout.selectedScale - 1
        for (i, icon) in icons.enumerated() {
            let near = max(0, 1 - abs(CGFloat(i) - highlight))
            let s = 1 + grow * near
            icon.transform = CATransform3DMakeScale(s, s, 1)
        }
    }

    private func updateTracking() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func index(at event: NSEvent) -> Int? {
        guard let layout else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        return layout.index(at: layout.edge.isRow ? p.x : p.y, scroll: scroll)
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: event)
        guard i != hovered else { return }
        hovered = i
        if let i { onHover?(i) }
    }

    // Not on entering: the strip appearing under a resting pointer mustn't steal the selection.
    override func mouseEntered(with event: NSEvent) {}
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        if let i = index(at: event) { onPick?(i) }
    }

    /// The overlay lets scrolls and pinches through to the canvas; so does the strip.
    override func scrollWheel(with event: NSEvent) { superview?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { superview?.magnify(with: event) }
}

// MARK: - The caption

/// The app's name and the window's title beside the highlighted icon, and when the app has several
/// windows on the canvas, a row of chips for them (⌘` walks them).
@MainActor
private final class SwitcherCaptionView: NSView {
    var onHoverChip: ((Int) -> Void)?
    var onPickChip: ((Int) -> Void)?

    private static let inset: CGFloat = 12
    private static let maxTextWidth: CGFloat = 380
    private static let chipHeight: CGFloat = 22
    private static let chipSpacing: CGFloat = 6
    private static let chipMaxWidth: CGFloat = 150
    private static let chipFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    private let name = Chrome.label(size: 13, weight: .semibold)
    private let title = Chrome.label(size: 11, color: Chrome.inkSecondary)
    private let chipRow = CALayer()
    private let chipPill = CALayer()
    private var chips: [CALayer] = []
    private var chipFrames: [CGRect] = []
    private var titles: [String] = []
    /// The selected window, as an index into `titles`.
    private var selectedWindow = 0
    private var chipsWidth: CGFloat = 0
    private var size = CGSize(width: 160, height: 44)
    private var hoveredChip: Int?
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        alphaValue = 0
        isHidden = true
        let l = layer!
        l.backgroundColor = Chrome.card.cgColor
        l.cornerRadius = 12
        l.cornerCurve = .continuous
        l.borderWidth = 1
        l.borderColor = Chrome.hairline.cgColor
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.35
        l.shadowRadius = 10
        l.shadowOffset = CGSize(width: 0, height: -2)
        name.alignment = .center
        title.alignment = .center
        addSubview(name)
        addSubview(title)
        chipRow.actions = SwitcherStripView.noActions
        chipPill.actions = SwitcherStripView.noActions
        chipPill.backgroundColor = NSColor(white: 1, alpha: 0.22).cgColor
        chipPill.cornerRadius = Self.chipHeight / 2
        chipRow.addSublayer(chipPill)
        Chrome.glass(behind: self, radius: 12, layersAbove: [chipRow])
        l.addSublayer(chipRow)
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    var preferredSize: CGSize { size }

    /// `chips`: which of the app's windows get a chip (none for an app with one window).
    func configure(_ entry: SwitcherHUD.Entry?, chips range: Range<Int>, selected: Int) {
        name.stringValue = entry?.name ?? ""
        titles = entry?.windows ?? []
        selectedWindow = selected
        hoveredChip = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chips.forEach { $0.removeFromSuperlayer() }
        chips = []
        chipFrames = []
        var x: CGFloat = 0
        let scale = window?.backingScaleFactor ?? 2
        for i in range {
            let text = Self.chipTitle(titles[i], index: i)
            let w = min(Self.chipMaxWidth, ceil((text as NSString).size(withAttributes: [.font: Self.chipFont]).width) + 18)
            let frame = CGRect(x: x, y: 0, width: w, height: Self.chipHeight)
            let chip = CALayer()
            chip.actions = SwitcherStripView.noActions
            chip.borderWidth = 1
            chip.borderColor = Chrome.hairline.cgColor
            chip.cornerRadius = Self.chipHeight / 2
            chip.frame = frame
            // A text layer draws its line from the top of its bounds: give it one line's height, centred.
            let label = CATextLayer()
            label.actions = SwitcherStripView.noActions
            label.string = text
            label.font = Self.chipFont
            label.fontSize = Self.chipFont.pointSize
            label.foregroundColor = Chrome.ink.cgColor
            label.alignmentMode = .center
            label.truncationMode = .end
            label.contentsScale = scale
            let line = ceil(Self.chipFont.ascender - Self.chipFont.descender)
            label.frame = CGRect(x: 8, y: (Self.chipHeight - line) / 2, width: w - 16, height: line)
            chip.addSublayer(label)
            chipRow.addSublayer(chip)
            chips.append(chip)
            chipFrames.append(frame)
            x += w + Self.chipSpacing
        }
        chipsWidth = max(0, x - Self.chipSpacing)
        chipRow.isHidden = chips.isEmpty
        CATransaction.commit()
        layoutText()
    }

    /// Another window of the same app, its chip already showing.
    func select(window: Int) {
        selectedWindow = window
        layoutText()
    }

    /// The chip highlight, at a fractional chip index while it moves.
    func apply(chip: CGFloat) {
        guard !chipFrames.isEmpty else { return }
        let lo = Int(floor(chip)), hi = lo + 1
        let f = chip - CGFloat(lo)
        func frame(_ i: Int) -> CGRect { chipFrames[min(max(0, i), chipFrames.count - 1)] }
        let a = frame(lo), b = frame(hi)
        let t = lo < 0 || lo >= chipFrames.count - 1 ? 0 : f
        // Past either end (the spring's overshoot) it keeps going at the end chip's size.
        var r = CGRect(x: a.minX + (b.minX - a.minX) * t, y: 0,
                       width: a.width + (b.width - a.width) * t, height: Self.chipHeight)
        if chip < 0 { r.origin.x = chipFrames[0].minX + chip * (chipFrames[0].width + Self.chipSpacing) }
        if chip > CGFloat(chipFrames.count - 1) {
            let last = chipFrames[chipFrames.count - 1]
            r = last.offsetBy(dx: (chip - CGFloat(chipFrames.count - 1)) * (last.width + Self.chipSpacing), dy: 0)
        }
        chipPill.frame = r
    }

    // MARK: Layout

    private func layoutText() {
        let t = titles.indices.contains(selectedWindow) ? titles[selectedWindow] : ""
        title.stringValue = t
        title.isHidden = t.isEmpty
        let inset = Self.inset
        let nameW = min(Self.maxTextWidth, ceil(name.intrinsicContentSize.width))
        let titleW = t.isEmpty ? 0 : min(Self.maxTextWidth, ceil(title.intrinsicContentSize.width))
        let width = max(160, max(nameW, titleW, chipsWidth) + 2 * inset)
        var y: CGFloat = 8
        name.frame = CGRect(x: inset, y: y, width: width - 2 * inset, height: 17)
        y += 17
        if !t.isEmpty {
            title.frame = CGRect(x: inset, y: y, width: width - 2 * inset, height: 15)
            y += 15
        }
        if !chips.isEmpty {
            y += 8
            chipRow.frame = CGRect(x: (width - chipsWidth) / 2, y: y, width: chipsWidth, height: Self.chipHeight)
            y += Self.chipHeight
        }
        size = CGSize(width: width, height: y + 9)
    }

    private static func chipTitle(_ title: String, index: Int) -> String {
        title.isEmpty ? "Window \(index + 1)" : title
    }

    // MARK: Pointer

    private func chip(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        let q = CGPoint(x: p.x - chipRow.frame.minX, y: p.y - chipRow.frame.minY)
        return chipFrames.firstIndex { $0.insetBy(dx: -Self.chipSpacing / 2, dy: -4).contains(q) }
    }

    override func mouseMoved(with event: NSEvent) {
        let c = chip(at: event)
        guard c != hoveredChip else { return }
        hoveredChip = c
        if let c { onHoverChip?(c) }
    }

    override func mouseExited(with event: NSEvent) { hoveredChip = nil }

    override func mouseDown(with event: NSEvent) {
        if let c = chip(at: event) { onPickChip?(c) }
    }

    override func scrollWheel(with event: NSEvent) { superview?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { superview?.magnify(with: event) }
}
