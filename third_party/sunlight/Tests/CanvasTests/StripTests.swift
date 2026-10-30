import XCTest
@testable import Canvas

final class StripTests: XCTestCase {
    private func item(_ app: String, _ x: CGFloat = 0, _ y: CGFloat = 0, w: CGFloat = 400, h: CGFloat = 300,
                      recency: Int? = nil, away: Bool = false) -> Strip.Item {
        Strip.Item(rect: CGRect(x: x, y: y, width: w, height: h), app: app, recency: recency, away: away)
    }

    // MARK: Order

    func testMostRecentAppIsTheFirstColumn() {
        let items = [item("Mail", recency: 2), item("Safari", recency: 0), item("Xcode", recency: 1)]
        XCTAssertEqual(Strip.columns(items), [[1], [2], [0]])
    }

    func testAnAppsWindowsShareAColumnMostRecentOnTop() {
        let items = [item("Safari", recency: 3), item("Mail", recency: 1), item("Safari", recency: 0)]
        XCTAssertEqual(Strip.columns(items), [[2, 0], [1]])
    }

    func testNeverUsedComeAfterInTheOrderTheySit() {
        let items = [item("Notes", 900), item("Mail", recency: 0), item("Finder", 100), item("Music", 500)]
        XCTAssertEqual(Strip.columns(items), [[1], [2], [3], [0]])
    }

    func testNeverUsedWindowsInAColumnGoTopToBottom() {
        let items = [item("Safari", 0, 600), item("Safari", 0, 40), item("Safari", 0, 300, recency: 4)]
        XCTAssertEqual(Strip.columns(items), [[2, 1, 0]])
    }

    func testByPositionIgnoresRecency() {
        let items = [item("Mail", 800, recency: 0), item("Safari", 10, recency: 1)]
        XCTAssertEqual(Strip.columns(items, usingRecency: false), [[1], [0]])
    }

    // MARK: Layout

    func testColumnsAreAsWideAsTheirWidestWindowWithTheGapBetween() {
        let items = [item("Safari", w: 600, h: 400, recency: 0), item("Safari", w: 300, h: 200, recency: 1),
                     item("Mail", w: 500, h: 700, recency: 2)]
        let placed = Strip.layout(items, origin: CGPoint(x: 32, y: 57), gap: 32)
        XCTAssertEqual(placed.rects[0], CGRect(x: 32, y: 57, width: 600, height: 400))
        XCTAssertEqual(placed.rects[1], CGRect(x: 32, y: 489, width: 300, height: 200))
        XCTAssertEqual(placed.rects[2], CGRect(x: 664, y: 57, width: 500, height: 700))
        XCTAssertEqual(placed.bounds, CGRect(x: 0, y: 25, width: 1196, height: 764))
    }

    func testNothingIsResizedAndPointsAreWhole() {
        let items = [item("A", w: 400.5, h: 300.25, recency: 0), item("B", w: 200, h: 100, recency: 1)]
        let placed = Strip.layout(items, origin: CGPoint(x: 10, y: 10), gap: 8)
        XCTAssertEqual(placed.rects[0].size, items[0].rect.size)
        XCTAssertEqual(placed.rects[1].origin.x, (10 + 400.5 + 8 as CGFloat).rounded())
    }

    func testAnAwayWindowKeepsItsSlot() {
        let items = [item("A", w: 800, recency: 0, away: true), item("B", w: 200, recency: 1)]
        let placed = Strip.layout(items, origin: .zero, gap: 10)
        XCTAssertEqual(placed.rects[1].minX, 810)
    }

    func testAnEmptyStripHasNoBounds() {
        XCTAssertTrue(Strip.layout([], origin: .zero, gap: 10).bounds.isNull)
    }

    // MARK: Dropping

    private func laidOut(_ items: [Strip.Item]) -> (columns: [[Int]], rects: [CGRect]) {
        let placed = Strip.layout(items, origin: .zero, gap: 20)
        return (placed.columns, placed.rects)
    }

    func testDroppingPastANeighboursMiddleSwapsTheColumns() {
        let items = [item("A", recency: 0), item("B", recency: 1), item("C", recency: 2)]
        let (columns, laid) = laidOut(items)
        var rects = laid
        XCTAssertEqual(columns, [[0], [1], [2]])
        rects[0].origin.x = rects[1].midX + 10 - rects[0].width / 2   // A's middle just past B's
        XCTAssertEqual(Strip.reordered(columns, rects: rects, dropped: 0), [[1], [0], [2]])
    }

    func testDroppingShortOfTheMiddleKeepsTheOrder() {
        let items = [item("A", recency: 0), item("B", recency: 1)]
        let (columns, laid) = laidOut(items)
        var rects = laid
        rects[0].origin.x += 100
        XCTAssertEqual(Strip.reordered(columns, rects: rects, dropped: 0), [[0], [1]])
    }

    func testOneWindowOfAnAppTakesItsWholeColumnAlong() {
        let items = [item("A", recency: 0), item("A", recency: 1), item("B", recency: 2)]
        let (columns, laid) = laidOut(items)
        var rects = laid
        XCTAssertEqual(columns, [[0, 1], [2]])
        rects[1].origin.x = rects[2].maxX
        XCTAssertEqual(Strip.reordered(columns, rects: rects, dropped: 1), [[2], [0, 1]])
    }

    func testDroppingBelowASiblingSwapsThemInTheColumn() {
        let items = [item("A", recency: 0), item("A", recency: 1)]
        let (columns, laid) = laidOut(items)
        var rects = laid
        rects[0].origin.y = rects[1].maxY - 50
        XCTAssertEqual(Strip.reordered(columns, rects: rects, dropped: 0), [[1, 0]])
    }

    func testTheReorderedStripReadsBackAsRecency() {
        // The controller writes a reordered strip back as the recency list; laying that out gives it again.
        let items = [item("A", recency: 0), item("B", recency: 1), item("A", recency: 2), item("C")]
        let (columns, laid) = laidOut(items)
        var rects = laid
        rects[3].origin.x = -500
        let order = Strip.reordered(columns, rects: rects, dropped: 3)
        XCTAssertEqual(order, [[3], [0, 2], [1]])
        var ranked = items
        for (rank, i) in order.flatMap({ $0 }).enumerated() { ranked[i].recency = rank }
        XCTAssertEqual(Strip.columns(ranked), order)
        XCTAssertNotEqual(columns, order)
    }

    // MARK: Arrow keys

    func testLeftAndRightGoToTheTopOfTheNextColumn() {
        let columns = [[0, 1], [2, 3], [4]]
        let away = [false, false, false, false, false]
        XCTAssertEqual(Strip.neighbour(of: 1, in: columns, away: away, direction: .right), 2)
        XCTAssertEqual(Strip.neighbour(of: 3, in: columns, away: away, direction: .left), 0)
        XCTAssertNil(Strip.neighbour(of: 4, in: columns, away: away, direction: .right))
        XCTAssertNil(Strip.neighbour(of: 0, in: columns, away: away, direction: .left))
    }

    func testUpAndDownStayInTheColumn() {
        let columns = [[0, 1, 2]]
        let away = [false, false, false]
        XCTAssertEqual(Strip.neighbour(of: 0, in: columns, away: away, direction: .down), 1)
        XCTAssertEqual(Strip.neighbour(of: 2, in: columns, away: away, direction: .up), 1)
        XCTAssertNil(Strip.neighbour(of: 2, in: columns, away: away, direction: .down))
    }

    func testAwayWindowsAreSkipped() {
        let columns = [[0], [1], [2, 3]]
        let away = [false, true, true, false]
        XCTAssertEqual(Strip.neighbour(of: 0, in: columns, away: away, direction: .right), 3)
        XCTAssertNil(Strip.neighbour(of: 3, in: columns, away: away, direction: .up))
    }
}
