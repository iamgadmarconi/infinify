import CoreGraphics
import QuartzCore

/// The pieces of camera motion that are pure arithmetic, kept out of the view so they can be tested:
/// input gathered between display frames, and the coasts that carry a pan or a pinch on after the
/// fingers lift.
///
/// Why gather: scroll events, pinch events and the trackpad's four-finger frames each arrive on their
/// own clock (up to 120 Hz, ~125 Hz for the trackpad), none of them the display's. Moving the camera
/// the moment each one lands puts several moves in one frame and none in the next, which reads as
/// judder even when no frame is dropped. The view folds them into a `PendingInput` and applies it once
/// per display-link tick instead (see `CanvasView.tick`).
enum Motion {
    /// Input since the last frame: pans summed, zooms multiplied about the latest anchor.
    struct PendingInput: Equatable {
        /// Screen points, top-left space.
        var pan = CGVector.zero
        var zoomFactor: CGFloat = 1
        /// Where the last zoom event was, on screen: the zoom holds that point still.
        var zoomAnchor: CGPoint?
        /// How many events were folded in: the perf log reports it.
        var events = 0

        var isEmpty: Bool { pan == .zero && zoomFactor == 1 }

        mutating func addPan(_ delta: CGVector) {
            pan.dx += delta.dx
            pan.dy += delta.dy
            events += 1
        }

        /// Zooms about `anchor`. A pan gathered before it is carried along: it was a move of the
        /// content on screen, and stays one at any zoom.
        mutating func addZoom(by factor: CGFloat, around anchor: CGPoint) {
            zoomFactor *= factor
            zoomAnchor = anchor
            events += 1
        }

        /// The camera after this input: the zoom first, about its anchor, then the pan. `clamp` keeps
        /// the zoom within the view's range (the anchor stays put under a clamped zoom too).
        func applied(to camera: Camera, clamp: (CGFloat) -> CGFloat) -> Camera {
            var c = camera
            if zoomFactor != 1, let anchor = zoomAnchor {
                let world = c.toWorld(anchor)
                c.zoom = clamp(c.zoom * zoomFactor)
                c.origin = CGPoint(x: world.x - anchor.x / c.zoom, y: world.y - anchor.y / c.zoom)
            }
            if pan != .zero {
                c.origin.x -= pan.dx / c.zoom
                c.origin.y -= pan.dy / c.zoom
            }
            return c
        }
    }

    /// A pan that keeps going after the fingers lift, slowing exponentially, as a scroll does on the
    /// Mac. Screen space throughout: the content moves the same distance on screen at any zoom.
    struct PanCoast: Equatable {
        /// Slower than this on screen (points per second) and the pan just stops.
        static let threshold: CGFloat = 120
        /// Time constant of the slow-down. Close to the Mac's own scroll momentum.
        static let decay: CGFloat = 0.42
        /// The coast is over once it has slowed to this.
        static let stop: CGFloat = 12

        /// Screen points per second when the fingers lifted.
        let velocity: CGVector
        let start: CFTimeInterval

        /// Nil when the hand was moving too slowly to matter.
        init?(velocity: CGVector, at start: CFTimeInterval) {
            guard hypot(velocity.dx, velocity.dy) >= PanCoast.threshold else { return nil }
            self.velocity = velocity
            self.start = start
        }

        /// How far the content moves on screen between two moments: the integral of v·e^(−t/τ).
        func travel(from a: CFTimeInterval, to b: CFTimeInterval) -> CGVector {
            let τ = PanCoast.decay
            let ta = max(0, CGFloat(a - start)), tb = max(0, CGFloat(b - start))
            let f = τ * (exp(-ta / τ) - exp(-tb / τ))
            return CGVector(dx: velocity.dx * f, dy: velocity.dy * f)
        }

        /// The speed `t` seconds in.
        func speed(at time: CFTimeInterval) -> CGFloat {
            hypot(velocity.dx, velocity.dy) * exp(-max(0, CGFloat(time - start)) / PanCoast.decay)
        }

        func isOver(at time: CFTimeInterval) -> Bool { speed(at: time) < PanCoast.stop }
    }

    /// A pinch's last bit of motion carried on for a moment: the zoom keeps changing about the same
    /// point, slowing fast. Short on purpose; a long tail makes a pinch feel loose.
    struct ZoomCoast: Equatable {
        /// In log-zoom per second: slower than this and the pinch just stops.
        static let threshold: CGFloat = 0.8
        static let decay: CGFloat = 0.12
        static let stop: CGFloat = 0.05

        /// Log-zoom per second when the fingers lifted.
        let velocity: CGFloat
        let anchor: CGPoint
        let start: CFTimeInterval

        init?(velocity: CGFloat, anchor: CGPoint, at start: CFTimeInterval) {
            guard abs(velocity) >= ZoomCoast.threshold else { return nil }
            self.velocity = velocity
            self.anchor = anchor
            self.start = start
        }

        /// The factor to zoom by between two moments.
        func factor(from a: CFTimeInterval, to b: CFTimeInterval) -> CGFloat {
            let τ = ZoomCoast.decay
            let ta = max(0, CGFloat(a - start)), tb = max(0, CGFloat(b - start))
            return exp(velocity * τ * (exp(-ta / τ) - exp(-tb / τ)))
        }

        /// The zoom it will have reached when it stops, from `zoom` now: what a handoff check needs.
        func end(from zoom: CGFloat, at time: CFTimeInterval) -> CGFloat {
            zoom * factor(from: time, to: .infinity)
        }

        func isOver(at time: CFTimeInterval) -> Bool {
            abs(velocity) * exp(-max(0, CGFloat(time - start)) / ZoomCoast.decay) < ZoomCoast.stop
        }
    }

    /// A scalar's speed, smoothed over the last few samples: the pinch's log-zoom.
    struct ScalarVelocity {
        static let window: CGFloat = 0.05
        static let stale: CGFloat = 0.08

        private(set) var value: CGFloat = 0
        private var last: (x: CGFloat, time: CFTimeInterval)?

        mutating func add(_ x: CGFloat, at time: CFTimeInterval) {
            defer { last = (x, time) }
            guard let last, time > last.time else { return }
            let dt = CGFloat(time - last.time)
            let instant = (x - last.x) / dt
            let a = 1 - exp(-dt / ScalarVelocity.window)
            value += a * (instant - value)
        }

        /// Zero if the fingers had been still for a moment before lifting.
        func release(at time: CFTimeInterval) -> CGFloat {
            guard let last, CGFloat(time - last.time) < ScalarVelocity.stale else { return 0 }
            return value
        }
    }
}
