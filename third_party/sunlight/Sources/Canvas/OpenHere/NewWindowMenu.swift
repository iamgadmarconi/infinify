import AppKit
import ApplicationServices

/// Asks a running app for a new window by pressing its own menu item through Accessibility, without
/// bringing it forward, as Move & Resize is pressed (`NativeTiling`). Open Here… uses it for an app
/// that already has windows, where a reopen event would only bring one of them back.
enum NewWindowMenu {
    /// What a menu item offers, as far as picking one goes.
    struct Item: Equatable {
        var title: String
        /// AXMenuItemCmdChar, upper-cased; nil without a shortcut.
        var key: String?
        /// ⌘ and no other modifier (AXMenuItemCmdModifiers 0).
        var commandOnly: Bool
        var enabled: Bool
        var hasSubmenu: Bool
    }

    /// The item to press, best first: ⌘N that says it's a window ("New Window", "New Finder Window",
    /// Terminal's "New Window with Profile"), then an item named New Window, then any ⌘N (a new
    /// document, which is a window in most apps). Pure, for tests.
    static func best(_ items: [Item]) -> Int? {
        let usable = items.indices.filter { items[$0].enabled && !items[$0].hasSubmenu }
        let commandN = usable.filter { items[$0].key == "N" && items[$0].commandOnly }
        if let i = commandN.first(where: { items[$0].title.localizedCaseInsensitiveContains("window") }) { return i }
        if let i = usable.first(where: { items[$0].title.caseInsensitiveCompare("New Window") == .orderedSame }) { return i }
        return commandN.first
    }

    /// Presses the app's new-window item. Call off the main thread: every step is a round trip to the
    /// app. False if it has no such item or the press didn't go through.
    static func press(pid: pid_t) -> Bool {
        let app = AXWindow.application(pid, timeout: 0.5)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return false }
        let bar = ref as! AXUIElement
        var elements: [AXUIElement] = []
        var items: [Item] = []
        func collect(_ menu: AXUIElement, depth: Int) {
            for element in menu.children {
                let title = element.string(kAXTitleAttribute) ?? ""
                let submenu = element.children.first
                elements.append(element)
                items.append(Item(title: title,
                                  key: element.string(kAXMenuItemCmdCharAttribute)?.uppercased(),
                                  commandOnly: element.int(kAXMenuItemCmdModifiersAttribute) == 0,
                                  enabled: element.bool(kAXEnabledAttribute),
                                  hasSubmenu: submenu != nil))
                // Terminal's New Window is a submenu of profiles; ⌘N is the default one inside it.
                if depth == 0, let submenu, title.localizedCaseInsensitiveContains("window") {
                    collect(submenu, depth: 1)
                }
            }
        }
        // The Apple menu first, and nothing there opens a window.
        for barItem in bar.children.dropFirst() {
            for menu in barItem.children { collect(menu, depth: 0) }
        }
        guard let i = best(items) else { return false }
        NSLog("Open Here: pressing “\(items[i].title)”")
        return AXUIElementPerformAction(elements[i], kAXPressAction as CFString) == .success
    }
}
