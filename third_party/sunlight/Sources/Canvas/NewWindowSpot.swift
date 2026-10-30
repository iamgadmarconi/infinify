import CoreGraphics

/// Where a window that just opened goes on the canvas: in the middle of the view if that's clear of
/// every other window, otherwise the free spot nearest the middle, beside the windows in the way, in
/// view if there's room in view. World coordinates throughout (top-left origin, points). Pure: rects in,
/// a rect out; the controller gathers the windows. Right-click › Open Here… aims it at the clicked spot
/// instead of the middle (`target`).
enum NewWindowSpot {
    /// What sticking out of view costs: more than any distance, so a free spot fully in view always
    /// beats one that isn't (where the window would pop in partly unseen), plus this much per point
    /// out, so among those the one least out wins.
    static let outOfViewPenalty: CGFloat = 1_000_000
    static let outOfViewWeight: CGFloat = 4

    /// `size`: the new window's. `others`: every window already on the canvas. `view`: the part of the
    /// world on screen. `gap`: the space left between. `target`: where the window's middle should be;
    /// the middle of the view if nil.
    static func spot(size: CGSize, avoiding others: [CGRect], view: CGRect, gap: CGFloat,
                     target: CGPoint? = nil) -> CGRect {
        let centre = target ?? CGPoint(x: view.midX, y: view.midY)
        var middle = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                            width: size.width, height: size.height)
        // Aimed at a spot near the edge of the view: pushed in just far enough to be all on screen.
        if target != nil { middle = inside(middle, view) }
        guard !isClear(middle, of: others, gap: gap) else { return middle }
        var best: (rect: CGRect, score: CGFloat)?
        for o in others {
            for origin in candidates(beside: o, size: size, gap: gap, middle: middle.origin) {
                let r = CGRect(origin: origin, size: size)
                guard isClear(r, of: others, gap: gap) else { continue }
                let s = score(r, target: centre, view: view)
                if best == nil || s < best!.score { best = (r, s) }
            }
        }
        if let best { return best.rect }
        // Nothing beside anything is free (it can't happen with finite windows, but): right of them all.
        let bounds = others.reduce(CGRect.null) { $0.union($1) }
        return CGRect(origin: CGPoint(x: bounds.maxX + gap, y: bounds.minY), size: size)
    }

    /// `r` moved the least to lie inside `view`, along each axis it fits on.
    static func inside(_ r: CGRect, _ view: CGRect) -> CGRect {
        var o = r.origin
        if r.width <= view.width { o.x = min(max(o.x, view.minX), view.maxX - r.width) }
        if r.height <= view.height { o.y = min(max(o.y, view.minY), view.maxY - r.height) }
        return CGRect(origin: o, size: r.size)
    }

    /// Clear of every window by at least the gap (edges exactly a gap apart are clear).
    static func isClear(_ r: CGRect, of others: [CGRect], gap: CGFloat) -> Bool {
        let reach = max(gap - 0.5, 0)
        let grown = r.insetBy(dx: -reach, dy: -reach)
        return !others.contains { grown.intersects($0) }
    }

    /// The spots touching `o` a gap away on each side: lined up with either of its edges along that side,
    /// or level with the target (`middle`, the centred spot's origin).
    static func candidates(beside o: CGRect, size: CGSize, gap: CGFloat, middle: CGPoint) -> [CGPoint] {
        let right = o.maxX + gap, left = o.minX - gap - size.width
        let below = o.maxY + gap, above = o.minY - gap - size.height
        return [
            CGPoint(x: right, y: o.minY), CGPoint(x: right, y: o.maxY - size.height),
            CGPoint(x: left, y: o.minY), CGPoint(x: left, y: o.maxY - size.height),
            CGPoint(x: o.minX, y: below), CGPoint(x: o.maxX - size.width, y: below),
            CGPoint(x: o.minX, y: above), CGPoint(x: o.maxX - size.width, y: above),
            CGPoint(x: right, y: middle.y), CGPoint(x: left, y: middle.y),
            CGPoint(x: middle.x, y: below), CGPoint(x: middle.x, y: above),
        ]
    }

    /// Distance from the target to the spot's middle; a spot sticking out of view comes after every one
    /// that doesn't, the further out the later.
    static func score(_ r: CGRect, target: CGPoint, view: CGRect) -> CGFloat {
        let distance = hypot(r.midX - target.x, r.midY - target.y)
        let out = max(0, view.minX - r.minX) + max(0, r.maxX - view.maxX)
            + max(0, view.minY - r.minY) + max(0, r.maxY - view.maxY)
        return out > 0 ? outOfViewPenalty + outOfViewWeight * out + distance : distance
    }
}
