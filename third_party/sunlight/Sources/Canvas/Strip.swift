import CoreGraphics
import Foundation

/// Strip mode (Window › Strip Mode, ⌃⌥S): every window on one endless horizontal strip, one column per
/// app, the app used last on the left and each one used before it further right. Inside a column the
/// app's windows are stacked top to bottom, the one used last on top. World coordinates throughout
/// (top-left origin, points). Pure: items in, columns and rects out; the controller gathers the
/// windows, keeps the recency list and animates.
enum Strip {
    /// One window on the strip.
    struct Item: Equatable {
        /// Where it is now: its size is kept, its place decides the order of windows never used.
        var rect: CGRect
        /// What a column groups by: the app's bundle ID, or its name.
        var app: String
        /// Place in the recency list, 0 the most recent; nil when never used.
        var recency: Int?
        /// Hidden or minimized: it keeps its slot, so nothing shifts when it comes back, but the arrow
        /// keys skip it.
        var away = false
    }

    enum Direction: Sendable {
        case left, right, up, down
    }

    /// The columns, left to right, each a list of item indices top to bottom.
    ///
    /// With `usingRecency` an app's column goes by its most recently used window and a column by its
    /// windows' recency; apps and windows never used come after, in the order they sit now (left to
    /// right, top to bottom). Without it, only where they sit counts: the order a layout restore or a
    /// relaunch put them in.
    static func columns(_ items: [Item], usingRecency: Bool = true) -> [[Int]] {
        var byApp: [String: [Int]] = [:]
        var apps: [String] = []
        for i in items.indices {
            if byApp[items[i].app] == nil { apps.append(items[i].app) }
            byApp[items[i].app, default: []].append(i)
        }
        func rank(_ i: Int) -> Int { usingRecency ? items[i].recency ?? Int.max : Int.max }
        var columns = apps.map { app in
            byApp[app, default: []].sorted { a, b in
                let ra = rank(a), rb = rank(b)
                if ra != rb { return ra < rb }
                let ka = (items[a].rect.minY, items[a].rect.minX), kb = (items[b].rect.minY, items[b].rect.minX)
                return ka != kb ? ka < kb : a < b
            }
        }
        // An app's place: its best rank, then the leftmost of its windows, then the order apps were met.
        let keys = columns.map { column -> (Int, CGFloat) in
            (column.map(rank).min() ?? Int.max, column.map { items[$0].rect.minX }.min() ?? 0)
        }
        let order = columns.indices.sorted { a, b in
            if keys[a].0 != keys[b].0 { return keys[a].0 < keys[b].0 }
            if keys[a].1 != keys[b].1 { return keys[a].1 < keys[b].1 }
            return a < b
        }
        columns = order.map { columns[$0] }
        return columns
    }

    struct Placement: Equatable {
        /// Each item's new rect, indexed like the items: its own size, at its slot.
        var rects: [CGRect]
        /// The columns it was laid out from, left to right, top to bottom.
        var columns: [[Int]]
        /// Around the whole strip, `gap` included, for the camera to frame.
        var bounds: CGRect
    }

    /// Lays `columns` out from `origin` (the top-left of the first window): each column as wide as its
    /// widest window, `gap` between columns and between the windows stacked in one, every window at the
    /// left of its column. Nothing is resized. Points are rounded, so a window entered at 1:1 is on whole
    /// points.
    static func layout(_ items: [Item], columns: [[Int]], origin: CGPoint, gap: CGFloat) -> Placement {
        var rects = items.map(\.rect)
        var x = origin.x
        var bottom = origin.y
        for column in columns where !column.isEmpty {
            var y = origin.y
            var width: CGFloat = 0
            for i in column {
                let size = items[i].rect.size
                rects[i].origin = CGPoint(x: x.rounded(), y: y.rounded())
                y += size.height + gap
                width = max(width, size.width)
            }
            bottom = max(bottom, y - gap)
            x += width + gap
        }
        let placed = columns.flatMap { $0 }
        let bounds = placed.isEmpty ? CGRect.null
            : CGRect(x: origin.x - gap, y: origin.y - gap, width: x - origin.x + gap, height: bottom - origin.y + 2 * gap)
        return Placement(rects: rects, columns: columns, bounds: bounds)
    }

    /// `columns(items)` laid out (see `layout(_:columns:origin:gap:)`).
    static func layout(_ items: [Item], origin: CGPoint, gap: CGFloat) -> Placement {
        layout(items, columns: columns(items), origin: origin, gap: gap)
    }

    /// The order after the window `dropped` was let go at `rects[dropped]`: its whole column goes where
    /// the window was dropped, passing a neighbouring column once the window's middle is past that
    /// column's middle, and inside its column it takes the place its middle is at. Every other window's
    /// rect is where it sits in the strip.
    static func reordered(_ columns: [[Int]], rects: [CGRect], dropped: Int) -> [[Int]] {
        func middleX(_ column: [Int]) -> CGFloat {
            if column.contains(dropped) { return rects[dropped].midX }
            let outline = column.reduce(CGRect.null) { $0.union(rects[$1]) }
            return outline.isNull ? 0 : outline.midX
        }
        let keys = columns.map(middleX)
        let order = columns.indices.sorted { keys[$0] != keys[$1] ? keys[$0] < keys[$1] : $0 < $1 }
        return order.map { c in
            let column = columns[c]
            guard column.contains(dropped) else { return column }
            let rest = column.filter { $0 != dropped }
            let at = rest.firstIndex { rects[dropped].midY < rects[$0].midY } ?? rest.count
            var placed = rest
            placed.insert(dropped, at: at)
            return placed
        }
    }

    /// The window the arrow keys go to from `item`: ← → the top window of the next column on that side
    /// that has one on the canvas, ↑ ↓ the next window up or down its own column. Hidden and minimized
    /// windows are skipped. nil at either end.
    static func neighbour(of item: Int, in columns: [[Int]], away: [Bool], direction: Direction) -> Int? {
        guard let c = columns.firstIndex(where: { $0.contains(item) }) else { return nil }
        let present = { (i: Int) in i < away.count ? !away[i] : true }
        switch direction {
        case .left, .right:
            let step = direction == .left ? -1 : 1
            var next = c + step
            while columns.indices.contains(next) {
                if let top = columns[next].first(where: present) { return top }
                next += step
            }
            return nil
        case .up, .down:
            let column = columns[c]
            guard var r = column.firstIndex(of: item) else { return nil }
            let step = direction == .up ? -1 : 1
            r += step
            while column.indices.contains(r) {
                if present(column[r]) { return column[r] }
                r += step
            }
            return nil
        }
    }
}
