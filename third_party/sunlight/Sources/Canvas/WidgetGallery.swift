import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Notification Center's widget gallery, where new desktop widgets come from: you drag one out of it onto
/// the desktop. Opening it puts the desktop in edit mode, which takes every app window off the screen — the
/// canvas too, `.stationary` or not — until Done brings them all back (measured on 27.2).
///
/// There's no API to open it. Two menus offer it as "Edit Widgets…": a desktop widget's own context menu,
/// which Accessibility can open and press, and Finder's desktop menu, the only way in while there's no
/// widget yet. (Notification Center's panel no longer has the button on 27.2: widgets moved to the desktop.)
enum WidgetGallery {
    /// "Edit Widgets…" in Notification Center's words.
    static let editTitles = Widgets.titles("Edit Widgets…")
    /// The gallery's Done button (27.2).
    static let doneIdentifier = "widget-add-sheet-done"

    /// Opens the gallery through `widget`'s context menu, or Finder's desktop menu when there's no widget
    /// (or its menu fails). False when neither menu could be used: no widget, and Finder isn't drawing the
    /// desktop. True means the item was picked, not that the gallery is up yet: `window()` tells.
    static func open(from widget: AXWidget?, completion: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var opened = widget?.pressThroughMenu(editTitles) ?? false
            if !opened { opened = FinderDesktop.openGallery() }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(opened) } }
        }
    }

    /// The gallery's window, once it's up: the Notification Center window with the Done button in it.
    /// Accessibility's window ID for it isn't the one on screen (27.2), so it's followed through
    /// Accessibility instead (`isShowing`).
    static func window() -> AXUIElement? {
        guard let nc = NSRunningApplication.runningApplications(withBundleIdentifier: Widgets.ownerBundleID).first else { return nil }
        return AXWindow.application(nc.processIdentifier).elements(kAXWindowsAttribute).first(where: hasDoneButton)
    }

    /// The gallery is still there and not slid away below the screen.
    static func isShowing(_ gallery: AXUIElement) -> Bool {
        guard let frame = gallery.frame, let screen = NSScreen.screens.first else { return false }
        return frame.minY < screen.frame.height
    }

    /// Window → hosting view → Done on 27.2; a level deeper is tolerated. Breadth first, so the gallery's
    /// long list of apps is never walked.
    private static func hasDoneButton(_ window: AXUIElement) -> Bool {
        var level = [window]
        for _ in 0..<3 {
            level = level.flatMap(\.children)
            if level.contains(where: { $0.string(kAXIdentifierAttribute) == doneIdentifier }) { return true }
        }
        return false
    }

    /// Whether a window is on screen right now. Edit mode takes windows off the screen without closing
    /// them, so this is how the canvas sees it start and end on its own window.
    static func isOnScreen(_ id: CGWindowID) -> Bool {
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
        return info.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }
}

/// Finder's desktop, for its context menu: its "Edit Widgets…" opens the gallery with no widget around.
/// Finder answers the request to show the menu, but doesn't expose the open menu to Accessibility. It does
/// take keys, as a user's typing: the title selects the item and ⏎ picks it. Keys go to Finder only, and
/// only while its menu is on screen, so they can never land in a Finder window instead.
enum FinderDesktop {
    static let bundleID = "com.apple.finder"

    /// Blocks for up to ~2 s; call it off the main thread. False when Finder doesn't draw the desktop
    /// (Show Items › On Desktop off, or `CreateDesktop` false) or the menu didn't open.
    static func openGallery() -> Bool {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let title = editTitle else { return false }
        let pid = finder.processIdentifier
        // The desktop is a full-screen scroll area among Finder's windows, holding a group with the menu.
        guard let desktop = AXWindow.application(pid, timeout: 0.5).elements(kAXWindowsAttribute)
                .first(where: { $0.string(kAXRoleAttribute) == kAXScrollAreaRole })?
                .children.first(where: { $0.actions.contains(kAXShowMenuAction) }) else { return false }

        AXUIElementSetMessagingTimeout(desktop, 2)
        // Finder may not answer until the menu closes again; don't wait for it.
        DispatchQueue.global(qos: .userInitiated).async {
            AXUIElementPerformAction(desktop, kAXShowMenuAction as CFString)
        }
        guard wait(upTo: 1, for: { menuIsOpen(pid) }) else { return false }
        for character in title {
            guard menuIsOpen(pid) else { return false }
            post(text: String(character), to: pid)
            usleep(15_000)
        }
        usleep(100_000)   // the menu takes a beat to move its selection
        guard menuIsOpen(pid) else { return false }
        post(key: CGKeyCode(kVK_Return), to: pid)
        if !wait(upTo: 1, for: { !menuIsOpen(pid) }) {
            post(key: CGKeyCode(kVK_Escape), to: pid)
            return false
        }
        return true
    }

    /// "Edit Widgets…" as Finder words it in the user's language, without the ellipsis, for typing. Its
    /// key is opaque ("N164.5" on 27.2), so it's found by the English title.
    static let editTitle: String? = {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url),
              let key = table(bundle, localization: "en")?.first(where: { $0.value == "Edit Widgets…" })?.key else { return nil }
        let language = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: Locale.preferredLanguages).first ?? "en"
        let title = table(bundle, localization: language)?[key] ?? "Edit Widgets…"
        return title.trimmingCharacters(in: CharacterSet(charactersIn: "….").union(.whitespaces))
    }()

    private static func table(_ bundle: Bundle, localization: String) -> [String: String]? {
        bundle.url(forResource: "LocalizableMerged", withExtension: "strings", subdirectory: nil, localization: localization)
            .flatMap { NSDictionary(contentsOf: $0) as? [String: String] }
    }

    private static func menuIsOpen(_ pid: pid_t) -> Bool {
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == level
        }
    }

    private static func wait(upTo seconds: TimeInterval, for condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(25_000)
        }
        return condition()
    }

    /// A typed character: the key code doesn't matter, the event carries the text.
    private static func post(text: String, to pid: pid_t) {
        post(key: 0, text: text, to: pid)
    }

    private static func post(key: CGKeyCode, text: String? = nil, to pid: pid_t) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
            if let text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.postToPid(pid)
        }
    }
}
