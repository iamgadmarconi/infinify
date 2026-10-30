import AppKit

/// The screen-space layer over the canvas: the minimap. A sibling of the canvas view, not inside it
/// (the canvas view hosts its own layers), that takes only the clicks landing on something of its
/// own; a scroll or a pinch over it still goes to the canvas. Top-left coordinates, like the canvas's screen space.
@MainActor
final class OverlayView: NSView {
    weak var canvas: CanvasView?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func scrollWheel(with event: NSEvent) {
        canvas?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        canvas?.magnify(with: event)
    }

    /// Whether a point is under something shown here: nothing beneath it on the canvas is hovered.
    func covers(_ point: CGPoint) -> Bool {
        subviews.contains { !$0.isHidden && $0.frame.contains(point) }
    }
}
