import AppKit

/// Takeover's footprint on the Mac: a handful of Dock, Finder and widget preferences, written through
/// CFPreferences (what `defaults write` does) and picked up by restarting their owner. The originals
/// are snapshotted before the first write; an absent key is remembered as absent and deleted again on
/// revert, so the user's own settings come back exactly as they were.
enum SystemPrefs {
    struct Pref {
        let domain: String
        let key: String
        /// nil deletes the key while takeover is on, so the system default applies.
        let desired: Any?
        var id: String { "\(domain)|\(key)" }
    }

    static let dock = "com.apple.dock"
    static let finder = "com.apple.finder"
    static let widgets = "com.apple.widgets"
    static let absent = "<absent>"

    static let managed: [Pref] = [
        // The Dock: auto-hide only. It still slides out at the screen edge after the system's own delay;
        // clearing the delay also undoes the never-ending one an earlier build wrote (or one set by hand).
        Pref(domain: dock, key: "autohide", desired: true),
        Pref(domain: dock, key: "autohide-delay", desired: nil),
        // Mission Control, App Exposé and Show Desktop: gestures and hot corners can't be swallowed by a key tap.
        Pref(domain: dock, key: "showMissionControlGestureEnabled", desired: false),
        Pref(domain: dock, key: "showAppExposeGestureEnabled", desired: false),
        Pref(domain: dock, key: "showDesktopGestureEnabled", desired: false),
        Pref(domain: dock, key: "wvous-tl-corner", desired: 1),
        Pref(domain: dock, key: "wvous-tr-corner", desired: 1),
        Pref(domain: dock, key: "wvous-bl-corner", desired: 1),
        Pref(domain: dock, key: "wvous-br-corner", desired: 1),
        // Managed-preferences switch for Mission Control; honoured on some releases, harmless on others.
        Pref(domain: dock, key: "mcx-expose-disabled", desired: true),
        // Widgets: never dimmed. Notification Center dims desktop widgets to monochrome whenever an app is
        // in front of the desktop, and the canvas always is, so every widget proxy would be grey. This is
        // Desktop & Dock › Dim widgets on desktop: 0 Automatically, 1 Never, 2 Always. No restart:
        // System Settings changes it without one and posts no notification for it (unlike the Dock's
        // `com.apple.dock.prefchanged`), so Notification Center watches the key itself.
        Pref(domain: widgets, key: "widgetAppearance", desired: 1),
    ]

    /// Prefs takeover used to manage and no longer does. A Mac taken over by an earlier build has
    /// takeover's value in force and the user's own in the snapshot: the next apply puts the user's back
    /// and drops it from the snapshot (`retiredInSnapshot`), and a revert puts it back as well.
    static let retired: [Pref] = [
        // Finder's desktop icons, off until the desktop came back as the canvas's floor (`DesktopFloor`).
        Pref(domain: finder, key: "CreateDesktop", desired: false),
    ]

    static func current(_ p: Pref) -> Any? {
        CFPreferencesCopyAppValue(p.key as CFString, p.domain as CFString)
    }

    /// Records the current value of every managed pref not already in `existing`. A pref added to
    /// `managed` since takeover was first applied still holds the user's own value, so recording it on
    /// the next apply is as good as having recorded it then.
    static func snapshot(adding existing: [String: Any] = [:]) -> [String: Any] {
        var s = existing
        for p in managed where s[p.id] == nil { s[p.id] = current(p) ?? absent }
        return s
    }

    /// Writes every managed pref that differs from its takeover value. Returns the domains that changed;
    /// their owners need a restart to pick the values up.
    @discardableResult
    static func apply() -> Set<String> {
        write(managed.map { ($0, $0.desired) })
    }

    /// The retired prefs a snapshot still holds, each with the user's own value to put back (nil: the key
    /// was absent), and the snapshot without them.
    static func retiredInSnapshot(_ snapshot: [String: Any]) -> (restore: [(Pref, Any?)], remaining: [String: Any]) {
        var remaining = snapshot
        var restore: [(Pref, Any?)] = []
        for p in retired {
            guard let saved = remaining.removeValue(forKey: p.id) else { continue }
            restore.append((p, (saved as? String) == absent ? nil : saved))
        }
        return (restore, remaining)
    }

    /// Writes the user's own values back for retired prefs. Returns the domains that changed.
    @discardableResult
    static func restore(_ targets: [(Pref, Any?)]) -> Set<String> {
        write(targets)
    }

    /// Puts back what `snapshot()` recorded, retired prefs included. Keys that were absent are deleted,
    /// not defaulted.
    @discardableResult
    static func revert(snapshot: [String: Any]) -> Set<String> {
        write((managed + retired).compactMap { p in
            guard let saved = snapshot[p.id] else { return nil }
            return (p, (saved as? String) == absent ? nil : saved)
        })
    }

    private static func write(_ targets: [(Pref, Any?)]) -> Set<String> {
        var changed = Set<String>()
        for (p, target) in targets where !equal(current(p), target) {
            CFPreferencesSetAppValue(p.key as CFString, target.map { $0 as AnyObject }, p.domain as CFString)
            changed.insert(p.domain)
        }
        for d in changed { CFPreferencesAppSynchronize(d as CFString) }
        return changed
    }

    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return (a as AnyObject).isEqual(b)
        default: return false
        }
    }

    /// Same as `killall`: launchd brings the Dock and Finder straight back with the new values. The
    /// widget setting needs no restart. Returns the apps restarted.
    @discardableResult
    static func restart(domains: Set<String>) -> [String] {
        var restarted: [String] = []
        if domains.contains(dock) { restart(bundleID: "com.apple.dock"); restarted.append("Dock") }
        if domains.contains(finder) { restart(bundleID: "com.apple.finder"); restarted.append("Finder") }
        return restarted
    }

    private static func restart(bundleID: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            kill(app.processIdentifier, SIGTERM)
        }
    }

    static func describeCurrent() -> String {
        managed.map { p in
            let v = current(p).map { "\($0)" } ?? absent
            return "  \(p.domain) \(p.key) = \(v)"
        }.joined(separator: "\n")
    }
}
