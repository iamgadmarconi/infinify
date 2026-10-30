import XCTest
import CoreGraphics
@testable import Canvas

final class MotionTests: XCTestCase {
    private let clamp: (CGFloat) -> CGFloat = { min(1, max(0.04, $0)) }

    // MARK: Pending input

    func testPansSumAndMoveTheContentOnScreen() {
        var input = Motion.PendingInput()
        input.addPan(CGVector(dx: 10, dy: 0))
        input.addPan(CGVector(dx: 5, dy: -20))
        XCTAssertEqual(input.events, 2)
        let camera = input.applied(to: Camera(origin: CGPoint(x: 100, y: 100), zoom: 0.5), clamp: clamp)
        // 15 pt right on screen is 30 world units at half zoom; the origin moves the other way.
        XCTAssertEqual(camera.origin.x, 70, accuracy: 1e-9)
        XCTAssertEqual(camera.origin.y, 140, accuracy: 1e-9)
        XCTAssertEqual(camera.zoom, 0.5)
    }

    func testZoomHoldsItsAnchorStill() {
        var input = Motion.PendingInput()
        let anchor = CGPoint(x: 300, y: 200)
        let before = Camera(origin: CGPoint(x: 50, y: 20), zoom: 0.5)
        let world = before.toWorld(anchor)
        input.addZoom(by: 1.5, around: anchor)
        input.addZoom(by: 1.2, around: anchor)
        let after = input.applied(to: before, clamp: clamp)
        XCTAssertEqual(after.zoom, 0.9, accuracy: 1e-9)
        let back = after.toScreen(world)
        XCTAssertEqual(back.x, anchor.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, anchor.y, accuracy: 1e-6)
    }

    func testClampedZoomStillHoldsTheAnchor() {
        var input = Motion.PendingInput()
        let anchor = CGPoint(x: 10, y: 10)
        let before = Camera(origin: .zero, zoom: 0.9)
        let world = before.toWorld(anchor)
        input.addZoom(by: 4, around: anchor)
        let after = input.applied(to: before, clamp: clamp)
        XCTAssertEqual(after.zoom, 1)
        XCTAssertEqual(after.toScreen(world).x, anchor.x, accuracy: 1e-6)
    }

    func testAPanBeforeAZoomIsStillAScreenMove() {
        // Gathered pan, then zoom, in one frame: the content ends up moved by the pan on screen at the
        // new zoom, as it would have been had the two been applied in turn.
        var input = Motion.PendingInput()
        input.addPan(CGVector(dx: 40, dy: 0))
        input.addZoom(by: 2, around: CGPoint(x: 100, y: 100))
        let before = Camera(origin: .zero, zoom: 0.25)
        let after = input.applied(to: before, clamp: clamp)
        var step = Motion.PendingInput()
        step.addZoom(by: 2, around: CGPoint(x: 100, y: 100))
        var zoomed = step.applied(to: before, clamp: clamp)
        zoomed.origin.x -= 40 / zoomed.zoom
        XCTAssertEqual(after.origin.x, zoomed.origin.x, accuracy: 1e-9)
        XCTAssertEqual(after.zoom, zoomed.zoom, accuracy: 1e-9)
    }

    func testEmptyInputChangesNothing() {
        let camera = Camera(origin: CGPoint(x: 3, y: 4), zoom: 0.3)
        XCTAssertTrue(Motion.PendingInput().isEmpty)
        XCTAssertEqual(Motion.PendingInput().applied(to: camera, clamp: clamp), camera)
    }

    // MARK: Pan coast

    func testSlowReleaseDoesNotCoast() {
        XCTAssertNil(Motion.PanCoast(velocity: CGVector(dx: 50, dy: 50), at: 0))
        XCTAssertNotNil(Motion.PanCoast(velocity: CGVector(dx: 500, dy: 0), at: 0))
    }

    func testCoastTravelsVelocityTimesDecayInAll() {
        let c = Motion.PanCoast(velocity: CGVector(dx: 1000, dy: -400), at: 10)!
        let whole = c.travel(from: 10, to: 100)
        XCTAssertEqual(whole.dx, 1000 * Motion.PanCoast.decay, accuracy: 1e-6)
        XCTAssertEqual(whole.dy, -400 * Motion.PanCoast.decay, accuracy: 1e-6)
        // Piecewise is the same as whole.
        let a = c.travel(from: 10, to: 10.1), b = c.travel(from: 10.1, to: 100)
        XCTAssertEqual(a.dx + b.dx, whole.dx, accuracy: 1e-6)
        // The first slice is the fastest.
        XCTAssertGreaterThan(a.dx, c.travel(from: 10.1, to: 10.2).dx)
    }

    func testCoastEndsOnceSlow() {
        let c = Motion.PanCoast(velocity: CGVector(dx: 1200, dy: 0), at: 0)!
        XCTAssertFalse(c.isOver(at: 0.5))
        XCTAssertTrue(c.isOver(at: 5))
        XCTAssertEqual(c.speed(at: 0), 1200, accuracy: 1e-9)
    }

    // MARK: Zoom coast

    func testZoomTailMultipliesToItsEnd() {
        let z = Motion.ZoomCoast(velocity: 2, anchor: .zero, at: 0)!
        let end = z.end(from: 0.5, at: 0)
        XCTAssertEqual(end, 0.5 * exp(2 * Motion.ZoomCoast.decay), accuracy: 1e-9)
        let f1 = z.factor(from: 0, to: 0.05), f2 = z.factor(from: 0.05, to: 10)
        XCTAssertEqual(0.5 * f1 * f2, end, accuracy: 1e-6)
        XCTAssertTrue(z.isOver(at: 2))
        XCTAssertNil(Motion.ZoomCoast(velocity: 0.1, anchor: .zero, at: 0))
    }

    // MARK: Settings

    func testInertiaIsOnByDefaultAndEachSwitchRoundTrips() async {
        await MainActor.run {
            let defaults = UserDefaults.standard
            let pan = defaults.object(forKey: "CanvasPanInertia"), zoom = defaults.object(forKey: "CanvasZoomInertia")
            defer {
                defaults.set(pan, forKey: "CanvasPanInertia")
                defaults.set(zoom, forKey: "CanvasZoomInertia")
            }
            defaults.removeObject(forKey: "CanvasPanInertia")
            defaults.removeObject(forKey: "CanvasZoomInertia")
            XCTAssertTrue(Settings.panInertia)
            XCTAssertTrue(Settings.zoomInertia)
            Settings.panInertia = false
            XCTAssertFalse(Settings.panInertia)
            XCTAssertTrue(Settings.zoomInertia, "separate switches")
            Settings.zoomInertia = false
            XCTAssertFalse(Settings.zoomInertia)
        }
    }

    // MARK: Velocity

    func testScalarVelocityReadsSteadyMotionAndGoesStale() {
        var v = Motion.ScalarVelocity()
        for i in 0...20 { v.add(CGFloat(i) * 0.1, at: Double(i) * 0.01) }   // 10 units per second
        XCTAssertEqual(v.release(at: 0.21), 10, accuracy: 0.5)
        XCTAssertEqual(v.release(at: 0.5), 0)   // the fingers had stopped
    }
}
