import XCTest
import CoreGraphics
@testable import Canvas

final class CameraTests: XCTestCase {
    func testCloseWithinAPixelOnScreen() {
        let a = Camera(origin: CGPoint(x: 100, y: 200), zoom: 1)
        XCTAssertTrue(a.isClose(to: Camera(origin: CGPoint(x: 100.4, y: 199.6), zoom: 1)))
        XCTAssertFalse(a.isClose(to: Camera(origin: CGPoint(x: 101.5, y: 200), zoom: 1)))
        XCTAssertFalse(a.isClose(to: Camera(origin: CGPoint(x: 100, y: 200), zoom: 0.9)))
    }

    func testZoomedOutAWorldPointIsLessThanAPixel() {
        let a = Camera(origin: .zero, zoom: 0.25)
        XCTAssertTrue(a.isClose(to: Camera(origin: CGPoint(x: 3, y: 0), zoom: 0.25)))
        XCTAssertFalse(a.isClose(to: Camera(origin: CGPoint(x: 5, y: 0), zoom: 0.25)))
    }
}
