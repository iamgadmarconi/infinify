import XCTest
@testable import Canvas

final class OpenHereTests: XCTestCase {
    // MARK: The bar's matcher

    func testANamesStartBeatsAWordStartBeatsAnywhereBeatsScatteredLetters() {
        let prefix = AppCatalog.score("saf", in: "safari")
        let word = AppCatalog.score("code", in: "visual studio code")
        let inside = AppCatalog.score("ari", in: "safari")
        let scattered = AppCatalog.score("sfr", in: "safari")
        XCTAssertEqual(prefix, 100)
        XCTAssertEqual(word, 80)
        XCTAssertEqual(inside, 60)
        XCTAssertEqual(scattered, 38)
    }

    func testLettersNotInTheNameDontMatch() {
        XCTAssertNil(AppCatalog.score("xyz", in: "safari"))
        XCTAssertNil(AppCatalog.score("ifas", in: "safari"))   // in the wrong order
    }

    // MARK: Which menu item makes a new window

    private func item(_ title: String, key: String? = nil, commandOnly: Bool = true, enabled: Bool = true,
                      submenu: Bool = false) -> NewWindowMenu.Item {
        NewWindowMenu.Item(title: title, key: key, commandOnly: key != nil && commandOnly, enabled: enabled, hasSubmenu: submenu)
    }

    func testSafarisNewWindowIsPickedOverItsOtherNewItems() {
        let items = [item("New Window", key: "N"), item("New Private Window", key: "N", commandOnly: false),
                     item("New Tab", key: "T")]
        XCTAssertEqual(NewWindowMenu.best(items), 0)
    }

    func testTerminalsDefaultProfileInsideItsNewWindowSubmenu() {
        let items = [item("New Window", submenu: true), item("New Tab", submenu: true),
                     item("New Window with Profile - Basic", key: "N"), item("New Window with Profile - Pro")]
        XCTAssertEqual(NewWindowMenu.best(items), 2)
    }

    func testANewWindowItemWithAnotherShortcutBeatsANewDocument() {
        // Xcode: New Window is ⇧⌘T, ⌘N makes a file.
        let items = [item("New File…", key: "N"), item("New Window", key: "T", commandOnly: false)]
        XCTAssertEqual(NewWindowMenu.best(items), 1)
    }

    func testOtherwiseCommandNMakesANewDocument() {
        let items = [item("New", key: "N"), item("Open…", key: "O")]
        XCTAssertEqual(NewWindowMenu.best(items), 0)
    }

    func testNothingDisabledAndNothingWithoutANewItem() {
        XCTAssertNil(NewWindowMenu.best([item("New Window", key: "N", enabled: false)]))
        XCTAssertNil(NewWindowMenu.best([item("Open…", key: "O"), item("Close", key: "W")]))
    }
}
