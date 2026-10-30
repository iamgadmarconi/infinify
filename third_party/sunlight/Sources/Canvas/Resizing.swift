import CoreGraphics

/// Resizing a window from its edges on the canvas. World coordinates throughout (top-left origin,
/// points), except where a rect is said to be on screen.
enum Resizing {
    /// The edges a press grabbed: one, or two at a corner.
    struct Edges: OptionSet, Hashable {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let top = Edges(rawValue: 1 << 2)
        static let bottom = Edges(rawValue: 1 << 3)
    }

    /// How close to an edge, on screen and inside the window, a press grabs it.
    static let band: CGFloat = 6
    /// Along an edge, this close to a corner grabs the corner: corners are the useful grip.
    static let corner: CGFloat = 16
    /// Below this on-screen size there's no room for an edge to grab apart from the window itself.
    static let minScreenSize = CGSize(width: 60, height: 40)
    /// No smaller than this at 1:1. Apps hold their windows to limits of their own on top.
    static let minSize = CGSize(width: 160, height: 100)

    /// The edges of an on-screen rect a point is on, if any.
    static func edges(at p: CGPoint, in r: CGRect) -> Edges {
        guard r.width >= minScreenSize.width, r.height >= minScreenSize.height, r.contains(p) else { return [] }
        let left = p.x - r.minX, right = r.maxX - p.x, top = p.y - r.minY, bottom = r.maxY - p.y
        var e: Edges = []
        if left < band { e.insert(.left) } else if right < band { e.insert(.right) }
        if top < band { e.insert(.top) } else if bottom < band { e.insert(.bottom) }
        if e == .left || e == .right {
            if top < corner { e.insert(.top) } else if bottom < corner { e.insert(.bottom) }
        } else if e == .top || e == .bottom {
            if left < corner { e.insert(.left) } else if right < corner { e.insert(.right) }
        }
        return e
    }

    /// The corner that stays put while `edges` move, as a unit point in the rect: (0, 0) is top-left.
    static func anchor(for edges: Edges) -> CGPoint {
        CGPoint(x: edges.contains(.left) ? 1 : 0, y: edges.contains(.top) ? 1 : 0)
    }

    /// `start` with the grabbed edges moved by a world-space delta, never below `minSize`: an edge
    /// pushed past that stops, and the opposite one never moves.
    static func resize(_ start: CGRect, edges: Edges, by delta: CGVector, minSize: CGSize = minSize) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if edges.contains(.left) { minX = min(start.maxX - minSize.width, start.minX + delta.dx) }
        if edges.contains(.right) { maxX = max(start.minX + minSize.width, start.maxX + delta.dx) }
        if edges.contains(.top) { minY = min(start.maxY - minSize.height, start.minY + delta.dy) }
        if edges.contains(.bottom) { maxY = max(start.minY + minSize.height, start.maxY + delta.dy) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Let go: the edges that moved settle onto the grid, the others stay where they are. An edge that
    /// would come closer than `minSize` to its opposite goes to the next grid line out instead.
    static func grid(_ rect: CGRect, edges: Edges, size: CGFloat, minSize: CGSize = minSize) -> CGRect {
        guard size > 0 else { return rect }
        func snap(_ v: CGFloat) -> CGFloat { (v / size).rounded() * size }
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if edges.contains(.left) {
            minX = snap(minX)
            if maxX - minX < minSize.width { minX = ((maxX - minSize.width) / size).rounded(.down) * size }
        }
        if edges.contains(.right) {
            maxX = snap(maxX)
            if maxX - minX < minSize.width { maxX = ((minX + minSize.width) / size).rounded(.up) * size }
        }
        if edges.contains(.top) {
            minY = snap(minY)
            if maxY - minY < minSize.height { minY = ((maxY - minSize.height) / size).rounded(.down) * size }
        }
        if edges.contains(.bottom) {
            maxY = snap(maxY)
            if maxY - minY < minSize.height { maxY = ((minY + minSize.height) / size).rounded(.up) * size }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Where a rect of a new size sits so that `anchor` (a unit point, see `anchor(for:)`) stays put:
    /// the size the app actually gave its window, kept against the edges that didn't move.
    static func place(_ size: CGSize, in rect: CGRect, anchor: CGPoint) -> CGRect {
        let fixed = CGPoint(x: rect.minX + rect.width * anchor.x, y: rect.minY + rect.height * anchor.y)
        return CGRect(x: fixed.x - size.width * anchor.x, y: fixed.y - size.height * anchor.y,
                      width: size.width, height: size.height)
    }
}
