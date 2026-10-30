import XCTest
@testable import Canvas

/// The menu bar panel's model: what the line under "Sunlight" says, and what is enabled when. The
/// views are thin; this is where the rules live.
@MainActor
final class MenuBarPanelTests: XCTestCase {
    typealias Model = MenuBarPanelModel

    func testOffComesBeforeEverythingElse() {
        let caption = Model.caption(on: false, setup: Model.Progress(done: 2, total: 8), liveWindowsUnloaded: true,
                                    update: "1.4", rendering: .live)
        XCTAssertEqual(caption.text, "Off · windows left as they are")
        XCTAssertNil(caption.prompt)
        XCTAssertNil(caption.action)
    }

    func testWhatNeedsDoingComesInTheOrderItWouldBeDone() {
        let setup = Model.caption(on: true, setup: Model.Progress(done: 5, total: 8), liveWindowsUnloaded: true,
                                  update: "1.4", rendering: .live)
        XCTAssertEqual(setup.text, "Setting up · 5 of 8 steps")
        XCTAssertEqual(setup.prompt, "Continue")
        XCTAssertEqual(setup.action, .continueSetup)

        let reload = Model.caption(on: true, setup: Model.Progress(done: 8, total: 8), liveWindowsUnloaded: true,
                                   update: "1.4", rendering: .live)
        XCTAssertEqual(reload.text, "Live windows aren't loaded")
        XCTAssertEqual(reload.action, .reload)

        let update = Model.caption(on: true, setup: nil, liveWindowsUnloaded: false, update: "1.4", rendering: .live)
        XCTAssertEqual(update.text, "Sunlight 1.4 is ready")
        XCTAssertEqual(update.prompt, "Install")
        XCTAssertEqual(update.action, .install)
    }

    func testNothingToDoSaysHowWindowsAreShown() {
        XCTAssertEqual(Model.caption(on: true, setup: nil, liveWindowsUnloaded: false, update: nil, rendering: .live).text, "On · live windows")
        XCTAssertEqual(Model.caption(on: true, setup: nil, liveWindowsUnloaded: false, update: nil, rendering: .pictures).text, "On · screen capture")
        XCTAssertEqual(Model.caption(on: true, setup: nil, liveWindowsUnloaded: false, update: nil, rendering: .preview).text, "On · preview")
    }

    func testTheFirstNineLayoutsGetCommandNumbers() {
        let rows = Model.layoutRows((1...11).map { "Layout \($0)" })
        XCTAssertEqual(rows.map(\.key), ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘7", "⌘8", "⌘9", nil, nil])
        XCTAssertEqual(rows.first?.name, "Layout 1")
    }

    func testOffLeavesOnlyTheSwitchAndMore() {
        let model = Model()
        model.isOn = false
        model.liveWindowsUnloaded = true
        XCTAssertFalse(model.canTidy)
        XCTAssertFalse(model.canUseLayouts)
        XCTAssertFalse(model.canToggleMinimap)
        XCTAssertFalse(model.canToggleStrip)
        XCTAssertFalse(model.canReload)
        XCTAssertFalse(model.canTakeOver)
    }

    func testStripModeStopsTidyAndArrangeButNotLayouts() {
        let model = Model()
        model.stripMode = true
        XCTAssertFalse(model.canTidy)
        XCTAssertFalse(model.canArrange)
        XCTAssertTrue(model.canUseLayouts)
        XCTAssertTrue(model.canToggleStrip)
    }

    func testBusyAndSetupHoldTheCanvasRows() {
        let model = Model()
        model.busy = true
        XCTAssertFalse(model.canTidy)
        XCTAssertFalse(model.canUseLayouts)
        XCTAssertTrue(model.canToggleMinimap)
        model.busy = false
        model.setupShowing = true
        model.liveWindowsUnloaded = true
        XCTAssertFalse(model.canTidy)
        XCTAssertFalse(model.canUseLayouts)
        XCTAssertFalse(model.canReload)
        XCTAssertFalse(model.canTakeOver)
    }

    func testReloadAndTakeOverFollowTheirState() {
        let model = Model()
        XCTAssertFalse(model.canReload)
        model.liveWindowsUnloaded = true
        XCTAssertTrue(model.canReload)
        XCTAssertTrue(model.canTakeOver)
        model.takeoverRunning = true
        XCTAssertFalse(model.canTakeOver)
    }

    func testLayoutsSummaryCounts() {
        let model = Model()
        XCTAssertEqual(model.layoutsSummary, "none saved")
        model.layouts = Model.layoutRows(["One"])
        XCTAssertEqual(model.layoutsSummary, "1 saved")
        model.layouts = Model.layoutRows(["One", "Two", "Three"])
        XCTAssertEqual(model.layoutsSummary, "3 saved")
    }

    func testTheShortcutsReferenceMatchesThePlacementKeys() {
        let rows = ShortcutReference.commandRows(arranging: true, strip: true)
        XCTAssertEqual(rows.first { $0.title == "Tidy" }?.keys, TileMenu.tidyKeysSummary)
        XCTAssertEqual(rows.first { $0.title == "Move & Resize a window" }?.keys, TileMenu.tileKeysSummary)
        XCTAssertFalse(ShortcutReference.canvasRows.isEmpty)
        XCTAssertEqual(Set(rows.map(\.title)).count, rows.count, "titles are the rows' identity in Settings")
    }

    func testTheShortcutsReferenceLeavesOutFeaturesThatAreOff() {
        let titles = ShortcutReference.commandRows(arranging: false, strip: false).map(\.title)
        XCTAssertFalse(titles.contains("Tidy"))
        XCTAssertFalse(titles.contains("Arrange the screen in columns"))
        XCTAssertFalse(titles.contains("Strip mode on or off"))
        XCTAssertTrue(titles.contains("Move & Resize a window"))
    }
}
