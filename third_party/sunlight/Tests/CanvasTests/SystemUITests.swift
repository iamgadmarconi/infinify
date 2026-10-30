import XCTest
@testable import Canvas

final class SystemUITests: XCTestCase {
    func testTheMacsOwnInterfaceIsNotAWindow() {
        for id in ["com.apple.notificationcenterui", "com.apple.controlcenter", "com.apple.Spotlight",
                   "com.apple.dock", "com.apple.WindowManager"] {
            XCTAssertTrue(SystemUI.owns(id), id)
        }
    }

    func testAppsAndUnknownOwnersAreLeftAlone() {
        for id in ["com.apple.finder", "com.apple.Safari", "com.apple.Terminal", "com.tinyspeck.slackmacgap"] {
            XCTAssertFalse(SystemUI.owns(id), id)
        }
        XCTAssertFalse(SystemUI.owns(nil))
    }
}
