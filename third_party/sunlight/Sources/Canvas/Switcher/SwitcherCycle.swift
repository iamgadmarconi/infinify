import Foundation
import CoreGraphics

/// What ⌘Tab walks: apps on the outside, each app's windows on the inside, the way the Mac's own
/// switcher pairs ⌘Tab with ⌘`. Every stop is still a window, because the camera flies to windows.
///
/// Apps: the one you're in first (so the first Tab lands on the one before, as on the Mac), then apps
/// by their most recently entered window, then apps never entered, by their leftmost window. Windows
/// within an app: the one you're in, then recently entered ones, then the rest left to right. Landing
/// on an app picks its first window. The canvas itself isn't a stop. Pure data, so it's unit-tested.
struct SwitcherCycle: Equatable {
    struct Window: Equatable {
        let id: CGWindowID
        let pid: pid_t
        /// Where it sits on the canvas: the order of windows (and apps) nobody has entered.
        let position: CGPoint
    }

    struct App: Equatable {
        let pid: pid_t
        var windows: [CGWindowID]
    }

    private(set) var apps: [App]
    private(set) var appIndex = 0
    private(set) var windowIndex = 0

    /// `recent`: entered windows, most recent first. `current`: the window you're in, if any.
    init(windows: [Window], recent: [CGWindowID], current: CGWindowID?) {
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rank: [CGWindowID: Int] = [:]
        if let current, byID[current] != nil { rank[current] = 0 }
        for id in recent where byID[id] != nil && rank[id] == nil { rank[id] = rank.count }
        let unentered = windows.filter { rank[$0.id] == nil }
            .sorted { ($0.position.x, $0.position.y) < ($1.position.x, $1.position.y) }
        for w in unentered { rank[w.id] = rank.count }

        // Every window has a rank now; an app's place is its best-ranked window's.
        var order: [pid_t] = []
        var grouped: [pid_t: [CGWindowID]] = [:]
        for id in rank.sorted(by: { $0.value < $1.value }).map({ $0.key }) {
            guard let pid = byID[id]?.pid else { continue }
            if grouped[pid] == nil { order.append(pid) }
            grouped[pid, default: []].append(id)
        }
        apps = order.map { App(pid: $0, windows: grouped[$0] ?? []) }
    }

    var isEmpty: Bool { apps.isEmpty }
    var selectedApp: App? { apps.indices.contains(appIndex) ? apps[appIndex] : nil }
    var selectedWindow: CGWindowID? {
        guard let app = selectedApp, app.windows.indices.contains(windowIndex) else { return nil }
        return app.windows[windowIndex]
    }

    /// Tab and ⇧Tab. With a single app there's nowhere else to go, so its windows take the step.
    mutating func stepApp(by steps: Int) {
        guard !apps.isEmpty else { return }
        if apps.count == 1 {
            stepWindow(by: steps)
            return
        }
        appIndex = Self.wrap(appIndex + steps, apps.count)
        windowIndex = 0
    }

    /// ⌘` and ⌘↓ (⇧ or ↑ go back): the selected app's windows, wrapping within the app.
    mutating func stepWindow(by steps: Int) {
        guard let app = selectedApp, !app.windows.isEmpty else { return }
        windowIndex = Self.wrap(windowIndex + steps, app.windows.count)
    }

    /// The pointer on an icon: that app, its first window.
    mutating func select(app index: Int) {
        guard apps.indices.contains(index), index != appIndex else { return }
        appIndex = index
        windowIndex = 0
    }

    /// The pointer on a window chip.
    mutating func select(app index: Int, window: Int) {
        guard apps.indices.contains(index), apps[index].windows.indices.contains(window) else { return }
        appIndex = index
        windowIndex = window
    }

    /// Windows that left the canvas while ⌘ was down go; an app without windows goes with them. The
    /// selection stays on the same window if it's still here, else moves to what took its place.
    mutating func keep(only alive: Set<CGWindowID>) {
        let selected = selectedWindow
        let selectedPID = selectedApp?.pid
        let pruned = apps.map { App(pid: $0.pid, windows: $0.windows.filter(alive.contains)) }.filter { !$0.windows.isEmpty }
        guard pruned != apps else { return }
        let oldIndex = appIndex
        apps = pruned
        if let selected, let a = apps.firstIndex(where: { $0.windows.contains(selected) }) {
            appIndex = a
            windowIndex = apps[a].windows.firstIndex(of: selected) ?? 0
        } else if let pid = selectedPID, let a = apps.firstIndex(where: { $0.pid == pid }) {
            appIndex = a
            windowIndex = min(windowIndex, apps[a].windows.count - 1)
        } else {
            appIndex = apps.isEmpty ? 0 : min(oldIndex, apps.count - 1)
            windowIndex = 0
        }
    }

    private static func wrap(_ i: Int, _ n: Int) -> Int { ((i % n) + n) % n }
}
