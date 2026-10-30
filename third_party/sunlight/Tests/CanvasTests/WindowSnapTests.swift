import XCTest
import CoreGraphics
@testable import Canvas

final class WindowSnapTests: XCTestCase {
    // A 1512×982 display with a 33 pt menu bar.
    let view = CGSize(width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 33, width: 1512, height: 949)
    // A full screen window somewhere on the canvas, entered on the visible area.
    let full = WindowSnap.Window(rect: CGRect(x: 3000, y: 500, width: 1512, height: 949), spot: CGPoint(x: 0, y: 33))
    var aligned: Camera { Camera(origin: CGPoint(x: 3000, y: 467), zoom: 1) }

    func testNearlyAlignedSnapsExactly() {
        let near = Camera(origin: CGPoint(x: 3030, y: 450), zoom: 1)
        let hit = WindowSnap.target(camera: near, viewSize: view, visible: visible, windows: [full])
        XCTAssertEqual(hit?.index, 0)
        XCTAssertEqual(hit?.camera, aligned)
    }

    func testNearlyOneToOneSnaps() {
        // 96 %, centred on the window: each edge is about 30 pt in.
        let near = Camera(center: aligned.center(viewSize: view), zoom: 0.96, viewSize: view)
        XCTAssertEqual(WindowSnap.target(camera: near, viewSize: view, visible: visible, windows: [full])?.camera, aligned)
    }

    func testTooFarOrTooZoomedOutStays() {
        let off = Camera(origin: CGPoint(x: 3200, y: 467), zoom: 1)
        XCTAssertNil(WindowSnap.target(camera: off, viewSize: view, visible: visible, windows: [full]))
        let out = Camera(center: aligned.center(viewSize: view), zoom: 0.8, viewSize: view)
        XCTAssertNil(WindowSnap.target(camera: out, viewSize: view, visible: visible, windows: [full]))
    }

    func testSmallWindowsNeverSnap() {
        let small = WindowSnap.Window(rect: CGRect(x: 3000, y: 500, width: 900, height: 700), spot: CGPoint(x: 306, y: 157))
        let near = Camera(origin: CGPoint(x: 3000 - 300, y: 500 - 150), zoom: 1)
        XCTAssertNil(WindowSnap.target(camera: near, viewSize: view, visible: visible, windows: [small]))
    }

    func testClosestWins() {
        let other = WindowSnap.Window(rect: CGRect(x: 3060, y: 500, width: 1512, height: 949), spot: CGPoint(x: 0, y: 33))
        let near = Camera(origin: CGPoint(x: 3050, y: 467), zoom: 1)
        XCTAssertEqual(WindowSnap.target(camera: near, viewSize: view, visible: visible, windows: [full, other])?.index, 1)
    }

    func testNudgeSpringIsQuickWithLittleOvershoot() {
        let s = Spring(x0: -1, v0: 0, response: WindowSnap.response, damping: WindowSnap.damping)
        var peak: CGFloat = -1
        for i in 0...200 { peak = max(peak, s.evaluate(at: CGFloat(i) * 0.005).x) }
        XCTAssertLessThan(peak, 0.02)                         // under 2 % past the window
        XCTAssertLessThan(abs(s.evaluate(at: 0.3).x), 0.01)   // there within 0.3 s
    }
}
