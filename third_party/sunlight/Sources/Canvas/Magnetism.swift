import CoreGraphics
import QuartzCore

/// Windows pushing each other out of the way on the canvas: Settings › Windows › "Windows push each
/// other". A window being dragged or resized is fixed where the hand holds it; the others are shoved out
/// of its way along the shortest route, and shove the ones behind them in turn. World coordinates
/// throughout (top-left origin, points), except where a value is said to be on screen.
///
/// Two layers keep it both exact and smooth. `resolve` produces a *target* layout with nothing
/// overlapping, afresh from the current rects on every pointer move, so it can never tunnel or drift.
/// `Follow` then eases each pushed window's displayed rect to its target without overshoot, and `Coast`
/// lets a window flung hard keep going a little when it's let go. Both are purely visual: the targets
/// are always a good layout on their own.
///
/// With magnetic polarity on (`Polarity`), what moves are *bodies*: a window on its own, or a group
/// bonded into one rigid piece. Like poles push as above; an opposite pole within reach of the hand is
/// pulled in to the gap instead (`attachment`), and holds there as if part of the hand.
enum Magnetism {
    /// What the Gentle…Firm slider (0…1) sets: how far before touching a push starts (and so the gap
    /// pushed windows are left at), and how quickly they respond.
    struct Strength: Equatable {
        let value: CGFloat
        init(_ value: CGFloat) { self.value = max(0, min(1, value)) }

        /// Gentle pushes only on contact; Firm starts a full tile gap out, so a drag through a cluster
        /// leaves it spaced like a tiled layout.
        func reach(gap: CGFloat) -> CGFloat { gap * value }

        /// Time for a pushed window to cover most of the way to its target (see `Follow`): 0.30 s at
        /// Gentle, 0.12 s at Firm.
        var response: CGFloat { 0.30 - 0.18 * value }
    }

    /// The layout `resolve` settled on: `rects` in the order they were given, and which of them moved.
    struct Resolution: Equatable {
        var rects: [CGRect]
        var moved: Set<Int>
    }

    /// Passes over the pairs before giving up; one to three settle every layout met in practice.
    static let maxPasses = 12
    /// A pass that moves nothing further than this is the last one.
    static let tolerance: CGFloat = 0.1
    /// Edges closer than this are touching, not overlapping.
    private static let epsilon: CGFloat = 1e-6

    // MARK: Bodies

    /// A rigid set of windows: a group bonded by polarity (`Grouping`), or one window on its own.
    /// `poles[i]` is `rects[i]`'s pole; nil for a widget, or with polarity off.
    struct Body: Equatable {
        var rects: [CGRect]
        var poles: [Polarity?]

        init(_ rect: CGRect, pole: Polarity? = nil) {
            rects = [rect]
            poles = [pole]
        }

        init(rects: [CGRect], poles: [Polarity?]) {
            precondition(rects.count == poles.count, "a pole per rect")
            self.rects = rects
            self.poles = poles
        }

        /// The union of the members.
        var bounds: CGRect {
            guard let first = rects.first else { return .null }
            return rects.dropFirst().reduce(first) { $0.union($1) }
        }

        func offsetBy(_ v: CGVector) -> Body {
            Body(rects: rects.map { $0.offsetBy(dx: v.dx, dy: v.dy) }, poles: poles)
        }

        /// Whether a member of each overlaps (touching doesn't count).
        func overlaps(_ other: Body) -> Bool {
            rects.contains { r in other.rects.contains { Magnetism.overlap(r, $0) } }
        }
    }

    /// Opposite poles pulling together: the pull starts once they're within `reach` of each other and
    /// leaves them `gap` apart — the push reach, so a bonded pair sits exactly as a pushed one does, and
    /// there's one spacing for everything. World points.
    struct Attraction: Equatable {
        var reach: CGFloat
        var gap: CGFloat
    }

    /// What `resolve` settled on for bodies: how far each moved (as one piece), which moved, and which
    /// the hand is pulling. A pulled body is held at the gap as if part of the hand: nothing shoves it,
    /// and it bonds when it gets there.
    struct BodyResolution: Equatable {
        var offsets: [CGVector]
        var moved: Set<Int>
        var pulled: Set<Int>
    }

    /// Pushes `others` out of `fixed`'s way. `fixed` never moves. Each rect it overlaps (after growing
    /// `fixed` by `reach` on every side) leaves along the axis where the overlap is smaller, by exactly
    /// the overlap, keeping its other coordinate: rows stay rows and columns stay columns. A rect that
    /// moved pushes any it now reaches in the same way, nearer ones pushing farther ones, until nothing
    /// overlaps. Two rects that already overlapped before the call (a stack the user made) are left to
    /// each other: a push never explodes a pile, only moves what's in the way.
    static func resolve(fixed: CGRect, others: [CGRect], reach: CGFloat) -> Resolution {
        let r = resolve(fixed: Body(fixed), others: others.map { Body($0) }, reach: reach)
        return Resolution(rects: zip(others, r.offsets).map { $0.offsetBy(dx: $1.dx, dy: $1.dy) }, moved: r.moved)
    }

    /// The same for bodies, with polarity. Every pass first finds who the hand pulls: an opposite pole
    /// within `attraction.reach` of one of the hand's windows goes to the gap (`attachment`) and is held
    /// there. Everything else is pushed out of the hand *and* what it holds, as one wall (a window caught
    /// between the two has to go sideways, not back and forth), and then pushes what's behind it. A
    /// pulled body is never shoved: the hand has it. Without `attraction`, every pole is neutral.
    static func resolve(fixed: Body, others: [Body], reach: CGFloat, attraction: Attraction? = nil) -> BodyResolution {
        var offsets = [CGVector](repeating: .zero, count: others.count)
        var moved = Set<Int>()
        var pulled = Set<Int>()
        guard !others.isEmpty, !fixed.rects.isEmpty else { return BodyResolution(offsets: offsets, moved: moved, pulled: pulled) }
        var bodies = others
        let reach = max(0, reach)
        // Nearest to the hand first: the push travels outwards.
        let hand = fixed.bounds
        let order = others.indices.sorted {
            distance(others[$0].bounds, hand) < distance(others[$1].bounds, hand)
        }
        // Pairs that were on top of each other to begin with stay that way.
        var stacked = Set<Int>()
        for i in others.indices {
            for j in others.indices where j > i && others[i].overlaps(others[j]) {
                stacked.insert(i * others.count + j)
            }
        }
        func areStacked(_ i: Int, _ j: Int) -> Bool { stacked.contains(min(i, j) * others.count + max(i, j)) }
        func shift(_ i: Int, by d: CGVector, _ largest: inout CGFloat) {
            bodies[i] = bodies[i].offsetBy(d)
            offsets[i] = CGVector(dx: offsets[i].dx + d.dx, dy: offsets[i].dy + d.dy)
            moved.insert(i)
            largest = max(largest, abs(d.dx), abs(d.dy))
        }

        for _ in 0..<maxPasses {
            var largest: CGFloat = 0
            // Who the hand pulls, and where to.
            pulled = []
            if let a = attraction {
                for i in order {
                    guard let pull = attachment(of: bodies[i], to: fixed, a, clearOf: reach) else { continue }
                    pulled.insert(i)
                    if pull != .zero { shift(i, by: pull, &largest) }
                }
            }
            // The hand and what it holds, one wall everyone else is clear of.
            var wall = fixed
            for i in pulled {
                wall.rects += bodies[i].rects
                wall.poles += bodies[i].poles
            }
            for i in order where !pulled.contains(i) {
                let d = displacement(of: bodies[i], outOf: wall, reach: reach)
                if d != .zero { shift(i, by: d, &largest) }
            }
            // What moved shoves what's behind it, except what the hand holds.
            for i in order where moved.contains(i) {
                for j in order where j != i && !pulled.contains(j) && !areStacked(i, j) {
                    let d = displacement(of: bodies[j], outOf: bodies[i], reach: reach)
                    guard d != .zero else { continue }
                    shift(j, by: d, &largest)
                }
            }
            if largest < tolerance { break }
        }
        return BodyResolution(offsets: offsets, moved: moved, pulled: pulled)
    }

    /// How far `body` has to move, as one piece, to be clear of `pusher` grown by `reach`: along the axis
    /// that takes less, away from the pusher. The axis and the way come from the two bodies' bounds, as
    /// for single rects; the distance is what the deepest of the members actually in the way needs. Zero
    /// when no member is in the way — a window in the notch of an L is left alone, though the L's bounds
    /// cover it.
    static func displacement(of body: Body, outOf pusher: Body, reach: CGFloat) -> CGVector {
        let grown = pusher.rects.map { $0.insetBy(dx: -reach, dy: -reach) }
        var right: CGFloat = 0, left: CGFloat = 0, down: CGFloat = 0, up: CGFloat = 0
        var inTheWay = false
        for r in body.rects {
            for p in grown where overlap(r, p) {
                inTheWay = true
                right = max(right, p.maxX - r.minX)
                left = max(left, r.maxX - p.minX)
                down = max(down, p.maxY - r.minY)
                up = max(up, r.maxY - p.minY)
            }
        }
        guard inTheWay else { return .zero }
        let b = body.bounds, p = pusher.bounds.insetBy(dx: -reach, dy: -reach)
        let dx = b.midX >= p.midX ? right : -left
        let dy = b.midY >= p.midY ? down : -up
        return abs(dx) <= abs(dy) ? CGVector(dx: dx, dy: 0) : CGVector(dx: 0, dy: dy)
    }

    /// Where `r` goes to sit `gap` from `fixed`, if the two are within `reach` of each other: in, when
    /// they're apart; out along the shorter way, when they're on top of each other. They have to face
    /// each other — side by side, or one above the other — and `r` keeps its other coordinate, so it
    /// arrives lined up as it came. Nil corner to corner, or further than `reach` apart.
    static func attach(_ r: CGRect, to fixed: CGRect, gap: CGFloat, reach: CGFloat) -> CGVector? {
        // How far each has to go to be clear on that axis; negative: how far apart they already are.
        let exitX = min(fixed.maxX - r.minX, r.maxX - fixed.minX)
        let exitY = min(fixed.maxY - r.minY, r.maxY - fixed.minY)
        if exitX > epsilon, exitY > epsilon {
            if exitX <= exitY {
                return CGVector(dx: r.midX >= fixed.midX ? exitX + gap : -(exitX + gap), dy: 0)
            }
            return CGVector(dx: 0, dy: r.midY >= fixed.midY ? exitY + gap : -(exitY + gap))
        }
        if exitY > epsilon {
            let apart = -exitX
            guard apart <= reach else { return nil }
            return CGVector(dx: r.midX >= fixed.midX ? gap - apart : apart - gap, dy: 0)
        }
        if exitX > epsilon {
            let apart = -exitY
            guard apart <= reach else { return nil }
            return CGVector(dx: 0, dy: r.midY >= fixed.midY ? gap - apart : apart - gap)
        }
        return nil
    }

    /// How far `body` moves, as one piece, to attach to `fixed`: the nearest pair of its members and the
    /// hand's with opposite poles that `attach` accepts. Nil if there's none, or if where it would sit is
    /// on another of the hand's windows (grown by the push `reach`): a ragged group would otherwise pull
    /// it in and shove it out by turns. The window it attaches to is allowed to be closer than `reach`.
    static func attachment(of body: Body, to fixed: Body, _ a: Attraction, clearOf reach: CGFloat) -> CGVector? {
        var best: (vector: CGVector, partner: Int)?
        var bestTravel = CGFloat.infinity
        for (i, r) in body.rects.enumerated() {
            for (j, f) in fixed.rects.enumerated() where Polarity.relation(body.poles[i], fixed.poles[j]) == .attract {
                guard let v = attach(r, to: f, gap: a.gap, reach: a.reach) else { continue }
                let travel = hypot(v.dx, v.dy)
                if travel < bestTravel {
                    best = (v, j)
                    bestTravel = travel
                }
            }
        }
        guard let best else { return nil }
        let placed = body.offsetBy(best.vector)
        for (j, f) in fixed.rects.enumerated() where j != best.partner {
            let grown = f.insetBy(dx: -reach, dy: -reach)
            if placed.rects.contains(where: { overlap($0, grown) }) { return nil }
        }
        return best.vector
    }

    /// Whether two windows sit together: side by side or one above the other, no more than `gap` apart
    /// (half a point of slack), or on top of each other. What keeps a group in one piece
    /// (`Grouping.split`).
    static func adjacent(_ a: CGRect, _ b: CGRect, within gap: CGFloat) -> Bool {
        let exitX = min(a.maxX - b.minX, b.maxX - a.minX)
        let exitY = min(a.maxY - b.minY, b.maxY - a.minY)
        if exitX > epsilon, exitY > epsilon { return true }
        if exitY > epsilon { return -exitX <= gap + 0.5 }
        if exitX > epsilon { return -exitY <= gap + 0.5 }
        return false
    }

    /// The gap between two windows that face each other, as a line across it midway along their shared
    /// span: what the canvas draws while the hand pulls one in. Nil if they don't face each other, or
    /// are on top of each other.
    static func gapLine(between a: CGRect, and b: CGRect) -> (from: CGPoint, to: CGPoint)? {
        let exitX = min(a.maxX - b.minX, b.maxX - a.minX)
        let exitY = min(a.maxY - b.minY, b.maxY - a.minY)
        if exitX > epsilon, exitY > epsilon { return nil }
        if exitY > epsilon {
            let y = (max(a.minY, b.minY) + min(a.maxY, b.maxY)) / 2
            let (left, right) = a.midX <= b.midX ? (a, b) : (b, a)
            return (CGPoint(x: left.maxX, y: y), CGPoint(x: right.minX, y: y))
        }
        if exitX > epsilon {
            let x = (max(a.minX, b.minX) + min(a.maxX, b.maxX)) / 2
            let (top, bottom) = a.midY <= b.midY ? (a, b) : (b, a)
            return (CGPoint(x: x, y: top.maxY), CGPoint(x: x, y: bottom.minY))
        }
        return nil
    }

    /// Overlap with some area to it; edges that merely touch don't count.
    private static func overlap(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxX, b.maxX) - max(a.minX, b.minX) > epsilon && min(a.maxY, b.maxY) - max(a.minY, b.minY) > epsilon
    }

    /// How far `r` has to move to be clear of `pusher` grown by `reach`: along the axis with the smaller
    /// overlap, away from the pusher's centre. Zero when they're already clear.
    static func displacement(of r: CGRect, outOf pusher: CGRect, reach: CGFloat) -> CGVector {
        let p = pusher.insetBy(dx: -reach, dy: -reach)
        let overlapX = min(p.maxX - r.minX, r.maxX - p.minX)
        let overlapY = min(p.maxY - r.minY, r.maxY - p.minY)
        guard overlapX > 1e-6, overlapY > 1e-6 else { return .zero }
        if overlapX <= overlapY {
            return CGVector(dx: r.midX >= p.midX ? overlapX : -overlapX, dy: 0)
        } else {
            return CGVector(dx: 0, dy: r.midY >= p.midY ? overlapY : -overlapY)
        }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    // MARK: Follow

    /// A pushed window's displayed origin on its way to the target: a critically damped spring, so it
    /// arrives without a bounce. `response` is roughly the time to cover 90 % of the way.
    struct Follow: Equatable {
        var position: CGPoint
        var velocity: CGVector = .zero

        /// Within this of the target and this slow, it has arrived.
        static let restDistance: CGFloat = 0.5
        static let restSpeed: CGFloat = 5

        /// `dt` seconds on, heading for `target`. Closed form, so a long or uneven frame can't make it
        /// unstable. A `response` of zero (Reduce Motion) goes straight there.
        mutating func step(toward target: CGPoint, dt: CGFloat, response: CGFloat) {
            guard response > 0, dt > 0 else {
                position = target
                velocity = .zero
                return
            }
            let ω = 4 / response   // (1 + ωt)·e^(−ωt) is under a tenth once ωt reaches 4
            let decay = exp(-ω * dt)
            func axis(_ x0: CGFloat, _ v0: CGFloat) -> (x: CGFloat, v: CGFloat) {
                let b = v0 + ω * x0
                let x = (x0 + b * dt) * decay
                let v = (b - ω * (x0 + b * dt)) * decay
                return (x, v)
            }
            let x = axis(position.x - target.x, velocity.dx)
            let y = axis(position.y - target.y, velocity.dy)
            position = CGPoint(x: target.x + x.x, y: target.y + y.x)
            velocity = CGVector(dx: x.v, dy: y.v)
        }

        func isAtRest(at target: CGPoint) -> Bool {
            hypot(position.x - target.x, position.y - target.y) < Follow.restDistance
                && hypot(velocity.dx, velocity.dy) < Follow.restSpeed
        }
    }

    // MARK: Inertia

    /// The pointer's speed over the last few samples, on screen, so the feel doesn't change with the
    /// zoom. An exponential average over about `window` seconds: steady enough to ignore jitter,
    /// short enough to report the last flick.
    struct Velocity {
        static let window: CGFloat = 0.05
        /// A pause longer than this before letting go means the hand had stopped: no coast.
        static let stale: CGFloat = 0.08

        private(set) var value: CGVector = .zero
        private var last: (point: CGPoint, time: CFTimeInterval)?

        mutating func add(_ point: CGPoint, at time: CFTimeInterval) {
            defer { last = (point, time) }
            guard let last, time > last.time else { return }
            let dt = CGFloat(time - last.time)
            let instant = CGVector(dx: (point.x - last.point.x) / dt, dy: (point.y - last.point.y) / dt)
            let a = 1 - exp(-dt / Velocity.window)
            value = CGVector(dx: value.dx + a * (instant.dx - value.dx), dy: value.dy + a * (instant.dy - value.dy))
        }

        /// The speed to let go with: zero if the pointer had been still for a moment.
        func release(at time: CFTimeInterval) -> CGVector {
            guard let last, CGFloat(time - last.time) < Velocity.stale else { return .zero }
            return value
        }
    }

    /// A window let go while moving fast keeps going, slowing exponentially: a little, never far.
    struct Coast: Equatable {
        /// Slower than this on screen and it just drops.
        static let threshold: CGFloat = 1200
        /// Time constant of the slow-down. The window has all but stopped after five of these.
        static let decay: CGFloat = 0.18
        /// The whole coast is no longer than this on screen…
        static let cap: CGFloat = 160
        /// …nor than this fraction of the window's own width.
        static let widthFraction: CGFloat = 0.25

        let origin: CGPoint
        /// World points per second, already scaled so the coast ends within the cap.
        let velocity: CGVector
        let start: CFTimeInterval

        /// Nil when the hand was moving too slowly to matter. `screenVelocity` is in screen points per
        /// second; `zoom` converts it and the cap to the world; `width` is the window's, in the world.
        init?(from origin: CGPoint, screenVelocity v: CGVector, zoom: CGFloat, width: CGFloat, at start: CFTimeInterval) {
            let speed = hypot(v.dx, v.dy)
            guard speed >= Coast.threshold, zoom > 0 else { return nil }
            let allowed = min(Coast.cap / zoom, width * Coast.widthFraction)
            let full = speed / zoom * Coast.decay   // where v·τ would take it
            let scale = (full > allowed ? allowed / full : 1) / zoom
            self.origin = origin
            self.velocity = CGVector(dx: v.dx * scale, dy: v.dy * scale)
            self.start = start
        }

        /// Where it is `t` seconds in: v·τ·(1 − e^(−t/τ)) along.
        func position(at time: CFTimeInterval) -> CGPoint {
            let t = max(0, CGFloat(time - start))
            let f = Coast.decay * (1 - exp(-t / Coast.decay))
            return CGPoint(x: origin.x + velocity.dx * f, y: origin.y + velocity.dy * f)
        }

        /// Where it stops.
        var end: CGPoint {
            CGPoint(x: origin.x + velocity.dx * Coast.decay, y: origin.y + velocity.dy * Coast.decay)
        }

        func isOver(at time: CFTimeInterval) -> Bool {
            CGFloat(time - start) >= 5 * Coast.decay
        }
    }
}
