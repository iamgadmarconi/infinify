import CoreGraphics
import Foundation

/// Where the desktop's files, and separately its widgets, sit on the canvas (Settings › Canvas › Desktop):
/// a dot on a small map of the canvas with the windows in its middle. Each is one block that keeps the
/// real desktop's arrangement inside it: the files as Finder lays them out, trimmed to what's there; the
/// widgets as they're placed on the desktop, relative to each other. The blocks follow the windows when
/// they settle.
///
/// The spot is normalised to the windows' bounds: (0, 0) is their top-left, (1, 1) their bottom-right,
/// anywhere on the map of the whole canvas (`mapWorld`). The block is centred on it; outside the
/// windows it's pushed straight out, far enough to sit `gap` clear of them; inside, it goes under them.
struct DesktopPlacement: Equatable {
    var x: CGFloat
    var y: CGFloat

    /// A spot stays within this many windows of them, so a bad saved value can't fly off.
    static let limit: CGFloat = 5

    /// As macOS lays them out: files to the right, widgets to the left, both near the top.
    static let filesDefault = DesktopPlacement(x: 1.25, y: 0.3)
    static let widgetsDefault = DesktopPlacement(x: -0.25, y: 0.3)

    /// How far a block sits from the windows, and from the other block (world points).
    static let gap: CGFloat = 80

    init(x: CGFloat, y: CGFloat) {
        self.x = min(1 + Self.limit, max(-Self.limit, x))
        self.y = min(1 + Self.limit, max(-Self.limit, y))
    }

    /// "1.25,0.3", as saved in the defaults.
    var stored: String { "\(Double(x)),\(Double(y))" }

    init?(stored: String) {
        let parts = stored.split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]), x.isFinite, y.isFinite else { return nil }
        self.init(x: x, y: y)
    }

    /// The spot at a world point, relative to `bounds` (the windows').
    init(world p: CGPoint, around bounds: CGRect) {
        self.init(x: bounds.width > 0 ? (p.x - bounds.minX) / bounds.width : 0,
                  y: bounds.height > 0 ? (p.y - bounds.minY) / bounds.height : 0)
    }

    /// The world point the spot is at around `bounds`.
    func world(around bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height)
    }

    /// The part of the canvas the map in Settings shows: the windows (`bounds`) and the blocks where they
    /// are, with half the windows' size spare on every side to drag into, grown about its centre on the
    /// shorter axis to the map's `aspect` (width / height), so the map is the canvas at true proportions.
    static func mapWorld(around bounds: CGRect, blocks: [CGRect], aspect: CGFloat, pad: CGFloat = 0.5) -> CGRect {
        var r = blocks.reduce(bounds) { $0.union($1) }.insetBy(dx: -pad * bounds.width, dy: -pad * bounds.height)
        guard r.width > 0, r.height > 0, aspect > 0 else { return r }
        if r.width / r.height < aspect {
            r = r.insetBy(dx: -(r.height * aspect - r.width) / 2, dy: 0)
        } else {
            r = r.insetBy(dx: 0, dy: -(r.width / aspect - r.height) / 2)
        }
        return r
    }

    var isInside: Bool { (0...1).contains(x) && (0...1).contains(y) }

    /// How far outside the windows the spot is on each axis, in windows (0 inside the span).
    private var out: (x: CGFloat, y: CGFloat) {
        (x < 0 ? -x : max(0, x - 1), y < 0 ? -y : max(0, y - 1))
    }

    /// In words, for VoiceOver and the log.
    var title: String {
        guard !isInside else { return "Under the windows" }
        let h = x < 0 ? "left" : x > 1 ? "right" : nil
        let v = y < 0 ? "top" : y > 1 ? "bottom" : nil
        switch (v, h) {
        case (nil, let h?): return "\(h.capitalized) of the windows"
        case (let v?, nil): return v == "top" ? "Above the windows" : "Below the windows"
        case (let v?, let h?): return "Off the \(v)-\(h) corner"
        case (nil, nil): return "Under the windows"
        }
    }

    /// Where a block of this size goes for this spot around `bounds` (the windows').
    func rect(size: CGSize, around bounds: CGRect, gap: CGFloat = DesktopPlacement.gap) -> CGRect {
        let centre = world(around: bounds)
        var r = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
        guard !isInside, r.intersects(bounds.insetBy(dx: -gap, dy: -gap)) else { return r }
        // Straight out along the axis the spot is furthest out on.
        let o = out
        if o.x >= o.y {
            r.origin.x = x < 0 ? bounds.minX - gap - size.width : bounds.maxX + gap
        } else {
            r.origin.y = y < 0 ? bounds.minY - gap - size.height : bounds.maxY + gap
        }
        return r
    }

    /// The widgets' and the files' blocks around `bounds`. Where they'd meet, the widgets keep their
    /// place and the files move clear of them, the way the files' dot lies from the widgets'.
    static func rects(widgets: (size: CGSize, at: DesktopPlacement)?, files: (size: CGSize, at: DesktopPlacement)?,
                      around bounds: CGRect, gap: CGFloat = gap) -> (widgets: CGRect?, files: CGRect?) {
        let w = widgets.map { $0.at.rect(size: $0.size, around: bounds, gap: gap) }
        guard var f = files.map({ $0.at.rect(size: $0.size, around: bounds, gap: gap) }) else { return (w, nil) }
        if let w, let files, let widgets, f.intersects(w.insetBy(dx: -gap, dy: -gap)) {
            // Compare in world units, so a wide canvas doesn't make every lean look sideways.
            let dx = (files.at.x - widgets.at.x) * bounds.width, dy = (files.at.y - widgets.at.y) * bounds.height
            if abs(dx) >= abs(dy) {
                f.origin.x = dx < 0 ? w.minX - gap - f.width : w.maxX + gap
            } else {
                f.origin.y = dy < 0 ? w.minY - gap - f.height : w.maxY + gap
            }
        }
        return (w, f)
    }

    /// The part of Finder's desktop with files on it: every file's picture and label (`hitRects`, screen
    /// points) with a margin, inside the screen. With no files, a patch of ground at the top right,
    /// where Finder puts the first one, so New Folder has somewhere to be.
    static func filesContent(hitRects: [CGRect], screen: CGRect, margin: CGFloat = 16) -> CGRect {
        let used = hitRects.reduce(CGRect.null) { $0.union($1) }
        if !used.isNull {
            let r = used.insetBy(dx: -margin, dy: -margin).intersection(screen)
            if !r.isNull, r.width > 0, r.height > 0 { return r.integral }
        }
        let empty = CGSize(width: min(160, screen.width), height: min(140, screen.height))
        return CGRect(x: screen.maxX - empty.width, y: screen.minY + min(40, screen.height - empty.height),
                      width: empty.width, height: empty.height)
    }
}

/// The canvas as the map in Settings › Canvas › Desktop draws it, in world points: the windows' bounds
/// (the screen's at 1:1 with no windows), each window, and the widgets' and files' blocks while they're
/// on the canvas.
struct DesktopMapSnapshot: Equatable {
    var bounds: CGRect
    var windows: [CGRect]
    var widgets: CGRect?
    var files: CGRect?
}
