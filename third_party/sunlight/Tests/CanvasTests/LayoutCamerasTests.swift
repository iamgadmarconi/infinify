import XCTest
import CoreGraphics
@testable import Canvas

final class LayoutCamerasTests: XCTestCase {
    private func layout(cameras: [String: Layout.DisplayCamera]? = nil) -> Layout {
        var l = Layout(name: "", saved: Date(timeIntervalSince1970: 0), center: .init(x: 500, y: 400), zoom: 0.5, entries: [])
        l.cameras = cameras
        return l
    }

    @MainActor
    func testEachDisplayHasItsOwnCameraAndTheLeadFallsBackToTheMainOne() {
        let size = CGSize(width: 1000, height: 800)
        let side = Layout.DisplayCamera(center: .init(x: 2500, y: 300), zoom: 0.25)
        let l = layout(cameras: ["SIDE": side])
        let own = l.camera(for: "SIDE", lead: false, viewSize: size)
        XCTAssertEqual(own?.zoom, 0.25)
        XCTAssertEqual(own?.center(viewSize: size), CGPoint(x: 2500, y: 300))
        // From before there was a camera per display: the lead takes the main one, another display none.
        XCTAssertEqual(l.camera(for: "MAIN", lead: true, viewSize: size)?.center(viewSize: size), CGPoint(x: 500, y: 400))
        XCTAssertNil(l.camera(for: "OTHER", lead: false, viewSize: size))
    }

    @MainActor
    func testWrittenDownAndReadBack() throws {
        let size = CGSize(width: 1000, height: 800)
        let camera = Camera(center: CGPoint(x: -1200, y: 90), zoom: 0.4, viewSize: size)
        let l = layout(cameras: ["SIDE": Layout.displayCamera(camera, viewSize: size)])
        let back = try JSONDecoder().decode(Layout.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back.cameras, l.cameras)
        XCTAssertTrue(back.sameArrangement(as: l))
        XCTAssertFalse(layout().sameArrangement(as: l))
    }

    func testALayoutFromBeforeDecodesWithoutCameras() throws {
        let json = #"{"name":"","saved":0,"center":{"x":1,"y":2},"zoom":1,"entries":[]}"#
        let l = try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
        XCTAssertNil(l.cameras)
    }
}
