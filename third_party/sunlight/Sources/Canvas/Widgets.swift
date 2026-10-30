import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit

/// Desktop widgets (macOS 14+), as the canvas sees them.
///
/// Notification Center draws every widget placed on the desktop in a borderless window of its own, just
/// above the desktop icons (layer -2147483601 on 27.2), so ScreenCaptureKit streams one from behind the
/// canvas like any other window. The card sits inside a transparent margin in that window. Accessibility
/// describes the rest: the window holds a hosting view whose child is the widget itself, identified as
/// `widget-local:<app bundle ID>:<extension bundle ID>:<kind>` (`widget-remote:` for an iPhone widget),
/// named the way VoiceOver says it, with the card's frame and a context menu.
enum Widgets {
    static let ownerBundleID = "com.apple.notificationcenterui"
    /// The card's margin inside Notification Center's window when Accessibility can't measure it
    /// (27.2: a 344 × 164 card in a 360 × 180 window).
    static let defaultInset: CGFloat = 8
    /// The card's corner radius, on a continuous curve (measured from a capture on 27.2).
    static let cornerRadius: CGFloat = 20

    /// A widget on the desktop. Notification Center's other windows (its panel, banners) sit above
    /// normal windows; only the widgets sit below them.
    static func isWidget(_ w: SCWindow) -> Bool {
        w.owningApplication?.bundleIdentifier == ownerBundleID && w.windowLayer < 0
            && w.frame.width >= 40 && w.frame.height >= 40
    }

    /// The same test on the window server's listing; `bundleID` is the owner's.
    static func isWidget(_ w: WindowInfo, bundleID: String?) -> Bool {
        bundleID == ownerBundleID && w.layer < 0 && w.bounds.width >= 40 && w.bounds.height >= 40
    }

    /// One of Notification Center's strings ("Remove Widget") as it words it in the user's language, and
    /// in English.
    static func titles(_ key: String) -> Set<String> {
        var titles: Set<String> = [key]
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ownerBundleID),
              let table = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Resources/Localizable.loctable"))
                  as? [String: [String: Any]],
              let language = Bundle.preferredLocalizations(from: Array(table.keys), forPreferences: Locale.preferredLanguages).first,
              let title = table[language]?[key] as? String else { return titles }
        titles.insert(title)
        return titles
    }
}

/// A handle on one desktop widget through Notification Center's Accessibility tree.
/// All coordinates are Quartz style: top-left origin, points.
struct AXWidget: @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t
    /// E.g. `widget-local:com.apple.weather:com.apple.weather.widget:com.apple.weather`.
    let identifier: String
    /// What VoiceOver calls it, e.g. "Weather".
    let name: String

    /// The widget in the Notification Center window with this ID.
    static func find(windowID: CGWindowID, pid: pid_t, approximateFrame: CGRect) -> AXWidget? {
        guard let window = AXWindow.find(windowID: windowID, pid: pid, approximateFrame: approximateFrame) else { return nil }
        // Window → hosting view → widget on 27.2; look a level or two deeper in case that changes.
        var level = [window.element]
        for _ in 0..<4 {
            for e in level {
                guard let id = e.string(kAXIdentifierAttribute), id.hasPrefix("widget-") else { continue }
                AXUIElementSetMessagingTimeout(e, 0.5)
                return AXWidget(element: e, pid: pid, identifier: id, name: e.string(kAXDescriptionAttribute) ?? "")
            }
            level = level.flatMap(\.children)
        }
        return nil
    }

    /// The app the widget belongs to, when it's on this Mac (an iPhone widget's isn't).
    var appBundleID: String? {
        let parts = identifier.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "widget-local", !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    /// The card on screen.
    var frame: CGRect? { element.frame }

    /// Presses the control under a screen point — a button or toggle in an interactive widget — as
    /// VoiceOver would. False when there's none there: the rest of a widget is a link to its app.
    func press(at point: CGPoint) -> Bool {
        guard let control = AXWidget.control(at: point, in: element, depth: 0) else { return false }
        return AXUIElementPerformAction(control, kAXPressAction as CFString) == .success
    }

    /// The deepest pressable element under the point: a toggle inside a pressable row is the one meant.
    private static func control(at point: CGPoint, in e: AXUIElement, depth: Int) -> AXUIElement? {
        if depth < 10 {
            for child in e.children where child.frame?.contains(point) ?? true {
                if let hit = control(at: point, in: child, depth: depth + 1) { return hit }
            }
        }
        return depth > 0 && e.actions.contains(kAXPressAction) ? e : nil
    }

    /// "Remove Widget" from the widget's own context menu, the way it's taken off the desktop. The menu
    /// pops up over the real widget for the moment it takes to find the item.
    func remove(completion: @escaping @MainActor (Bool) -> Void) {
        pressMenuItem(AXWidget.removeTitles, completion: completion)
    }

    /// Runs off the main thread: Notification Center may not answer the show-menu request until its menu
    /// has closed again.
    private func pressMenuItem(_ titles: Set<String>, completion: @escaping @MainActor (Bool) -> Void) {
        let widget = self
        DispatchQueue.global(qos: .userInitiated).async {
            let pressed = widget.pressThroughMenu(titles)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(pressed) } }
        }
    }

    /// Shows the widget's context menu and presses the item with one of these titles. False if there's
    /// no such item. Blocks while it waits for the menu: call it off the main thread.
    func pressThroughMenu(_ titles: Set<String>) -> Bool {
        let shown = AXUIElementPerformAction(element, kAXShowMenuAction as CFString)
        // A timeout means Notification Center is busy putting the menu up; look for it anyway.
        guard shown == .success || shown == .cannotComplete else { return false }
        let app = AXWindow.application(pid, timeout: 0.5)
        for _ in 0..<20 {
            for menu in openMenus(app: app) {
                if let item = menu.children.first(where: { titles.contains($0.string(kAXTitleAttribute) ?? "") }) {
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
            usleep(25_000)
        }
        // No such item, or no menu we can see: put away whatever came up.
        let menus = openMenus(app: app)
        menus.forEach { AXUIElementPerformAction($0, kAXCancelAction as CFString) }
        if menus.isEmpty {
            for down in [true, false] {
                CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: down)?.postToPid(pid)
            }
        }
        return false
    }

    /// A context menu turns up at the top of the app's tree, under the element it belongs to, or next to
    /// it: on 27.2 it's a child of the widget's hosting view.
    private func openMenus(app: AXUIElement) -> [AXUIElement] {
        (app.children + element.children + (element.parent?.children ?? [])).filter { $0.string(kAXRoleAttribute) == kAXMenuRole }
    }

    private static let removeTitles = Widgets.titles("Remove Widget")
}
