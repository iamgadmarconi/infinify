import XCTest
import CoreGraphics
@testable import Canvas

final class SwitcherCycleTests: XCTestCase {
    // Safari has three windows, Mail one, Notes one, Xcode two.
    private let safari: pid_t = 10, mail: pid_t = 20, notes: pid_t = 30, xcode: pid_t = 40
    private func w(_ id: CGWindowID, _ pid: pid_t, x: CGFloat) -> SwitcherCycle.Window {
        .init(id: id, pid: pid, position: CGPoint(x: x, y: 0))
    }
    private var windows: [SwitcherCycle.Window] {
        [w(1, safari, x: 500), w(2, safari, x: 100), w(3, safari, x: 900),
         w(4, mail, x: 300), w(5, notes, x: 50), w(6, xcode, x: 700), w(7, xcode, x: 200)]
    }

    func testCurrentAppComesFirstThenRecentThenByPosition() {
        let c = SwitcherCycle(windows: windows, recent: [6, 4, 1], current: 1)
        XCTAssertEqual(c.apps.map(\.pid), [safari, xcode, mail, notes])
        XCTAssertEqual(c.selectedWindow, 1)
    }

    func testWindowsOfAnAppAreCurrentThenRecentThenLeftToRight() {
        let c = SwitcherCycle(windows: windows, recent: [6, 3, 1], current: 1)
        XCTAssertEqual(c.apps.first?.windows, [1, 3, 2])
        XCTAssertEqual(c.apps[1].windows, [6, 7])
    }

    func testFirstTabFromAWindowLandsOnThePreviousApp() {
        var c = SwitcherCycle(windows: windows, recent: [1, 6], current: 1)
        c.stepApp(by: 1)
        XCTAssertEqual(c.selectedApp?.pid, xcode)
        XCTAssertEqual(c.selectedWindow, 6, "an app is entered at its most recent window")
    }

    func testFromTheCanvasTheFirstAppIsTheMostRecent() {
        let c = SwitcherCycle(windows: windows, recent: [4, 1], current: nil)
        XCTAssertEqual(c.selectedApp?.pid, mail)
    }

    func testNeverEnteredAppsAreOrderedByTheirLeftmostWindow() {
        let c = SwitcherCycle(windows: windows, recent: [], current: nil)
        XCTAssertEqual(c.apps.map(\.pid), [notes, safari, xcode, mail])
    }

    func testTabAndShiftTabWrap() {
        var c = SwitcherCycle(windows: windows, recent: [], current: nil)
        c.stepApp(by: -1)
        XCTAssertEqual(c.selectedApp?.pid, mail)
        c.stepApp(by: 1)
        XCTAssertEqual(c.selectedApp?.pid, notes)
    }

    func testWindowStepsWrapWithinTheApp() {
        var c = SwitcherCycle(windows: windows, recent: [], current: nil)
        c.stepApp(by: 1)   // Safari: 2, 1, 3 left to right
        XCTAssertEqual(c.selectedApp?.windows, [2, 1, 3])
        c.stepWindow(by: 1)
        XCTAssertEqual(c.selectedWindow, 1)
        c.stepWindow(by: 2)
        XCTAssertEqual(c.selectedWindow, 2)
        c.stepWindow(by: -1)
        XCTAssertEqual(c.selectedWindow, 3)
    }

    func testTabAfterWindowStepsMovesToTheNextAppsFirstWindow() {
        var c = SwitcherCycle(windows: windows, recent: [], current: nil)
        c.stepApp(by: 1)
        c.stepWindow(by: 2)
        c.stepApp(by: 1)
        XCTAssertEqual(c.selectedApp?.pid, xcode)
        XCTAssertEqual(c.selectedWindow, 7)
    }

    func testASingleAppStepsThroughItsWindows() {
        var c = SwitcherCycle(windows: [w(1, safari, x: 0), w(2, safari, x: 10)], recent: [1], current: 1)
        c.stepApp(by: 1)
        XCTAssertEqual(c.selectedWindow, 2)
    }

    func testAWindowStepOnASingleWindowAppStaysPut() {
        var c = SwitcherCycle(windows: windows, recent: [4], current: nil)
        c.stepWindow(by: 1)
        XCTAssertEqual(c.selectedWindow, 4)
    }

    func testAVanishedWindowKeepsTheSelection() {
        var c = SwitcherCycle(windows: windows, recent: [6, 4], current: nil)
        c.stepApp(by: 1)   // Mail
        c.keep(only: [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(c.apps.first?.windows, [6])
        XCTAssertEqual(c.selectedWindow, 4)
    }

    func testAnAppWhoseLastWindowGoesLeavesTheCycle() {
        var c = SwitcherCycle(windows: windows, recent: [6, 4], current: nil)
        c.stepApp(by: 1)   // Mail
        c.keep(only: [1, 2, 3, 5, 6, 7])
        XCTAssertFalse(c.apps.contains { $0.pid == mail })
        XCTAssertNotNil(c.selectedWindow, "the selection moves to the app that took its place")
    }

    func testEverythingGoneLeavesAnEmptyCycle() {
        var c = SwitcherCycle(windows: windows, recent: [], current: nil)
        c.keep(only: [])
        XCTAssertTrue(c.isEmpty)
        XCTAssertNil(c.selectedWindow)
        c.stepApp(by: 1)
        c.stepWindow(by: 1)
        XCTAssertNil(c.selectedWindow)
    }

    func testPointerSelection() {
        var c = SwitcherCycle(windows: windows, recent: [], current: nil)
        c.select(app: 2, window: 1)
        XCTAssertEqual(c.selectedWindow, 6)
        c.select(app: 1)
        XCTAssertEqual(c.selectedWindow, 2)
        c.select(app: 9)
        XCTAssertEqual(c.selectedWindow, 2, "out of range is ignored")
    }
}
