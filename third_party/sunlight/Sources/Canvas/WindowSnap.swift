import CoreGraphics

/// Coming to rest almost exactly on a screen-sized window: near 1:1, with every edge of the window nearly
/// where it would sit on the screen once entered. The canvas then nudges the rest of the way on a quick,
/// stiff spring and enters the window, so a pan, pinch or minimap jump that lands *nearly* on a full
/// screen window lands on it. Pure arithmetic, so it can be tested; the view calls for it when the camera
/// settles after the user moved it (`CanvasView.onSettle`) and the controller decides (`snapToWindow`).
enum WindowSnap {
    /// A window at least this share of the visible area, each way, counts as screen-sized.
    static let fill: CGFloat = 0.9
    /// How far each edge may be from where it lands, as a share of the view's width or height.
    static let reach: CGFloat = 0.05
    /// Never less than this, in screen points, however small the screen.
    static let minReach: CGFloat = 32
    /// The nudge's spring: quicker and stiffer than a flight's (0.45 s, 0.72), overshooting by about 1 %.
    static let response: CGFloat = 0.24
    static let damping: CGFloat = 0.82

    /// A window that could be snapped to: its rect in the world, and where its top-left corner sits on
    /// screen (view coordinates, top-left origin) once it's entered at 1:1.
    struct Window {
        let rect: CGRect
        let spot: CGPoint
    }

    static func isScreenSized(_ size: CGSize, visible: CGSize) -> Bool {
        size.width >= visible.width * fill && size.height >= visible.height * fill
    }

    /// The window to snap to, by index, and the camera that shows it at 1:1 on its spot; nil when no
    /// screen-sized window is close enough. The closest wins when several are.
    static func target(camera: Camera, viewSize: CGSize, visible: CGRect, windows: [Window]) -> (index: Int, camera: Camera)? {
        let rx = max(minReach, viewSize.width * reach), ry = max(minReach, viewSize.height * reach)
        var best: (index: Int, camera: Camera, off: CGFloat)?
        for (i, w) in windows.enumerated() where isScreenSized(w.rect.size, visible: visible.size) {
            let now = camera.toScreen(w.rect)
            let then = CGRect(origin: w.spot, size: w.rect.size)
            let dx = max(abs(now.minX - then.minX), abs(now.maxX - then.maxX))
            let dy = max(abs(now.minY - then.minY), abs(now.maxY - then.maxY))
            guard dx <= rx, dy <= ry else { continue }
            let off = dx / rx + dy / ry
            if best == nil || off < best!.off {
                best = (i, Camera(origin: CGPoint(x: w.rect.minX - w.spot.x, y: w.rect.minY - w.spot.y), zoom: 1), off)
            }
        }
        return best.map { ($0.index, $0.camera) }
    }
}
