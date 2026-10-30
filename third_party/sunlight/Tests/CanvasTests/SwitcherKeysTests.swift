import XCTest
import CoreGraphics
@testable import Canvas

final class SwitcherKeysTests: XCTestCase {
    private let tab: Int64 = 48, grave: Int64 = 50, left: Int64 = 123, right: Int64 = 124, down: Int64 = 125, up: Int64 = 126

    private func act(_ key: Int64, _ flags: CGEventFlags, open: Bool) -> KeyTap.Action {
        var state = KeyTap.State()
        state.switcherOpen = open
        return KeyTap.action(keyCode: key, flags: flags, state: &state)
    }

    func testCommandTabOpensThenSteps() {
        var state = KeyTap.State()
        XCTAssertEqual(KeyTap.action(keyCode: tab, flags: .maskCommand, state: &state), .send(.appSwitchBegin(reverse: false)))
        XCTAssertTrue(state.switcherOpen)
        XCTAssertEqual(KeyTap.action(keyCode: tab, flags: [.maskCommand, .maskShift], state: &state), .send(.appSwitchStep(reverse: true)))
    }

    func testWindowStepsWhileSwitching() {
        XCTAssertEqual(act(grave, .maskCommand, open: true), .send(.appSwitchWindowStep(reverse: false)))
        XCTAssertEqual(act(grave, [.maskCommand, .maskShift], open: true), .send(.appSwitchWindowStep(reverse: true)))
        XCTAssertEqual(act(down, .maskCommand, open: true), .send(.appSwitchWindowStep(reverse: false)))
        XCTAssertEqual(act(up, .maskCommand, open: true), .send(.appSwitchWindowStep(reverse: true)))
    }

    func testArrowsAcrossTheStripStepApps() {
        XCTAssertEqual(act(right, .maskCommand, open: true), .send(.appSwitchStep(reverse: false)))
        XCTAssertEqual(act(left, .maskCommand, open: true), .send(.appSwitchStep(reverse: true)))
    }

    func testTheSameKeysPassWhenNotSwitching() {
        XCTAssertEqual(act(grave, .maskCommand, open: false), .pass, "⌘` stays the Mac's own outside the switcher")
        XCTAssertEqual(act(down, .maskCommand, open: false), .pass)
        XCTAssertEqual(act(left, .maskCommand, open: false), .pass)
    }

    func testControlArrowsKeepTheirMeaningWhileSwitching() {
        XCTAssertEqual(act(left, .maskControl, open: true), .swallow)
    }

    func testOnlyTheMissionControlKeySeesAll() {
        let missionControlKey: Int64 = 160
        XCTAssertEqual(act(missionControlKey, [], open: false), .send(.missionControl))
        XCTAssertEqual(act(up, .maskControl, open: false), .pass, "⌃↑ is the app's own")
        XCTAssertEqual(act(down, .maskControl, open: false), .pass, "⌃↓ is the app's own")
        XCTAssertEqual(act(grave, .maskAlternate, open: false), .pass, "⌥` is the app's own")
    }
}
