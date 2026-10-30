import XCTest
@testable import Canvas

final class TilingTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 25, width: 1512, height: 920)

    func testHalvesShareTheGapBetweenThem() {
        let left = Tiling.rect(Tiling.Preset.leftHalf.unit!, in: screen, gap: 8)
        let right = Tiling.rect(Tiling.Preset.rightHalf.unit!, in: screen, gap: 8)
        XCTAssertEqual(left, CGRect(x: 8, y: 33, width: 744, height: 904))
        XCTAssertEqual(right.minX - left.maxX, 8)
        XCTAssertEqual(screen.maxX - right.maxX, 8)
        XCTAssertEqual(left.height, right.height)
    }

    func testNoGapFillsTheArea() {
        let full = Tiling.rect(Tiling.Preset.full.unit!, in: screen, gap: 0)
        XCTAssertEqual(full, screen)
    }

    func testThirdsCoverTheWidthWithoutOverlap() {
        let rects = [Tiling.Preset.leftThird, .centerThird, .rightThird].map { Tiling.rect($0.unit!, in: screen, gap: 8) }
        XCTAssertEqual(rects[0].minX, 8)
        XCTAssertEqual(rects[2].maxX, screen.maxX - 8)
        XCTAssertLessThanOrEqual(rects[0].maxX, rects[1].minX)
        XCTAssertLessThanOrEqual(rects[1].maxX, rects[2].minX)
        XCTAssertLessThanOrEqual(abs(rects[0].width - rects[2].width), 1)
    }

    func testTwoThirdsAndAThirdMeet() {
        let big = Tiling.rect(Tiling.Preset.leftTwoThirds.unit!, in: screen, gap: 8)
        let small = Tiling.rect(Tiling.Preset.rightThird.unit!, in: screen, gap: 8)
        XCTAssertEqual(small.minX - big.maxX, 8)
    }

    func testCentreKeepsTheSizeWithinTheArea() {
        let r = Tiling.rect(.center, size: CGSize(width: 800, height: 600), in: screen, gap: 8)
        XCTAssertEqual(r.size, CGSize(width: 800, height: 600))
        XCTAssertEqual(r.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(r.midY, screen.midY, accuracy: 1)
        let huge = Tiling.rect(.center, size: CGSize(width: 4000, height: 3000), in: screen, gap: 8)
        XCTAssertEqual(huge, screen.insetBy(dx: 8, dy: 8))
    }

    func testAnchorsKeepToTheOuterEdges() {
        XCTAssertEqual(Tiling.anchor(for: Tiling.Preset.leftHalf.unit), CGPoint(x: 0, y: 0))
        XCTAssertEqual(Tiling.anchor(for: Tiling.Preset.bottomRight.unit), CGPoint(x: 1, y: 1))
        XCTAssertEqual(Tiling.anchor(for: Tiling.Preset.centerThird.unit), CGPoint(x: 0.5, y: 0))
        XCTAssertEqual(Tiling.anchor(for: nil), CGPoint(x: 0.5, y: 0.5))
    }

    func testRepeatPressCyclesTheWidth() {
        XCTAssertEqual(Tiling.Preset.leftHalf.next, .leftTwoThirds)
        XCTAssertEqual(Tiling.Preset.leftTwoThirds.next, .leftThird)
        XCTAssertEqual(Tiling.Preset.leftThird.next, .leftHalf)
        XCTAssertEqual(Tiling.Preset.leftThird.cycleRoot, .leftHalf)
        XCTAssertEqual(Tiling.Preset.topLeft.next, .topLeft)
    }

    func testPagesTileTheCanvasFromTheRealDesktop() {
        let home = Tiling.page(containing: CGPoint(x: 700, y: 400), screen: screen)
        XCTAssertEqual(home, screen)
        let right = Tiling.page(containing: CGPoint(x: 1512 + 240 + 10, y: 400), screen: screen)
        XCTAssertEqual(right.minX, 1512 + 240)
        let left = Tiling.page(containing: CGPoint(x: -500, y: 400), screen: screen)
        XCTAssertEqual(left.minX, -(1512 + 240))
        let below = Tiling.page(containing: CGPoint(x: 10, y: 25 + 920 + 200), screen: screen)
        XCTAssertEqual(below.minY, 25 + 920 + 240)
        // Half the gutter belongs to each page beside it.
        XCTAssertEqual(Tiling.page(containing: CGPoint(x: 1512 + 100, y: 400), screen: screen), home)
    }

    func testCellsAreInReadingOrder() {
        let cells = Tiling.cells(columns: 2, rows: 2)
        XCTAssertEqual(cells.count, 4)
        XCTAssertEqual(cells[1], CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(cells[2], CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
    }

    func testArrangeKeepsTheWindowsOrderOnScreen() {
        let rects = [CGRect(x: 900, y: 0, width: 100, height: 100),
                     CGRect(x: 100, y: 0, width: 100, height: 100),
                     CGRect(x: 500, y: 0, width: 100, height: 100)]
        XCTAssertEqual(Tiling.arrangeOrder(rects, rows: 1), [1, 2, 0])
        let grid = [CGRect(x: 600, y: 500, width: 100, height: 100),
                    CGRect(x: 0, y: 0, width: 100, height: 100),
                    CGRect(x: 0, y: 500, width: 100, height: 100),
                    CGRect(x: 600, y: 0, width: 100, height: 100)]
        XCTAssertEqual(Tiling.arrangeOrder(grid, rows: 2), [1, 3, 2, 0])
    }

    /// The green button's Fill & Arrange layouts: the window's own cell first, and the cells cover the
    /// area without overlapping.
    func testSharesCoverTheAreaWithTheWindowFirst() {
        for share in Tiling.Share.allCases {
            let cells = share.cells
            let area = cells.reduce(0) { $0 + $1.width * $1.height }
            XCTAssertEqual(area, 1, accuracy: 0.0001, share.title)
            for (i, a) in cells.enumerated() {
                for b in cells[(i + 1)...] {
                    XCTAssertTrue(a.intersection(b).width * a.intersection(b).height < 0.0001, share.title)
                }
            }
            if let preset = share.preset, let unit = preset.unit {
                XCTAssertEqual(cells[0].minX, unit.minX, accuracy: 0.0001, share.title)
                XCTAssertEqual(cells[0].width, unit.width, accuracy: 0.0001, share.title)
                XCTAssertEqual(cells[0].height, unit.height, accuracy: 0.0001, share.title)
            }
        }
        XCTAssertEqual(Tiling.Share.leftRight.cells.count, 2)
        XCTAssertEqual(Tiling.Share.rightLeft.cells[0].minX, 0.5)
        XCTAssertEqual(Tiling.Share.quarters.cells.count, 4)
    }
}
