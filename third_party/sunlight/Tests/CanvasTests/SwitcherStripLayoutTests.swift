import XCTest
import CoreGraphics
@testable import Canvas

final class SwitcherStripLayoutTests: XCTestCase {
    /// A 1512 × 982 screen with a 37-point menu bar, in overlay (top-left) coordinates.
    private let area = CGRect(x: 0, y: 37, width: 1512, height: 945)
    private typealias L = SwitcherStripLayout

    func testABottomRowIsCentredAndHugsTheEdge() {
        let l = L(edge: .bottom, count: 4, area: area)
        let card = l.cardFrame
        XCTAssertEqual(card.width, 2 * L.padding + 4 * L.icon + 3 * L.spacing)
        XCTAssertEqual(card.height, L.icon + 2 * L.padding)
        XCTAssertEqual(card.midX, area.midX)
        XCTAssertEqual(card.maxY, area.maxY - L.margin)
        XCTAssertFalse(l.overflows)
    }

    func testATopRowSitsBelowTheMenuBar() {
        let card = L(edge: .top, count: 3, area: area).cardFrame
        XCTAssertEqual(card.minY, area.minY + L.margin)
    }

    func testSideStripsAreColumns() {
        let left = L(edge: .left, count: 3, area: area).cardFrame
        let right = L(edge: .right, count: 3, area: area).cardFrame
        XCTAssertEqual(left.minX, L.margin)
        XCTAssertEqual(right.maxX, area.maxX - L.margin)
        XCTAssertEqual(left.width, L.icon + 2 * L.padding)
        XCTAssertGreaterThan(left.height, left.width)
        XCTAssertEqual(left.midY, area.midY)
    }

    func testSlotsStepByOnePitchAndSitInsideTheCard() {
        let l = L(edge: .left, count: 3, area: area)
        XCTAssertEqual(l.slot(1).minY - l.slot(0).minY, L.icon + L.spacing)
        XCTAssertEqual(l.slot(0).minX, L.padding)
        XCTAssertEqual(l.slot(2).maxY + L.padding, l.contentLength)
    }

    func testEverythingFitsMeansNoScroll() {
        let l = L(edge: .bottom, count: 5, area: area)
        XCTAssertEqual(l.scroll(centering: 4), 0)
    }

    func testTooManyIconsScrollWithTheSelectionCentredAndHeldAtTheEnds() {
        let l = L(edge: .left, count: 20, area: area)
        XCTAssertTrue(l.overflows)
        XCTAssertEqual(l.cardFrame.height, area.height - 2 * L.margin)
        XCTAssertEqual(l.scroll(centering: 0), 0)
        XCTAssertEqual(l.scroll(centering: 19), l.contentLength - l.length)
        let middle = l.scroll(centering: 10)
        XCTAssertEqual(l.center(of: 10) - middle, l.length / 2, accuracy: 0.001)
    }

    func testHitTestingFindsTheIconUnderThePointer() {
        let l = L(edge: .bottom, count: 3, area: area)
        XCTAssertEqual(l.index(at: l.center(of: 0), scroll: 0), 0)
        XCTAssertEqual(l.index(at: l.center(of: 2), scroll: 0), 2)
        XCTAssertNil(l.index(at: l.contentLength + 40, scroll: 0))
        let long = L(edge: .bottom, count: 30, area: area)
        let s = long.scroll(centering: 15)
        XCTAssertEqual(long.index(at: long.center(of: 15) - s, scroll: s), 15)
    }

    func testTheCaptionFacesTheMiddleAndStaysOnScreen() {
        let size = CGSize(width: 300, height: 60)
        let bottom = L(edge: .bottom, count: 3, area: area)
        let c = bottom.captionFrame(size: size, along: bottom.center(of: 1))
        XCTAssertEqual(c.maxY, bottom.cardFrame.minY - L.captionGap)
        XCTAssertEqual(c.midX, bottom.cardFrame.minX + bottom.center(of: 1), accuracy: 0.001)

        let left = L(edge: .left, count: 3, area: area)
        XCTAssertEqual(left.captionFrame(size: size, along: 0).minX, left.cardFrame.maxX + L.captionGap)
        let right = L(edge: .right, count: 3, area: area)
        XCTAssertEqual(right.captionFrame(size: size, along: 0).maxX, right.cardFrame.minX - L.captionGap)

        let wide = L(edge: .bottom, count: 40, area: area)
        XCTAssertGreaterThanOrEqual(wide.captionFrame(size: size, along: 0).minX, area.minX + L.margin)
        XCTAssertLessThanOrEqual(wide.captionFrame(size: size, along: wide.length).maxX, area.maxX - L.margin)
    }

    func testTheMinimapStepsAsideOnlyWhenItWouldBeCovered() {
        let minimap = CGRect(x: area.maxX - 212, y: area.maxY - 137, width: 200, height: 125)
        let few = L(edge: .bottom, count: 3, area: area)
        XCTAssertEqual(few.clearing(minimap), minimap, "a short strip in the middle doesn't reach it")
        let many = L(edge: .bottom, count: 14, area: area)
        let moved = many.clearing(minimap)
        XCTAssertLessThanOrEqual(moved.maxY, many.cardFrame.minY - L.margin)
        XCTAssertEqual(moved.minX, minimap.minX)
        let right = L(edge: .right, count: 9, area: area)
        XCTAssertLessThanOrEqual(right.clearing(minimap).maxX, right.cardFrame.minX - L.margin)
        XCTAssertEqual(L(edge: .top, count: 14, area: area).clearing(minimap), minimap)
    }

    func testChipsShowAtMostFiveAroundTheSelection() {
        XCTAssertEqual(L.chipRange(count: 3, selected: 2), 0..<3)
        XCTAssertEqual(L.chipRange(count: 9, selected: 0), 0..<5)
        XCTAssertEqual(L.chipRange(count: 9, selected: 4), 2..<7)
        XCTAssertEqual(L.chipRange(count: 9, selected: 8), 4..<9)
    }
}
