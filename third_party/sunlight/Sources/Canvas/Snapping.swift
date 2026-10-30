import CoreGraphics

/// Where a window being dragged lines up with its neighbours, and where it lands on the grid when it's
/// let go. World coordinates throughout (top-left origin, points).
enum Snapping {
    /// What a drag is lined up with, drawn while it's held there: an edge or centre shared with a
    /// neighbour (`line`), or the standard gap to a neighbour side by side (`gap`).
    struct Guide {
        enum Kind { case line, gap }
        let kind: Kind
        let from: CGPoint
        let to: CGPoint
    }

    struct Alignment {
        var origin: CGPoint
        /// Whether a neighbour holds the rect on that axis. The grid leaves a held axis alone.
        var snappedX = false
        var snappedY = false
        var guides: [Guide] = []
    }

    /// Lines `moving` up with the nearest of `others` on each axis, if one is within `threshold`: left,
    /// right and centre with theirs, or `gap` away from a neighbour beside it. Called with the raw
    /// pointer position on every move, so the rect sticks until the pointer pulls `threshold` away.
    static func align(_ moving: CGRect, to others: [CGRect], threshold: CGFloat, gap: CGFloat) -> Alignment {
        let x = nearest(candidates(.x, moving, others, gap), threshold: threshold)
        let y = nearest(candidates(.y, moving, others, gap), threshold: threshold)
        let snapped = moving.offsetBy(dx: x.first?.delta ?? 0, dy: y.first?.delta ?? 0)
        var result = Alignment(origin: snapped.origin, snappedX: !x.isEmpty, snappedY: !y.isEmpty)
        result.guides = x.map { guide($0, .x, snapped, gap) } + y.map { guide($0, .y, snapped, gap) }
        return result
    }

    /// The nearest grid point on each axis that no neighbour is holding.
    static func grid(_ origin: CGPoint, size: CGFloat, keepX: Bool, keepY: Bool) -> CGPoint {
        guard size > 0 else { return origin }
        return CGPoint(x: keepX ? origin.x : (origin.x / size).rounded() * size,
                       y: keepY ? origin.y : (origin.y / size).rounded() * size)
    }

    // MARK: Candidates

    private enum Axis { case x, y }

    /// One way to line up on an axis: move by `delta`, and the rect shares `at` with `other` (a line's
    /// coordinate, or where the gap starts).
    private struct Candidate {
        let delta: CGFloat
        let other: CGRect
        let kind: Guide.Kind
        let at: CGFloat
    }

    private static func span(_ r: CGRect, _ axis: Axis) -> (min: CGFloat, mid: CGFloat, max: CGFloat) {
        axis == .x ? (r.minX, r.midX, r.maxX) : (r.minY, r.midY, r.maxY)
    }

    /// Edges with edges and centre with centre (an edge to a centre is too sticky to be useful), plus the
    /// gap either side of a neighbour that overlaps the rect across the axis.
    private static func candidates(_ axis: Axis, _ moving: CGRect, _ others: [CGRect], _ gap: CGFloat) -> [Candidate] {
        let m = span(moving, axis)
        var list: [Candidate] = []
        for o in others {
            let t = span(o, axis)
            for mv in [m.min, m.max] {
                for tv in [t.min, t.max] {
                    list.append(Candidate(delta: tv - mv, other: o, kind: .line, at: tv))
                }
            }
            list.append(Candidate(delta: t.mid - m.mid, other: o, kind: .line, at: t.mid))

            let across = axis == .x ? (moving.minY, moving.maxY, o.minY, o.maxY) : (moving.minX, moving.maxX, o.minX, o.maxX)
            guard across.0 < across.3, across.2 < across.1 else { continue }
            list.append(Candidate(delta: t.max + gap - m.min, other: o, kind: .gap, at: t.max))
            list.append(Candidate(delta: t.min - gap - m.max, other: o, kind: .gap, at: t.min - gap))
        }
        return list
    }

    /// The closest candidate within reach, and every other one it lines the rect up with too.
    private static func nearest(_ list: [Candidate], threshold: CGFloat) -> [Candidate] {
        guard let best = list.filter({ abs($0.delta) <= threshold }).min(by: { abs($0.delta) < abs($1.delta) }) else {
            return []
        }
        return list.filter { abs($0.delta - best.delta) < 0.5 }
    }

    /// A line runs along the shared coordinate across both rects. A gap is marked across it, halfway
    /// along where the two rects overlap.
    private static func guide(_ c: Candidate, _ axis: Axis, _ r: CGRect, _ gap: CGFloat) -> Guide {
        let o = c.other
        switch (c.kind, axis) {
        case (.line, .x):
            return Guide(kind: .line, from: CGPoint(x: c.at, y: min(r.minY, o.minY)), to: CGPoint(x: c.at, y: max(r.maxY, o.maxY)))
        case (.line, .y):
            return Guide(kind: .line, from: CGPoint(x: min(r.minX, o.minX), y: c.at), to: CGPoint(x: max(r.maxX, o.maxX), y: c.at))
        case (.gap, .x):
            let y = (max(r.minY, o.minY) + min(r.maxY, o.maxY)) / 2
            return Guide(kind: .gap, from: CGPoint(x: c.at, y: y), to: CGPoint(x: c.at + gap, y: y))
        case (.gap, .y):
            let x = (max(r.minX, o.minX) + min(r.maxX, o.maxX)) / 2
            return Guide(kind: .gap, from: CGPoint(x: x, y: c.at), to: CGPoint(x: x, y: c.at + gap))
        }
    }
}
