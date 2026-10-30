import XCTest
@testable import Canvas

final class ResizingTests: XCTestCase {
    private let window = CGRect(x: 100, y: 100, width: 400, height: 300)

    func testEdgesAreFoundInsideTheWindowNearItsBorder() {
        XCTAssertEqual(Resizing.edges(at: CGPoint(x: 102, y: 250), in: window), .left)
        XCTAssertEqual(Resizing.edges(at: CGPoint(x: 497, y: 250), in: window), .right)
        XCTAssertEqual(Resizing.edges(at: CGPoint(x: 300, y: 103), in: window), .top)
        XCTAssertEqual(Resizing.edges(at: CGPoint(x: 300, y: 398), in: window), .bottom)
        XCTAssertEqual(Resizing.edges(at: CGPoint(x: 300, y: 250), in: window), [])
        XCTAssertEqual(Resizing.edges(at: CGPoint(x: 90, y: 250), in: window), [], "outside is the canvas's")
    }

    func testCornersAreGenerous() {
        XCTAssertEqual(Resizing.edges(at: CGPoint(x: 497, y: 390), in: window), [.right, .bottom])
        XCTAssertEqual(Resizing.edges(at: CGPoint(x: 490, y: 398), in: window), [.right, .bottom])
        XCTAssertEqual(Resizing.edges(at: CGPoint(x: 102, y: 110), in: window), [.left, .top])
    }

    func testTinyWindowsHaveNoEdges() {
        let tiny = CGRect(x: 0, y: 0, width: 50, height: 30)
        XCTAssertEqual(Resizing.edges(at: CGPoint(x: 1, y: 15), in: tiny), [])
    }

    func testResizeMovesOnlyTheGrabbedEdges() {
        let r = Resizing.resize(window, edges: [.left, .bottom], by: CGVector(dx: -50, dy: 40))
        XCTAssertEqual(r, CGRect(x: 50, y: 100, width: 450, height: 340))
    }

    func testResizeStopsAtTheMinimumWithoutMovingTheOppositeEdge() {
        let r = Resizing.resize(window, edges: [.left, .top], by: CGVector(dx: 1000, dy: 1000))
        XCTAssertEqual(r.maxX, window.maxX)
        XCTAssertEqual(r.maxY, window.maxY)
        XCTAssertEqual(r.size, Resizing.minSize)
    }

    func testGridSnapsOnlyTheMovedEdges() {
        let r = CGRect(x: 103, y: 117, width: 411, height: 305)   // right edge at 514, bottom at 422
        let snapped = Resizing.grid(r, edges: [.right, .bottom], size: 40)
        XCTAssertEqual(snapped, CGRect(x: 103, y: 117, width: 417, height: 323))
    }

    func testGridNeverSnapsBelowTheMinimum() {
        let r = CGRect(x: 0, y: 0, width: 170, height: 100)
        let snapped = Resizing.grid(r, edges: .right, size: 80)
        XCTAssertGreaterThanOrEqual(snapped.width, Resizing.minSize.width)
        XCTAssertEqual(snapped.maxX.truncatingRemainder(dividingBy: 80), 0)
    }

    func testPlaceKeepsTheAnchoredCorner() {
        let anchor = Resizing.anchor(for: [.left, .top])
        XCTAssertEqual(anchor, CGPoint(x: 1, y: 1))
        let placed = Resizing.place(CGSize(width: 500, height: 320), in: window, anchor: anchor)
        XCTAssertEqual(placed.maxX, window.maxX)
        XCTAssertEqual(placed.maxY, window.maxY)
        XCTAssertEqual(Resizing.place(CGSize(width: 10, height: 10), in: window, anchor: .zero).origin, window.origin)
    }
}
