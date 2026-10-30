import CoreGraphics
import Foundation

/// Sizing a window to a fraction of a screen: halves, thirds, quarters, columns. World coordinates
/// throughout (top-left origin, points).
///
/// A slot is a fraction of an *area*: a screen-sized rect on the canvas. At 1:1 the area is the screen
/// you're looking at; zoomed out it's the *page* the window is on. Pages are screen-sized areas laid out
/// in a grid from the real desktop (page 0 is where the windows sat at launch), a gutter apart, so a
/// tiled page reads as one desktop among many from further out.
enum Tiling {
    /// Between pages, so zoomed out they read as separate areas.
    static let pageGutter: CGFloat = 240

    /// A named slot. `unit` is its rect in a unit area: (0, 0, 0.5, 1) is the left half.
    enum Preset: String, CaseIterable, Sendable {
        case leftHalf, rightHalf, topHalf, bottomHalf
        case topLeft, topRight, bottomLeft, bottomRight
        case leftThird, centerThird, rightThird
        case leftTwoThirds, centerTwoThirds, rightTwoThirds
        case full, center

        var title: String {
            switch self {
            case .leftHalf: return "Left Half"
            case .rightHalf: return "Right Half"
            case .topHalf: return "Top Half"
            case .bottomHalf: return "Bottom Half"
            case .topLeft: return "Top Left Quarter"
            case .topRight: return "Top Right Quarter"
            case .bottomLeft: return "Bottom Left Quarter"
            case .bottomRight: return "Bottom Right Quarter"
            case .leftThird: return "Left Third"
            case .centerThird: return "Centre Third"
            case .rightThird: return "Right Third"
            case .leftTwoThirds: return "Left Two-Thirds"
            case .centerTwoThirds: return "Centre Two-Thirds"
            case .rightTwoThirds: return "Right Two-Thirds"
            case .full: return "Full"
            case .center: return "Centre"
            }
        }

        /// Nil for `center`, which keeps the window's size.
        var unit: CGRect? {
            let t: CGFloat = 1.0 / 3
            switch self {
            case .leftHalf: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
            case .rightHalf: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
            case .topHalf: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
            case .bottomHalf: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
            case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
            case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
            case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
            case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
            case .leftThird: return CGRect(x: 0, y: 0, width: t, height: 1)
            case .centerThird: return CGRect(x: t, y: 0, width: t, height: 1)
            case .rightThird: return CGRect(x: 2 * t, y: 0, width: 1 - 2 * t, height: 1)
            case .leftTwoThirds: return CGRect(x: 0, y: 0, width: 2 * t, height: 1)
            case .centerTwoThirds: return CGRect(x: t / 2, y: 0, width: 2 * t, height: 1)
            case .rightTwoThirds: return CGRect(x: t, y: 0, width: 1 - t, height: 1)
            case .full: return CGRect(x: 0, y: 0, width: 1, height: 1)
            case .center: return nil
            }
        }

        /// Pressing the same slot again steps through its widths, as in Rectangle: a half, then
        /// two-thirds, then a third, then a half again.
        var next: Preset {
            switch self {
            case .leftHalf: return .leftTwoThirds
            case .leftTwoThirds: return .leftThird
            case .leftThird: return .leftHalf
            case .rightHalf: return .rightTwoThirds
            case .rightTwoThirds: return .rightThird
            case .rightThird: return .rightHalf
            case .centerThird: return .centerTwoThirds
            case .centerTwoThirds: return .centerThird
            default: return self
            }
        }

        /// The preset a repeat press starts from: pressing left half on a window at left two-thirds
        /// carries on the cycle rather than starting over.
        var cycleRoot: Preset {
            switch self {
            case .leftTwoThirds, .leftThird: return .leftHalf
            case .rightTwoThirds, .rightThird: return .rightHalf
            case .centerTwoThirds: return .centerThird
            default: return self
            }
        }
    }

    /// The green button's Fill & Arrange layouts, as macOS's: the window shares its area with the windows
    /// used just before it, each in a cell. The window itself takes the first cell.
    enum Share: String, CaseIterable, Sendable {
        case leftRight, rightLeft, topBottom, bottomTop, threeColumns, quarters

        var title: String {
            switch self {
            case .leftRight: return "Left & Right"
            case .rightLeft: return "Right & Left"
            case .topBottom: return "Top & Bottom"
            case .bottomTop: return "Bottom & Top"
            case .threeColumns: return "Three Columns"
            case .quarters: return "Quarters"
            }
        }

        /// Unit cells, this window's first.
        var cells: [CGRect] {
            let left = CGRect(x: 0, y: 0, width: 0.5, height: 1), right = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
            let top = CGRect(x: 0, y: 0, width: 1, height: 0.5), bottom = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
            switch self {
            case .leftRight: return [left, right]
            case .rightLeft: return [right, left]
            case .topBottom: return [top, bottom]
            case .bottomTop: return [bottom, top]
            case .threeColumns: return Tiling.cells(columns: 3, rows: 1)
            case .quarters: return Tiling.cells(columns: 2, rows: 2)
            }
        }

        /// The preset this window's cell is, so a later press of that slot cycles on from it.
        var preset: Preset? {
            switch self {
            case .leftRight: return .leftHalf
            case .rightLeft: return .rightHalf
            case .topBottom: return .topHalf
            case .bottomTop: return .bottomHalf
            case .threeColumns: return .leftThird
            case .quarters: return .topLeft
            }
        }
    }

    /// A window's place in an area, kept so a repeat press can cycle and so entering the window can
    /// line the camera up with the area it was tiled in.
    struct Tile: Equatable {
        var area: CGRect
        var preset: Preset?
    }

    // MARK: Geometry

    /// The rect a unit slot takes in an area: `gap` from the area's edges and `gap` between neighbours
    /// (half of it on each side of a shared edge), in whole points.
    static func rect(_ unit: CGRect, in area: CGRect, gap: CGFloat) -> CGRect {
        func edge(_ u: CGFloat, _ origin: CGFloat, _ length: CGFloat, leading: Bool) -> CGFloat {
            let v = origin + u * length
            let atBorder = u <= 0.0001 || u >= 0.9999
            let inset = atBorder ? gap : gap / 2
            return (leading ? v + inset : v - inset).rounded()
        }
        let minX = edge(unit.minX, area.minX, area.width, leading: true)
        let maxX = edge(unit.maxX, area.minX, area.width, leading: false)
        let minY = edge(unit.minY, area.minY, area.height, leading: true)
        let maxY = edge(unit.maxY, area.minY, area.height, leading: false)
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    /// Where a preset puts a window of `size` in an area. `center` keeps the size, no larger than the
    /// area allows.
    static func rect(_ preset: Preset, size: CGSize, in area: CGRect, gap: CGFloat) -> CGRect {
        if let unit = preset.unit { return rect(unit, in: area, gap: gap) }
        let room = area.insetBy(dx: gap, dy: gap)
        let w = min(size.width, room.width), h = min(size.height, room.height)
        return CGRect(x: (room.midX - w / 2).rounded(), y: (room.midY - h / 2).rounded(), width: w, height: h)
    }

    /// The corner of a slot a window stays against when its app won't take the slot's exact size (a
    /// minimum width, Terminal's whole character cells): the slot's outer edges, as a unit point for
    /// `Resizing.place`. A left slot keeps left, a right one right, a centred one centred.
    static func anchor(for unit: CGRect?) -> CGPoint {
        guard let unit else { return CGPoint(x: 0.5, y: 0.5) }
        func axis(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            if lo <= 0.0001 { return 0 }
            if hi >= 0.9999 { return 1 }
            return 0.5
        }
        return CGPoint(x: axis(unit.minX, unit.maxX), y: axis(unit.minY, unit.maxY))
    }

    /// The page a world point is on. `screen` is the usable screen at the identity camera: page 0.
    static func page(containing p: CGPoint, screen: CGRect, gutter: CGFloat = pageGutter) -> CGRect {
        let pitchX = screen.width + gutter, pitchY = screen.height + gutter
        // Half the gutter belongs to each page beside it.
        let i = ((p.x - screen.minX + gutter / 2) / pitchX).rounded(.down)
        let j = ((p.y - screen.minY + gutter / 2) / pitchY).rounded(.down)
        return CGRect(x: screen.minX + i * pitchX, y: screen.minY + j * pitchY, width: screen.width, height: screen.height)
    }

    /// The unit cells of an arrangement, in reading order: `columns` across and `rows` down.
    static func cells(columns: Int, rows: Int) -> [CGRect] {
        guard columns > 0, rows > 0 else { return [] }
        var cells: [CGRect] = []
        for r in 0..<rows {
            for c in 0..<columns {
                cells.append(CGRect(x: CGFloat(c) / CGFloat(columns), y: CGFloat(r) / CGFloat(rows),
                                    width: 1 / CGFloat(columns), height: 1 / CGFloat(rows)))
            }
        }
        return cells
    }

    /// The windows an arrangement takes, in the order they fill its cells: left to right for a row of
    /// columns, and row by row (top to bottom, then left to right) for a grid.
    static func arrangeOrder(_ rects: [CGRect], rows: Int) -> [Int] {
        func leftOf(_ a: Int, _ b: Int) -> Bool {
            rects[a].midX != rects[b].midX ? rects[a].midX < rects[b].midX : rects[a].midY < rects[b].midY
        }
        let all = Array(rects.indices)
        if rows <= 1 { return all.sorted(by: leftOf) }
        // Into rows by where they sit now, then each row left to right.
        let byY = all.sorted { rects[$0].midY < rects[$1].midY }
        let perRow = max(1, Int((Double(byY.count) / Double(rows)).rounded(.up)))
        var order: [Int] = []
        var start = 0
        while start < byY.count {
            order += byY[start..<min(byY.count, start + perRow)].sorted(by: leftOf)
            start += perRow
        }
        return order
    }
}

