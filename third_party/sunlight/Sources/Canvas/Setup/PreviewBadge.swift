import AppKit

/// The card in the canvas's bottom-left corner in preview mode (`Settings.previewMode`), called demo
/// mode to the person: a warning triangle and "Demo mode", a two-column table of demo against the
/// full version, a closing push to switch, and Use Full Version, which leads to Set Up Sunlight's
/// live-windows steps. Out of the way so the canvas is usable as it is, and there for as long as
/// preview mode lasts: no ✕, it goes when live windows load. Faded a little until the pointer is on
/// it. The minimap has the other bottom corner. Chrome's look, like the minimap, so it reads as the
/// canvas's own.
@MainActor
final class PreviewBadge: NSView {
    var onGoLive: (() -> Void)?

    static let margin: CGFloat = 12
    private static let padding: CGFloat = 16
    private static let radius: CGFloat = 14
    private static let warning = NSColor(calibratedRed: 1, green: 0.62, blue: 0.04, alpha: 1)
    private static let glyphSize: CGFloat = 28
    private static let restingAlpha: CGFloat = 0.85
    /// Label, Demo and Full columns, and the gap between them; the card is as wide as they are.
    private static let columns: [CGFloat] = [66, 100, 104]
    private static let gutter: CGFloat = 8
    private static let width = 2 * padding + columns.reduce(0, +) + CGFloat(columns.count - 1) * gutter
    private static let rowInset: CGFloat = 6

    /// Demo against the full version. The stream figures are the capture renderer's own limits
    /// (`maxStreams`, `fps(forLevel:)`, the 1 s stills); the energy one was measured on a Mac on
    /// 2026-10-28, panning and pinching in each mode (Sunlight + WindowServer + replayd energy
    /// impact, about 54 against 45).
    private static let rows: [(label: String, demo: String, full: String)] = [
        ("Windows", "Screen recording API streams", "Your real windows"),
        ("Live video", "Only the 8 largest on screen, at 30 fps", "Every window, full refresh rate"),
        ("All other windows", "Update once a second", "Always live"),
        ("Energy", "About 20% more", "Lower"),
    ]
    private static let outro = "About five minutes, with one restart and part of SIP turned off. **Switch now.**"

    private let glyph = NSImageView()
    private let title = Chrome.label("Demo mode", size: 17, weight: .bold)
    private let headers = [PreviewBadge.cell("Demo", size: 10, weight: .semibold, color: Chrome.inkSecondary),
                           PreviewBadge.cell("Full", size: 10, weight: .semibold, color: Chrome.inkSecondary)]
    /// Per row: label, demo, full.
    private let cells: [[NSTextField]] = PreviewBadge.rows.map { row in
        [PreviewBadge.cell(row.label, size: 11.5, weight: .regular, color: Chrome.inkSecondary),
         PreviewBadge.cell(row.demo, size: 11.5, weight: .regular, color: Chrome.inkSecondary),
         PreviewBadge.cell(row.full, size: 11.5, weight: .semibold, color: Chrome.ink)]
    }
    private let rules: [NSView] = PreviewBadge.rows.map { _ in NSView() }
    private let outro = PreviewBadge.cell("", size: 12, weight: .regular, color: Chrome.inkSecondary)
    private let goLive = PillButton(title: "Use Full Version", height: 28, size: 13)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: PreviewBadge.width, height: 80))
        wantsLayer = true
        layer?.backgroundColor = Chrome.card.cgColor
        layer?.cornerRadius = PreviewBadge.radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = Chrome.hairline.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        alphaValue = PreviewBadge.restingAlpha
        Chrome.glass(behind: self, radius: PreviewBadge.radius)

        glyph.image = Chrome.symbol("exclamationmark.triangle.fill", size: 24, weight: .semibold)
        glyph.contentTintColor = PreviewBadge.warning

        for rule in rules {
            rule.wantsLayer = true
            rule.layer?.backgroundColor = Chrome.hairline.cgColor
        }
        outro.attributedStringValue = PreviewBadge.styled(PreviewBadge.outro, size: 12, alignment: .center)

        goLive.action = { [weak self] in self?.onGoLive?() }
        goLive.setAccessibilityLabel("Set up the full version: live windows")

        for view in [glyph, title] + headers + rules + cells.flatMap({ $0 }) + [outro, goLive] as [NSView] {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Demo mode")
        layOut()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    /// Clicks on the card itself stay here; nothing under it on the canvas is hit.
    override func mouseDown(with event: NSEvent) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { fade(to: 1) }
    override func mouseExited(with event: NSEvent) { fade(to: PreviewBadge.restingAlpha) }

    private func fade(to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = alpha
        }
    }

    /// A wrapping label for the table and the closing line.
    private static func cell(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.isSelectable = false
        field.maximumNumberOfLines = 0
        field.cell?.truncatesLastVisibleLine = false
        return field
    }

    /// Grey, with the parts between ** in bold white.
    private static func styled(_ text: String, size: CGFloat, alignment: NSTextAlignment) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let result = NSMutableAttributedString()
        for (index, part) in text.components(separatedBy: "**").enumerated() {
            let bold = index % 2 == 1
            result.append(NSAttributedString(string: part, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                .foregroundColor: bold ? Chrome.ink : Chrome.inkSecondary,
                .paragraphStyle: paragraph,
            ]))
        }
        return result
    }

    /// The height a label needs at `width`, measured by its own cell, as it'll draw, so a last line
    /// is never cut off.
    private static func height(of field: NSTextField, width: CGFloat) -> CGFloat {
        ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0)
    }

    /// Heading row (glyph, title), the column heads, a row per comparison with a hairline above it, the
    /// closing line and the button, both centred; the card's height follows them.
    private func layOut() {
        let p = PreviewBadge.padding
        let titleSize = title.fittingSize
        let g = PreviewBadge.glyphSize
        let headingHeight = max(g, titleSize.height)
        glyph.frame = CGRect(x: p - 2, y: p + (headingHeight - g) / 2, width: g, height: g)
        title.frame = CGRect(x: glyph.frame.maxX + 8, y: p + (headingHeight - titleSize.height) / 2,
                             width: titleSize.width, height: titleSize.height)

        let widths = PreviewBadge.columns
        var xs: [CGFloat] = []
        var x = p
        for w in widths { xs.append(x); x += w + PreviewBadge.gutter }

        var y = p + headingHeight + 12
        let headHeight = max(headers.map { PreviewBadge.height(of: $0, width: widths[1]) }.max() ?? 0, 0)
        for (i, head) in headers.enumerated() {
            head.frame = CGRect(x: xs[i + 1], y: y, width: widths[i + 1], height: headHeight)
        }
        y += headHeight + 4

        let contentWidth = PreviewBadge.width - 2 * p
        for (row, fields) in cells.enumerated() {
            rules[row].frame = CGRect(x: p, y: y, width: contentWidth, height: 1)
            y += 1 + PreviewBadge.rowInset
            let heights = fields.enumerated().map { PreviewBadge.height(of: $1, width: widths[$0]) }
            for (column, field) in fields.enumerated() {
                field.frame = CGRect(x: xs[column], y: y, width: widths[column], height: heights[column])
            }
            y += (heights.max() ?? 0) + PreviewBadge.rowInset
        }

        let outroHeight = PreviewBadge.height(of: outro, width: contentWidth)
        outro.frame = CGRect(x: p, y: y + 10, width: contentWidth, height: outroHeight)
        goLive.frame.origin = CGPoint(x: ((PreviewBadge.width - goLive.frame.width) / 2).rounded(),
                                      y: outro.frame.maxY + 20)
        setFrameSize(NSSize(width: PreviewBadge.width, height: goLive.frame.maxY + p))
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: PreviewBadge.radius,
                                   cornerHeight: PreviewBadge.radius, transform: nil)
    }

    /// In the bottom-left of `visible` (the screen less the Dock and menu bar, top-left coordinates).
    func frame(in visible: CGRect) -> CGRect {
        CGRect(x: visible.minX + PreviewBadge.margin, y: visible.maxY - PreviewBadge.margin - bounds.height,
               width: bounds.width, height: bounds.height)
    }
}

/// The badge's one button: Sunlight's yellow, dark text, round. On macOS 26 and later the system's
/// prominent glass capsule tinted that yellow; before it, drawn here, with a fill while the pointer is on it.
@MainActor
final class PillButton: NSView {
    var action: (() -> Void)?
    static let yellow = NSColor(calibratedRed: 0.95, green: 0.76, blue: 0, alpha: 1)
    private static let ink = NSColor(calibratedRed: 0.10, green: 0.09, blue: 0, alpha: 1)
    private let label: NSTextField
    private var system: NSButton?
    private var hovered = false {
        didSet {
            guard system == nil else { return }
            layer?.backgroundColor = (hovered ? PillButton.yellow.blended(withFraction: 0.12, of: .white) : PillButton.yellow)?.cgColor
        }
    }

    init(title: String, height: CGFloat = 24, size fontSize: CGFloat = 12) {
        label = Chrome.label(title, size: fontSize, weight: .semibold, color: PillButton.ink)
        if #available(macOS 26.0, *) {
            let button = NSButton(title: title, target: nil, action: nil)
            button.bezelStyle = .glass
            button.borderShape = .capsule
            button.tintProminence = .primary
            button.bezelColor = PillButton.yellow
            button.controlSize = .large
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: PillButton.ink])
            button.sizeToFit()
            super.init(frame: NSRect(origin: .zero, size: button.frame.size))
            button.target = self
            button.action = #selector(pressed)
            button.autoresizingMask = [.width, .height]
            addSubview(button)
            system = button
            setAccessibilityElement(false)
            return
        }
        let size = label.fittingSize
        let inset = height / 2
        super.init(frame: NSRect(x: 0, y: 0, width: size.width + 2 * inset, height: height))
        wantsLayer = true
        layer?.backgroundColor = PillButton.yellow.cgColor
        layer?.cornerRadius = height / 2
        label.frame = NSRect(x: inset, y: (height - size.height) / 2, width: size.width, height: size.height)
        addSubview(label)
        widthAnchor.constraint(equalToConstant: size.width + 2 * inset).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { action?() }

    /// The label goes to the system button when there is one: it's the accessibility element then.
    override func setAccessibilityLabel(_ accessibilityLabel: String?) {
        super.setAccessibilityLabel(accessibilityLabel)
        system?.setAccessibilityLabel(accessibilityLabel)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        guard system == nil else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }
}

/// A line over the canvas that fades after a moment: "This is the real thing", the first time live
/// windows load after a preview. Same card as the badge, centred along the top.
@MainActor
enum CanvasToast {
    private static let margin: CGFloat = 12

    static func show(_ message: String, in overlay: NSView, for seconds: TimeInterval = 4) {
        let label = Chrome.label(message, size: 13, weight: .medium)
        let size = label.fittingSize
        let height: CGFloat = 36
        let width = min(size.width + 32, overlay.bounds.width - 2 * margin)
        let card = NSView(frame: CGRect(x: (overlay.bounds.width - width) / 2, y: margin, width: width, height: height))
        card.wantsLayer = true
        card.layer?.backgroundColor = Chrome.card.cgColor
        card.layer?.cornerRadius = height / 2
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Chrome.hairline.cgColor
        Chrome.glass(behind: card, radius: height / 2)
        label.frame = CGRect(x: 16, y: (height - size.height) / 2, width: width - 32, height: size.height)
        label.alignment = .center
        card.addSubview(label)
        card.alphaValue = 0
        overlay.addSubview(card)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            card.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.6
                    card.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated { card.removeFromSuperview() }
                })
            }
        }
    }
}
