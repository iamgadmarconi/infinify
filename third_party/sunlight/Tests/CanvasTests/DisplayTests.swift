import XCTest
import CoreGraphics
@testable import Canvas

final class DisplayTests: XCTestCase {
    private func display(_ frame: CGRect, visible: CGRect? = nil) -> Display {
        Display(id: 1, uuid: "u", name: "d", frame: frame, visible: visible ?? frame, cocoaFrame: frame, scale: 2)
    }

    func testQuartzFlipsAroundThePrimaryHeight() {
        // A 1920×1080 display above a 1512×982 primary, its left edge 200 pt in.
        let above = Display.quartz(CGRect(x: 200, y: 982, width: 1920, height: 1080), primaryHeight: 982)
        XCTAssertEqual(above, CGRect(x: 200, y: -1080, width: 1920, height: 1080))
        let primary = Display.quartz(CGRect(x: 0, y: 0, width: 1512, height: 982), primaryHeight: 982)
        XCTAssertEqual(primary, CGRect(x: 0, y: 0, width: 1512, height: 982))
    }

    func testVisibleInViewAndTopInset() {
        let d = display(CGRect(x: 1512, y: -200, width: 2560, height: 1440),
                        visible: CGRect(x: 1512, y: -175, width: 2560, height: 1415))
        XCTAssertEqual(d.visibleInView, CGRect(x: 0, y: 25, width: 2560, height: 1415))
        XCTAssertEqual(d.topInset, 25)
    }

    func testIndexPicksTheCentreThenTheOverlapThenTheNearest() {
        let displays = [display(CGRect(x: 0, y: 0, width: 1000, height: 800)),
                        display(CGRect(x: 1000, y: 0, width: 1000, height: 800))]
        XCTAssertEqual(Display.index(for: CGRect(x: 900, y: 100, width: 400, height: 300), in: displays), 1)
        XCTAssertEqual(Display.index(for: CGRect(x: 700, y: 100, width: 400, height: 300), in: displays), 0)
        // Centre below both, mostly over the second.
        XCTAssertEqual(Display.index(for: CGRect(x: 1100, y: 700, width: 400, height: 300), in: displays), 1)
        // Nowhere near either: the nearest.
        XCTAssertEqual(Display.index(for: CGPoint(x: 2500, y: 400), in: displays), 1)
        XCTAssertNil(Display.index(for: CGPoint.zero, in: []))
    }

    func testGlobalCameraMapsTheViewToGlobalPoints() {
        let o = CGPoint(x: 1512, y: -200)
        let view = Camera(origin: CGPoint(x: 300, y: 50), zoom: 0.5)
        let global = view.global(viewOrigin: o)
        let world = CGPoint(x: 900, y: 650)
        let inView = view.toScreen(world)
        let inGlobal = global.toScreen(world)
        XCTAssertEqual(inGlobal.x, inView.x + o.x, accuracy: 1e-9)
        XCTAssertEqual(inGlobal.y, inView.y + o.y, accuracy: 1e-9)
        XCTAssertEqual(global.toWorld(inGlobal).x, world.x, accuracy: 1e-9)
    }

    func testHomeCameraShowsTheDisplayAtOneToOne() {
        let o = CGPoint(x: -1920, y: 0)
        let home = Camera.home(viewOrigin: o)
        // A window at global (-1800, 100) sits at view (120, 100), and its world rect is where it is.
        XCTAssertEqual(home.toScreen(CGPoint(x: -1800, y: 100)), CGPoint(x: 120, y: 100))
        XCTAssertEqual(home.global(viewOrigin: o).toScreen(CGPoint(x: -1800, y: 100)), CGPoint(x: -1800, y: 100))
    }
}
