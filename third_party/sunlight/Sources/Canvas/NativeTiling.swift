import ApplicationServices
import Foundation
import Carbon.HIToolbox

/// macOS's own window tiling (macOS 15+), driven through the app's menu bar: every app's
/// Window › Move & Resize submenu holds the system's tiling commands, and pressing one through
/// Accessibility tiles the app's main window exactly as the menu or fn⌃ shortcut would, with the
/// system's animation and margins, and with macOS remembering the size to go back to.
///
/// The submenu is found by its fixed shortcuts (fn⌃ arrows, fn⌃F, fn⌃C), not its titles, so it's
/// found in any language. Quarters have no shortcut and are matched by their English titles, so
/// other languages fall back to Sunlight's own placement for those.
enum NativeTiling {
    /// Presets macOS tiles itself. The rest (thirds, two-thirds) are Sunlight's.
    static func supports(_ preset: Tiling.Preset) -> Bool { item(for: preset) != nil }

    private enum Item {
        case shortcut(key: Int, glyph: Int, character: UInt32)
        case letter(String)
        case title(String)
    }

    /// How each preset's menu item is recognised. Arrows are matched any way Accessibility may report
    /// them: virtual key code, menu glyph, or the function-key character.
    private static func item(for preset: Tiling.Preset) -> Item? {
        switch preset {
        case .leftHalf: return .shortcut(key: kVK_LeftArrow, glyph: 0x64, character: 0xF702)
        case .rightHalf: return .shortcut(key: kVK_RightArrow, glyph: 0x65, character: 0xF703)
        case .topHalf: return .shortcut(key: kVK_UpArrow, glyph: 0x68, character: 0xF700)
        case .bottomHalf: return .shortcut(key: kVK_DownArrow, glyph: 0x6A, character: 0xF701)
        case .full: return .letter("F")
        case .center: return .letter("C")
        case .topLeft: return .title("Top Left")
        case .topRight: return .title("Top Right")
        case .bottomLeft: return .title("Bottom Left")
        case .bottomRight: return .title("Bottom Right")
        default: return nil
        }
    }

    /// Presses the app's Move & Resize item for `preset`, acting on its main window. Call off the main
    /// thread: every step is a round trip to the app. False if the app has no such item (older macOS,
    /// an app without a standard Window menu, a quarter in another language).
    static func tile(pid: pid_t, _ preset: Tiling.Preset) -> Bool {
        guard let want = item(for: preset), let menu = moveAndResizeMenu(pid: pid) else { return false }
        for element in menu.children {
            if matches(element, want) {
                return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    /// The submenu holding ⌃← and ⌃→ (no ⌘): Window › Move & Resize. Searched two levels under each
    /// menu bar item, since it's a submenu of the Window menu.
    private static func moveAndResizeMenu(pid: pid_t) -> AXUIElement? {
        let app = AXWindow.application(pid, timeout: 0.5)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let bar = ref as! AXUIElement
        let left = item(for: .leftHalf)!, right = item(for: .rightHalf)!
        // The Window menu is near the end; look there first.
        for barItem in bar.children.reversed() {
            for menu in barItem.children {
                for entry in menu.children {
                    for submenu in entry.children {
                        let items = submenu.children
                        if items.contains(where: { matches($0, left) }), items.contains(where: { matches($0, right) }) {
                            return submenu
                        }
                    }
                }
            }
        }
        return nil
    }

    /// ⌃ without ⌘ (fn isn't reported), and nothing else: AXMenuItemCmdModifiers' control (1 << 2) and
    /// no-command (1 << 3) bits, which the SDK doesn't export to Swift.
    private static let controlOnly = 1 << 2 | 1 << 3

    private static func matches(_ element: AXUIElement, _ want: Item) -> Bool {
        switch want {
        case .title(let title):
            return element.string(kAXTitleAttribute) == title
        case .letter(let letter):
            guard element.int(kAXMenuItemCmdModifiersAttribute) == controlOnly else { return false }
            return element.string(kAXMenuItemCmdCharAttribute)?.uppercased() == letter
        case .shortcut(let key, let glyph, let character):
            guard element.int(kAXMenuItemCmdModifiersAttribute) == controlOnly else { return false }
            if element.int(kAXMenuItemCmdVirtualKeyAttribute) == key { return true }
            if element.int(kAXMenuItemCmdGlyphAttribute) == glyph { return true }
            if let c = element.string(kAXMenuItemCmdCharAttribute)?.unicodeScalars.first, c.value == character { return true }
            return false
        }
    }
}

extension AXUIElement {
    func int(_ attribute: String) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.intValue
    }
}
