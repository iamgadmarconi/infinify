import XCTest
@testable import Canvas

final class TidyTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 25, width: 1512, height: 920)

    private func item(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, app: String = "A",
                      recency: Int? = nil, away: Bool = false, group: Bool = false) -> Tidy.Item {
        Tidy.Item(rect: CGRect(x: x, y: y, width: w, height: h), recency: recency, app: app, away: away, isGroup: group)
    }

    private func options(columns: Int = 0, sizing: Tidy.Sizing = .keep, order: Tidy.Order = .position,
                         spacing: CGFloat = 32) -> Tidy.Options {
        Tidy.Options(columns: columns, sizing: sizing, order: order, spacing: spacing)
    }

    // MARK: Order

    func testReadingOrderGoesRowByRowThenLeftToRight() {
        // Two rows with ragged tops: the second row's windows start below the first row's middles.
        let items = [item(900, 60, 300, 300), item(40, 20, 400, 300), item(500, 90, 300, 200),
                     item(600, 500, 300, 200), item(30, 480, 300, 300)]
        XCTAssertEqual(Tidy.order(items, by: .position), [1, 2, 0, 4, 3])
    }

    func testAWindowBesideATallOneIsInItsRow() {
        let tall = item(0, 0, 400, 800), beside = item(500, 300, 300, 200), below = item(0, 900, 300, 200)
        XCTAssertEqual(Tidy.order([below, beside, tall], by: .position), [2, 1, 0])
    }

    func testMostRecentFirstThenTheRestWhereTheyAre() {
        let items = [item(0, 0, 100, 100, recency: 2), item(200, 0, 100, 100), item(400, 0, 100, 100, recency: 0),
                     item(600, 0, 100, 100, recency: 1)]
        XCTAssertEqual(Tidy.order(items, by: .recent), [2, 3, 0, 1])
    }

    func testByAppKeepsAnAppTogetherInOrderOfFirstAppearance() {
        let items = [item(0, 0, 100, 100, app: "Mail"), item(200, 0, 100, 100, app: "Safari"),
                     item(400, 0, 100, 100, app: "Mail"), item(0, 300, 100, 100, app: "Notes"),
                     item(200, 300, 100, 100, app: "Safari")]
        XCTAssertEqual(Tidy.order(items, by: .app), [0, 2, 1, 4, 3])
    }

    func testHiddenWindowsComeAfterEverythingVisible() {
        let items = [item(0, 0, 100, 100, away: true), item(200, 0, 100, 100), item(400, 0, 100, 100, recency: 0, away: true)]
        XCTAssertEqual(Tidy.order(items, by: .position), [1, 0, 2])
        XCTAssertEqual(Tidy.order(items, by: .recent), [1, 2, 0])
    }

    // MARK: Columns

    func testAutoColumnsIsTheSquareRootRoundedUp() {
        XCTAssertEqual(Tidy.columns(for: 1, requested: 0, sizing: .keep), 1)
        XCTAssertEqual(Tidy.columns(for: 4, requested: 0, sizing: .keep), 2)
        XCTAssertEqual(Tidy.columns(for: 5, requested: 0, sizing: .keep), 3)
        XCTAssertEqual(Tidy.columns(for: 12, requested: 0, sizing: .keep), 4)
        XCTAssertEqual(Tidy.columns(for: 30, requested: 0, sizing: .keep), 6)
        XCTAssertEqual(Tidy.columns(for: 30, requested: 0, sizing: .same), 4)
        XCTAssertEqual(Tidy.columns(for: 30, requested: 3, sizing: .keep), 3)
    }

    // MARK: Keep sizes

    func testKeepSizesAlignsColumnsAndRowsWithoutResizing() {
        let items = [item(900, 900, 300, 200), item(100, 100, 500, 400), item(700, 100, 200, 100), item(100, 600, 400, 300)]
        let placed = Tidy.layout(items, options: options(columns: 2), screen: screen)
        // Order: 1, 2 (top row), 3, 0 (bottom row).
        XCTAssertEqual(placed.rects.map(\.size), items.map(\.rect.size))
        XCTAssertEqual(placed.rects[1].origin, CGPoint(x: 32, y: 57))
        XCTAssertEqual(placed.rects[2].origin, CGPoint(x: 32 + 500 + 32, y: 57))   // the column is as wide as the 500 window
        XCTAssertEqual(placed.rects[3].origin, CGPoint(x: 32, y: 57 + 400 + 32))   // the row is as tall as the 400 window
        XCTAssertEqual(placed.rects[0].origin, CGPoint(x: 564, y: 489))
        XCTAssertEqual(placed.screens, [nil, nil, nil, nil])
        XCTAssertEqual(placed.bounds, CGRect(x: 0, y: 25, width: 32 + 500 + 32 + 300 + 32, height: 32 + 400 + 32 + 300 + 32))
    }

    func testKeepSizesNeverOverlaps() {
        var items: [Tidy.Item] = []
        for i in 0..<9 { items.append(item(CGFloat(i * 37), CGFloat(i * 23), CGFloat(200 + i * 50), CGFloat(150 + i * 30))) }
        let rects = Tidy.layout(items, options: options(), screen: screen).rects
        for a in rects.indices { for b in rects.indices where a < b { XCTAssertFalse(rects[a].intersects(rects[b]), "\(a) and \(b)") } }
    }

    // MARK: Same size

    func testSameSizeFillsTheScreenInSlotsThenTheNext() {
        let items = (0..<6).map { item(CGFloat($0 * 100), 0, 300, 200) }
        let placed = Tidy.layout(items, options: options(columns: 2, sizing: .same, spacing: 8), screen: screen)
        let topLeft = Tiling.rect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5), in: screen, gap: 8)
        let bottomRight = Tiling.rect(CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), in: screen, gap: 8)
        XCTAssertEqual(placed.rects[0], topLeft)
        XCTAssertEqual(placed.rects[3], bottomRight)
        let next = screen.offsetBy(dx: 0, dy: screen.height + Tiling.pageGutter)
        XCTAssertEqual(placed.rects[4], Tiling.rect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5), in: next, gap: 8))
        XCTAssertEqual(placed.screens[0], screen)
        XCTAssertEqual(placed.screens[5], next)
        XCTAssertEqual(Set(placed.rects.map(\.size)).count, 1)
    }

    func testAGroupSpansTheCellsItsOutlineNeedsAndIsNotResized() {
        let cell = Tiling.rect(CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1.0 / 3), in: screen, gap: 8).size
        let group = item(0, 0, cell.width * 1.6, cell.height * 0.5, group: true)
        let items = [item(900, 0, 200, 200), group, item(1200, 0, 200, 200), item(0, 500, 200, 200)]
        let placed = Tidy.layout(items, options: options(columns: 3, sizing: .same, spacing: 8), screen: screen)
        // Order: group (0, 0) spanning two columns, window 0 in the third, then the next row.
        XCTAssertEqual(placed.rects[1].origin, Tiling.rect(CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1.0 / 3), in: screen, gap: 8).origin)
        XCTAssertEqual(placed.rects[1].size, group.rect.size)
        XCTAssertEqual(placed.rects[0], Tiling.rect(CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1.0 / 3), in: screen, gap: 8))
        XCTAssertEqual(placed.rects[2], Tiling.rect(CGRect(x: 0, y: 1.0 / 3, width: 1.0 / 3, height: 1.0 / 3), in: screen, gap: 8))
        for a in placed.rects.indices { for b in placed.rects.indices where a < b { XCTAssertFalse(placed.rects[a].intersects(placed.rects[b])) } }
    }

    func testAGroupNeverStraddlesTwoScreens() {
        let cell = Tiling.rect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5), in: screen, gap: 8).size
        let tall = item(600, 10, cell.width * 0.8, cell.height * 1.5, group: true)
        // Three windows fill (0,0), (0,1), (1,0); the tall group can't start on row 1 of this screen.
        let items = [item(0, 0, 100, 100), item(200, 0, 100, 100), item(400, 0, 100, 100), tall]
        let placed = Tidy.layout(items, options: options(columns: 2, sizing: .same, order: .position, spacing: 8), screen: screen)
        let next = screen.offsetBy(dx: 0, dy: screen.height + Tiling.pageGutter)
        XCTAssertEqual(placed.screens[3], next)
        XCTAssertEqual(placed.rects[3].origin, Tiling.rect(CGRect(x: 0, y: 0, width: 0.5, height: 1), in: next, gap: 8).origin)
    }

    // MARK: Spacing

    func testSpacingIsInTileGaps() {
        XCTAssertEqual(Tidy.Spacing.tight.points(gap: 8), 8)
        XCTAssertEqual(Tidy.Spacing.normal.points(gap: 8), 32)
        XCTAssertEqual(Tidy.Spacing.roomy.points(gap: 8), 96)
        XCTAssertEqual(Tidy.Spacing.tight.points(gap: 0), 0)
        XCTAssertEqual(Tidy.Spacing.normal.points(gap: 0), 32)
    }

    func testATidyCanvasComesBackUnchanged() {
        let items = [item(100, 100, 300, 200), item(500, 100, 300, 200)]
        let first = Tidy.layout(items, options: options(columns: 2), screen: screen)
        let again = Tidy.layout(zip(items, first.rects).map { var i = $0.0; i.rect = $0.1; return i },
                                options: options(columns: 2), screen: screen)
        XCTAssertEqual(again.rects, first.rects)
    }

    func testNoItemsIsNothing() {
        let placed = Tidy.layout([], options: options(), screen: screen)
        XCTAssertTrue(placed.rects.isEmpty)
        XCTAssertTrue(placed.bounds.isNull)
    }
}
