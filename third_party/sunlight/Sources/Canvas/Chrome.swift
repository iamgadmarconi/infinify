import AppKit

/// The look of the canvas's own chrome — the minimap and the hover pill: a
/// dark material, white ink, round symbol buttons. Always dark, whatever the canvas colour.
enum Chrome {
    static let card = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.98)
    static let hairline = NSColor(white: 1, alpha: 0.12)
    static let ink = NSColor(white: 1, alpha: 0.92)
    static let inkSecondary = NSColor(white: 1, alpha: 0.55)
    static let highlight = NSColor(white: 1, alpha: 0.12)
    static let cardRadius: CGFloat = 14

    static func label(_ text: String = "", size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = Chrome.ink, digits: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = digits ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                            : .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    /// Liquid Glass behind a chrome card on macOS 26 and later, in place of the card colour, its hairline
    /// and its shadow: the minimap, the ⌘Tab strip and caption, the preview badge, the canvas toast. The
    /// glass is dark and tinted, so the white ink reads over a bright canvas as over a dark one. Layers
    /// the card draws into itself go above the glass (`zPosition`). On macOS 15 the card stays as it is.
    static func glass(behind card: NSView, radius: CGFloat, layersAbove: [CALayer] = []) {
        guard #available(macOS 26.0, *) else { return }
        let glass = ChromeGlass(frame: card.bounds)
        glass.cornerRadius = radius
        glass.tintColor = NSColor.black.withAlphaComponent(0.5)
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.autoresizingMask = [.width, .height]
        card.addSubview(glass, positioned: .below, relativeTo: nil)
        glass.layer?.zPosition = -1
        for layer in layersAbove { layer.zPosition = 1 }
        card.layer?.backgroundColor = nil
        card.layer?.borderWidth = 0
        card.layer?.shadowOpacity = 0
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }
}

extension Polarity {
    /// A real magnet's colours — a red ⊕ (north), a blue ⊖ (south) — on the window's magnet button,
    /// the pill's polarity button and in the minimap.
    var tint: NSColor {
        switch self {
        case .plus: return NSColor(srgbRed: 0.88, green: 0.20, blue: 0.17, alpha: 1)
        case .minus: return NSColor(srgbRed: 0.16, green: 0.42, blue: 0.90, alpha: 1)
        }
    }
}

/// A round button with an SF Symbol: the hover pill's buttons, as a view. A fill while the pointer
/// is on it, never the keyboard focus.
@MainActor
final class GlyphButton: NSView {
    var action: (() -> Void)?
    private let imageView = NSImageView()
    private var hovered = false {
        didSet { layer?.backgroundColor = hovered ? Chrome.highlight.cgColor : nil }
    }
    private var pressed = false

    init(symbol: String, pointSize: CGFloat, size: CGFloat, action: (() -> Void)? = nil) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = size / 2
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleNone
        imageView.contentTintColor = Chrome.ink
        imageView.image = Chrome.symbol(symbol, size: pointSize)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The whole circle is the button; the image view inside never takes the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        imageView.alphaValue = 0.6
    }

    override func mouseDragged(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        imageView.alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
}

/// The glass behind a chrome card: only a backdrop, so clicks and hovers go to the card itself.
@available(macOS 26.0, *)
private final class ChromeGlass: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
