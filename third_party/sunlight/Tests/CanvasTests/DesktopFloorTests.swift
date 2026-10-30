import Carbon.HIToolbox
import XCTest
@testable import Canvas

final class DesktopFloorTests: XCTestCase {
    private func info(layer: Int, size: CGSize = CGSize(width: 1512, height: 982)) -> WindowInfo {
        WindowInfo(id: 7284, pid: 1, layer: layer, bounds: CGRect(origin: .zero, size: size), title: nil, alpha: 1)
    }

    func testFindersDesktopIconWindowIsTheFloor() {
        XCTAssertEqual(DesktopFloor.iconLevel, -2147483603)   // kCGDesktopIconWindowLevel, as listed on 27.2
        XCTAssertTrue(DesktopFloor.isDesktop(info(layer: DesktopFloor.iconLevel), bundleID: "com.apple.finder"))
    }

    func testOtherWindowsAreNot() {
        // A Finder window at the normal level, the wallpaper's level, or a widget's.
        XCTAssertFalse(DesktopFloor.isDesktop(info(layer: 0), bundleID: "com.apple.finder"))
        XCTAssertFalse(DesktopFloor.isDesktop(info(layer: -2147483624), bundleID: "com.apple.finder"))
        // The desktop level, but someone else's window, or a small one.
        XCTAssertFalse(DesktopFloor.isDesktop(info(layer: DesktopFloor.iconLevel), bundleID: "com.apple.WindowManager"))
        XCTAssertFalse(DesktopFloor.isDesktop(info(layer: DesktopFloor.iconLevel), bundleID: nil))
        XCTAssertFalse(DesktopFloor.isDesktop(info(layer: DesktopFloor.iconLevel, size: CGSize(width: 64, height: 64)),
                                              bundleID: "com.apple.finder"))
    }

    // MARK: Files

    func testANewFolderTakesTheFirstFreeUntitledName() {
        XCTAssertEqual(DesktopFiles.untitledFolderName(existing: ["Notes.txt"]), "untitled folder")
        XCTAssertEqual(DesktopFiles.untitledFolderName(existing: ["Untitled Folder"]), "untitled folder 2")
        XCTAssertEqual(DesktopFiles.untitledFolderName(existing: ["untitled folder", "untitled folder 2", "untitled folder 4"]),
                       "untitled folder 3")
    }

    func testRenamesNeedARealNewName() {
        XCTAssertEqual(DesktopFiles.validRename("  Plans.pdf ", from: "Draft.pdf"), "Plans.pdf")
        XCTAssertNil(DesktopFiles.validRename("Draft.pdf", from: "Draft.pdf"))
        XCTAssertNil(DesktopFiles.validRename("   ", from: "Draft.pdf"))
        XCTAssertNil(DesktopFiles.validRename("a/b", from: "Draft.pdf"))
        XCTAssertNil(DesktopFiles.validRename("..", from: "Draft.pdf"))
    }

    func testAFileIsHitOnItsPictureAndItsLabel() {
        let icon = DesktopIcon(element: AXUIElementCreateSystemWide(), name: "Plans.pdf", url: nil,
                               frame: CGRect(x: 1400, y: 40, width: 64, height: 64))
        XCTAssertTrue(icon.hitRect.contains(CGPoint(x: 1432, y: 72)))    // the picture
        XCTAssertTrue(icon.hitRect.contains(CGPoint(x: 1385, y: 115)))   // a long label, under it
        XCTAssertFalse(icon.hitRect.contains(CGPoint(x: 1432, y: 150)))  // below the label
    }

    // MARK: Selecting

    private func click(_ key: String, in selection: [String], command: Bool = false, shift: Bool = false,
                       released: Bool = false) -> [String]? {
        DesktopFiles.click(on: key, in: selection, command: command, shift: shift, released: released)
    }

    func testAClickSelectsJustThatFile() {
        XCTAssertEqual(click("a", in: []), ["a"])
        XCTAssertEqual(click("b", in: ["a"]), ["b"])
        XCTAssertNil(click("a", in: ["a"]))
    }

    func testCommandTogglesAndShiftAdds() {
        XCTAssertEqual(click("b", in: ["a"], command: true), ["a", "b"])
        XCTAssertEqual(click("a", in: ["a", "b"], command: true), ["b"])
        XCTAssertEqual(click("b", in: ["a"], shift: true), ["a", "b"])
        XCTAssertNil(click("a", in: ["a", "b"], shift: true))
    }

    func testPressingASelectedFileKeepsTheOthersForADragUntilItsLetGo() {
        XCTAssertNil(click("a", in: ["a", "b"]))
        XCTAssertEqual(click("a", in: ["a", "b"], released: true), ["a"])
        XCTAssertNil(click("a", in: ["a", "b"], command: true, released: true))
        XCTAssertNil(click("a", in: ["a"], released: true))
    }

    // MARK: Keys

    func testFindersDesktopKeys() {
        XCTAssertEqual(DesktopFiles.command(keyCode: kVK_ANSI_O, modifiers: .command), .open)
        XCTAssertEqual(DesktopFiles.command(keyCode: kVK_DownArrow, modifiers: [.command, .numericPad, .function]), .open)
        XCTAssertEqual(DesktopFiles.command(keyCode: kVK_Delete, modifiers: .command), .trash)
        XCTAssertEqual(DesktopFiles.command(keyCode: kVK_ANSI_C, modifiers: .command), .copy)
        XCTAssertEqual(DesktopFiles.command(keyCode: kVK_Return, modifiers: []), .rename)
        XCTAssertEqual(DesktopFiles.command(keyCode: kVK_ANSI_A, modifiers: .command), .selectAll)
        XCTAssertEqual(DesktopFiles.command(keyCode: kVK_Escape, modifiers: []), .deselect)
    }

    func testOtherKeysAreTheCanvas() {
        XCTAssertNil(DesktopFiles.command(keyCode: kVK_Delete, modifiers: []))          // plain ⌫ doesn't trash
        XCTAssertNil(DesktopFiles.command(keyCode: kVK_Return, modifiers: .command))
        XCTAssertNil(DesktopFiles.command(keyCode: kVK_ANSI_O, modifiers: [.command, .shift]))
        XCTAssertNil(DesktopFiles.command(keyCode: kVK_ANSI_Z, modifiers: .command))     // undo stays undo
    }
}
