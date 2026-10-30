import CoreGraphics

/// Which screen edge the ⌘Tab icon strip hugs. Settings › Canvas › ⌘ Tab.
enum SwitcherEdge: String, CaseIterable {
    case bottom, left, right, top

    var title: String {
        switch self {
        case .bottom: return "Bottom"
        case .left: return "Left"
        case .right: return "Right"
        case .top: return "Top"
        }
    }

    /// Top and bottom strips are rows; left and right ones are columns.
    var isRow: Bool { self == .bottom || self == .top }
}

/// The strip's geometry, apart from any view so it can be tested: where the card goes on the screen,
/// where each icon sits along it, how far the icons scroll when they don't all fit, and where the
/// caption (app name, window title, window chips) goes beside the highlighted icon.
///
/// Coordinates are the overlay's: top-left origin, y down. "Along" is the strip's long axis (x for a
/// row, y for a column), measured inside the card from its leading edge before scrolling.
struct SwitcherStripLayout: Equatable {
    static let icon: CGFloat = 96
    /// How much the highlighted icon grows. The card's padding leaves room for it.
    static let selectedScale: CGFloat = 1.12
    static let spacing: CGFloat = 16
    static let padding: CGFloat = 18
    /// From the edge of the visible screen (below the menu bar, beside the Dock's spot).
    static let margin: CGFloat = 12
    /// Between the card and the caption.
    static let captionGap: CGFloat = 10
    /// How much of each end fades out while the icons scroll.
    static let fade: CGFloat = 28

    let edge: SwitcherEdge
    let count: Int
    /// The visible screen, in overlay coordinates.
    let area: CGRect

    var pitch: CGFloat { Self.icon + Self.spacing }
    var thickness: CGFloat { Self.icon + 2 * Self.padding }

    /// All the icons laid end to end, with the card's padding.
    var contentLength: CGFloat {
        count == 0 ? 0 : 2 * Self.padding + CGFloat(count) * Self.icon + CGFloat(count - 1) * Self.spacing
    }
    var maxLength: CGFloat { max(thickness, (edge.isRow ? area.width : area.height) - 2 * Self.margin) }
    /// More icons than fit: the strip keeps its length and the icons scroll, the highlighted one centred.
    var overflows: Bool { contentLength > maxLength }
    var length: CGFloat { min(contentLength, maxLength) }

    var cardFrame: CGRect {
        let m = Self.margin, t = thickness, l = length
        switch edge {
        case .bottom: return CGRect(x: area.midX - l / 2, y: area.maxY - m - t, width: l, height: t)
        case .top: return CGRect(x: area.midX - l / 2, y: area.minY + m, width: l, height: t)
        case .left: return CGRect(x: area.minX + m, y: area.midY - l / 2, width: t, height: l)
        case .right: return CGRect(x: area.maxX - m - t, y: area.midY - l / 2, width: t, height: l)
        }
    }

    /// The centre of icon `index` along the strip, before scrolling. Fractional indices sit between
    /// icons: the highlight travels through them.
    func center(of index: CGFloat) -> CGFloat {
        Self.padding + Self.icon / 2 + index * pitch
    }

    /// The icon's frame inside the card's content, before scrolling.
    func slot(_ index: Int) -> CGRect {
        let a = center(of: CGFloat(index)) - Self.icon / 2
        return edge.isRow ? CGRect(x: a, y: Self.padding, width: Self.icon, height: Self.icon)
                          : CGRect(x: Self.padding, y: a, width: Self.icon, height: Self.icon)
    }

    /// How far the icons scroll so `index` (fractional while moving) is centred, held at both ends.
    /// Zero whenever everything fits.
    func scroll(centering index: CGFloat) -> CGFloat {
        guard overflows else { return 0 }
        return min(max(0, center(of: index) - length / 2), contentLength - length)
    }

    /// The icon under a point along the card (from its leading edge), the icons scrolled by `scroll`.
    func index(at along: CGFloat, scroll: CGFloat) -> Int? {
        let x = along + scroll - Self.padding + Self.spacing / 2
        guard x >= 0, count > 0 else { return nil }
        let i = Int(x / pitch)
        return i < count ? i : nil
    }

    /// Where the caption goes for an icon centred `along` the visible card: on the side facing the
    /// middle of the screen, centred on the icon, and kept inside the visible screen.
    func captionFrame(size: CGSize, along: CGFloat) -> CGRect {
        let card = cardFrame, g = Self.captionGap, m = Self.margin
        var origin: CGPoint
        switch edge {
        case .bottom: origin = CGPoint(x: card.minX + along - size.width / 2, y: card.minY - g - size.height)
        case .top: origin = CGPoint(x: card.minX + along - size.width / 2, y: card.maxY + g)
        case .left: origin = CGPoint(x: card.maxX + g, y: card.minY + along - size.height / 2)
        case .right: origin = CGPoint(x: card.minX - g - size.width, y: card.minY + along - size.height / 2)
        }
        if edge.isRow {
            origin.x = min(max(origin.x, area.minX + m), area.maxX - m - size.width)
        } else {
            origin.y = min(max(origin.y, area.minY + m), area.maxY - m - size.height)
        }
        return CGRect(origin: origin, size: size)
    }

    /// The minimap's frame moved clear of the card (and its margin), towards the middle of the screen.
    func clearing(_ frame: CGRect) -> CGRect {
        let card = cardFrame.insetBy(dx: -Self.margin, dy: -Self.margin)
        guard count > 0, frame.intersects(card) else { return frame }
        var f = frame
        switch edge {
        case .bottom: f.origin.y = card.minY - f.height
        case .top: f.origin.y = card.maxY
        case .left: f.origin.x = card.maxX
        case .right: f.origin.x = card.minX - f.width
        }
        return f
    }

    /// The window chips shown under an app with many windows: at most `limit`, the selected one among
    /// them, as near the middle as the ends allow.
    static func chipRange(count: Int, selected: Int, limit: Int = 5) -> Range<Int> {
        guard count > limit else { return 0..<count }
        let start = min(max(0, selected - limit / 2), count - limit)
        return start..<(start + limit)
    }
}
