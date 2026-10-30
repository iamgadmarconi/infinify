import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Canvas

/// The placement section is one list for every menu, so the Window menu, the right-click menus and the
/// shortcuts menu can't drift apart; these pin what it holds and which keys it shows.
@MainActor
final class TileMenuTests: XCTestCase {
    private let actions = TileMenu.Actions(tidy: #selector(NSObject.copy), tidyBy: #selector(NSObject.copy),
                                           arrange: #selector(NSObject.copy), tile: #selector(NSObject.copy))

    func testThePlacementSectionIsInScopeOrder() {
        let items = TileMenu.placementItems(target: nil, actions: actions, represent: { $0.rawValue }, arranging: true)
        XCTAssertEqual(items.map(\.title), ["Tidy", "Tidy By", "Arrange", "Move & Resize"])
        // The canvas's own menu has no window to Move & Resize.
        XCTAssertEqual(TileMenu.placementItems(target: nil, actions: actions, arranging: true).map(\.title), ["Tidy", "Tidy By", "Arrange"])
    }

    func testArrangingOffLeavesOnlyMoveAndResize() {
        let items = TileMenu.placementItems(target: nil, actions: actions, represent: { $0.rawValue }, arranging: false)
        XCTAssertEqual(items.map(\.title), ["Move & Resize"])
        XCTAssertTrue(TileMenu.placementItems(target: nil, actions: actions, arranging: false).isEmpty)
    }

    func testTidyIsControlOptionA() {
        let tidy = TileMenu.placementItems(target: nil, actions: actions, arranging: true).first!
        XCTAssertEqual(tidy.keyEquivalent, "a")
        XCTAssertEqual(tidy.keyEquivalentModifierMask, [.control, .option])
        XCTAssertEqual(TileMenu.tidyKeysSummary, "⌃⌥A")
        XCTAssertEqual(TileMenu.tidyKeyCode, kVK_ANSI_A)
    }

    func testArrangeColumnsHaveDigitsAndTheGridsDoNot() {
        let arrange = TileMenu.placementItems(target: nil, actions: actions, arranging: true)[2].submenu!
        let items = arrange.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(items.map(\.title), ["2 Columns", "3 Columns", "4 Columns", "2×2", "3×2"])
        XCTAssertEqual(items.map(\.keyEquivalent), ["2", "3", "4", "", ""])
        XCTAssertEqual(items.prefix(3).map(\.keyEquivalentModifierMask), [[.control, .option], [.control, .option], [.control, .option]])
        XCTAssertEqual(TileMenu.arrangeKeysSummary, "⌃⌥ 2 · 3 · 4")
        XCTAssertEqual(TileMenu.arrangement(of: items[1])?.columns, 3)
        XCTAssertEqual(TileMenu.arrangement(of: items[4])?.rows, 2)
    }

    func testTidyByListsTheOrdersAndChecksTheCurrentOne() {
        let tidyBy = TileMenu.placementItems(target: nil, actions: actions, arranging: true)[1].submenu!
        XCTAssertEqual(tidyBy.items.map(\.title), ["Where They Are", "Most Recent", "App"])
        XCTAssertEqual(tidyBy.items.compactMap(TileMenu.order(of:)), Tidy.Order.allCases)
        let was = Settings.tidyOrder
        defer { Settings.tidyOrder = was }
        Settings.tidyOrder = .app
        tidyBy.delegate?.menuNeedsUpdate?(tidyBy)
        XCTAssertEqual(tidyBy.items.map(\.state), [.off, .off, .on])
    }

    func testMoveAndResizeKeysAreTheTilingShortcuts() {
        let menu = TileMenu.build(target: nil, action: #selector(NSObject.copy)) { $0.rawValue }
        let items = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(items.count, Tiling.Preset.allCases.count)
        for item in items {
            let preset = Tiling.Preset(rawValue: item.representedObject as! String)!
            XCTAssertEqual(item.keyEquivalent, TileMenu.shortcuts.first { $0.preset == preset }?.key ?? "")
        }
    }

    func testTheGuideShowsTheSameKeys() {
        XCTAssertEqual(PlacementGuide.Scope.window.keys, TileMenu.tileKeysSummary)
        XCTAssertEqual(PlacementGuide.Scope.screen.keys, TileMenu.arrangeKeysSummary)
        XCTAssertEqual(PlacementGuide.Scope.everything.keys, TileMenu.tidyKeysSummary)
        for scope in PlacementGuide.Scope.allCases {
            let demo = PlacementGuide.demo(for: scope)
            XCTAssertEqual(demo.before.count, demo.after.count)
            for i in demo.after.indices { for j in demo.after.indices where i < j { XCTAssertFalse(demo.after[i].intersects(demo.after[j]), "\(scope) \(i) \(j)") } }
        }
    }

    /// Each size shows a picture of where it puts the window, as macOS's Move & Resize menu.
    func testEverySizeHasAPicture() {
        let move = TileMenu.build(target: nil, action: #selector(NSObject.copy), represent: { $0.rawValue })
        let sizes = move.items.filter { !$0.isSeparatorItem }
        XCTAssertFalse(sizes.isEmpty)
        for item in sizes {
            XCTAssertNotNil(item.image, item.title)
            XCTAssertEqual(item.image?.isTemplate, true, item.title)
        }
        let arrange = TileMenu.arrangeMenu(target: nil, action: #selector(NSObject.copy)).items.filter { !$0.isSeparatorItem }
        XCTAssertTrue(arrange.allSatisfy { $0.image != nil })
    }
}
