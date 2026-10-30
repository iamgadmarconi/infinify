import AppKit

/// One display, in the coordinates the rest of Sunlight speaks: Quartz global space, origin at the
/// primary display's top-left corner, y down, in points. The window list, Accessibility, posted events
/// and the Dock add-on all use it.
///
/// Every display has a canvas of its own (`Desk`), and every canvas's world is this same space: at its
/// home camera a canvas shows its display at 1:1, so a window sits on the canvas where it is on the
/// screen. What differs between canvases is only where their view starts: a canvas's view coordinates
/// are global coordinates less its display's origin, which is zero on the primary display.
struct Display: Equatable, Sendable {
    let id: CGDirectDisplayID
    /// Stable across reconnects and restarts, unlike `id`: what a display's canvas is remembered by.
    let uuid: String
    let name: String
    /// The whole display, global.
    let frame: CGRect
    /// Below the menu bar and beside the Dock, global.
    let visible: CGRect
    /// The same display in AppKit's coordinates (bottom-left origin), for placing windows on it.
    let cocoaFrame: CGRect
    let scale: CGFloat

    var origin: CGPoint { frame.origin }

    /// The visible part in the canvas's view coordinates (top-left of the display at zero).
    var visibleInView: CGRect { visible.offsetBy(dx: -frame.minX, dy: -frame.minY) }

    /// The menu bar's height on this display: what a borderless window covering it has above the visible part.
    var topInset: CGFloat { visible.minY - frame.minY }

    init(id: CGDirectDisplayID, uuid: String, name: String, frame: CGRect, visible: CGRect, cocoaFrame: CGRect, scale: CGFloat) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.frame = frame
        self.visible = visible
        self.cocoaFrame = cocoaFrame
        self.scale = scale
    }

    /// The display an `NSScreen` is. `primaryHeight` is the primary display's height, which anchors the
    /// flip from AppKit's coordinates to Quartz's.
    @MainActor
    init?(screen: NSScreen, primaryHeight: CGFloat) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = CGDirectDisplayID(number.uint32Value)
        self.init(id: id,
                  uuid: Display.uuid(of: id),
                  name: screen.localizedName,
                  frame: Display.quartz(screen.frame, primaryHeight: primaryHeight),
                  visible: Display.quartz(screen.visibleFrame, primaryHeight: primaryHeight),
                  cocoaFrame: screen.frame,
                  scale: screen.backingScaleFactor)
    }

    /// Every display, the primary (the one with the menu bar) first, as `NSScreen.screens` lists them.
    @MainActor
    static var all: [Display] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        return screens.compactMap { Display(screen: $0, primaryHeight: primary.frame.height) }
    }

    /// AppKit's rect (bottom-left origin, y up from the primary display's bottom edge) in Quartz's.
    static func quartz(_ cocoa: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: cocoa.minX, y: primaryHeight - cocoa.maxY, width: cocoa.width, height: cocoa.height)
    }

    /// The display's UUID as a string; the display number when ColorSync has none (it always has one
    /// for a real display).
    static func uuid(of id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String? else { return "display-\(id)" }
        return string
    }

    /// Which display a global rect belongs to: the one holding its centre, else the one it overlaps most,
    /// else the nearest. Nil only with no displays.
    static func index(for rect: CGRect, in displays: [Display]) -> Int? {
        guard !displays.isEmpty else { return nil }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        if let i = displays.firstIndex(where: { $0.frame.contains(centre) }) { return i }
        let overlaps = displays.map { d -> CGFloat in
            let o = d.frame.intersection(rect)
            return o.isNull ? 0 : o.width * o.height
        }
        if let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 { return best }
        return displays.indices.min { distance(centre, to: displays[$0].frame) < distance(centre, to: displays[$1].frame) }
    }

    /// Which display a global point is on, else the nearest.
    static func index(for point: CGPoint, in displays: [Display]) -> Int? {
        index(for: CGRect(origin: point, size: .zero), in: displays)
    }

    private static func distance(_ p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}

extension Camera {
    /// The same camera seen from global coordinates rather than from a view whose top-left is at
    /// `viewOrigin` (a display's origin): `toScreen` gives global points, `toWorld` takes them. What a
    /// real window's frame, a posted event or the Dock add-on's transform go through.
    func global(viewOrigin o: CGPoint) -> Camera {
        Camera(origin: CGPoint(x: origin.x - o.x / zoom, y: origin.y - o.y / zoom), zoom: zoom)
    }

    /// The identity camera of a view whose top-left is at `viewOrigin`: the display at 1:1, world where
    /// the screen is.
    static func home(viewOrigin o: CGPoint) -> Camera {
        Camera(origin: o, zoom: 1)
    }
}
