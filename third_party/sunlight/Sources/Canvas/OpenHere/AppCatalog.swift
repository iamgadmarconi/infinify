import AppKit

struct AppEntry: Hashable, Sendable {
    let name: String
    let path: String
    var url: URL { URL(fileURLWithPath: path) }
}

/// The apps installed in the usual places, a small fuzzy matcher over their names, and a recents list
/// so the ones you actually open float to the top: what Open Here… lists. The folders are walked in the
/// background, and the icons of the first page decoded there too; whatever was loaded last is what
/// `search` sees until the next walk lands. One for every display's canvas.
@MainActor
final class AppCatalog {
    static let shared = AppCatalog()

    private(set) var apps: [AppEntry] = []
    /// A walk landed: results shown from the old list may want refreshing.
    var onUpdate: (() -> Void)?

    private var icons: [String: NSImage] = [:]
    private var loadedAt = Date.distantPast
    private var loading = false
    private let recentsKey = "launcher.recents"   // ⌘K's, kept: the same apps
    private static let queue = DispatchQueue(label: "canvas.catalog", qos: .utility)

    nonisolated private static let roots: [(path: String, depth: Int)] = [
        ("/Applications", 1),                      // one level of vendor folders
        ("/Applications/Utilities", 0),
        ("/System/Applications", 0),
        ("/System/Applications/Utilities", 0),
        ("/System/Library/CoreServices/Applications", 0),
        ("/System/Cryptexes/App/System/Applications", 0),   // Safari; its /Applications symlink is hidden
        (NSHomeDirectory() + "/Applications", 1),
    ]

    /// Walks the app folders in the background if the last walk is older than `maxAge`. Never blocks.
    func refresh(ifOlderThan maxAge: TimeInterval = 60) {
        guard !loading, Date().timeIntervalSince(loadedAt) > maxAge else { return }
        loading = true
        let recents = self.recents
        AppCatalog.queue.async { [weak self] in
            let found = AppCatalog.scan()
            // Icons for what an empty query shows first, so the first list draws without decoding any.
            let top = AppCatalog.ordered(found, recents: recents).prefix(24)
            let icons = IconBatch(icons: Dictionary(uniqueKeysWithValues: top.map { ($0.path, AppCatalog.loadIcon(path: $0.path)) }))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.apps = found
                    self.icons.merge(icons.icons) { _, new in new }
                    self.loadedAt = Date()
                    self.loading = false
                    self.onUpdate?()
                }
            }
        }
    }

    /// Images aren't Sendable by declaration; these are freshly made and handed over, never shared.
    private struct IconBatch: @unchecked Sendable {
        let icons: [String: NSImage]
    }

    nonisolated private static func scan() -> [AppEntry] {
        let fm = FileManager.default
        var seen = Set<String>()
        var found: [AppEntry] = []

        func scan(_ dir: URL, depth: Int) {
            let keys: [URLResourceKey] = [.isApplicationKey, .isDirectoryKey]
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
            for item in items {
                let values = try? item.resourceValues(forKeys: Set(keys))
                if values?.isApplication == true || item.pathExtension == "app" {
                    let path = item.standardizedFileURL.path
                    guard seen.insert(path).inserted else { continue }
                    var name = fm.displayName(atPath: path)
                    if name.hasSuffix(".app") { name.removeLast(4) }
                    found.append(AppEntry(name: name, path: path))
                } else if depth > 0, values?.isDirectory == true {
                    scan(item, depth: depth - 1)
                }
            }
        }
        for root in AppCatalog.roots { scan(URL(fileURLWithPath: root.path), depth: root.depth) }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Empty-query order: recents first, then everything alphabetically.
    nonisolated private static func ordered(_ apps: [AppEntry], recents: [String]) -> [AppEntry] {
        let byPath = Dictionary(apps.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let recentSet = Set(recents)
        return recents.compactMap { byPath[$0] } + apps.filter { !recentSet.contains($0.path) }
    }

    nonisolated private static func loadIcon(path: String) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 28, height: 28)
        return image
    }

    /// The app's icon, from the cache or decoded now (a row the walk didn't get to).
    func icon(for app: AppEntry) -> NSImage {
        if let cached = icons[app.path] { return cached }
        let image = AppCatalog.loadIcon(path: app.path)
        icons[app.path] = image
        return image
    }

    private var recents: [String] {
        UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
    }

    func noteLaunch(_ app: AppEntry) {
        var paths = recents
        paths.removeAll { $0 == app.path }
        paths.insert(app.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(20)), forKey: recentsKey)
    }

    /// Empty query: recents first, then everything alphabetically. Otherwise the best matches.
    func search(_ query: String, limit: Int = 40) -> [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let recents = self.recents
        if q.isEmpty { return Array(AppCatalog.ordered(apps, recents: recents).prefix(limit)) }
        let recentRank = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var scored: [(AppEntry, Int)] = []
        for app in apps {
            guard var s = AppCatalog.score(q, in: app.name.lowercased()) else { continue }
            if let r = recentRank[app.path] { s += max(0, 20 - r) }
            scored.append((app, s))
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
            .prefix(limit)
            .map { $0.0 }
    }

    /// Prefix beats word start beats substring beats a scattered subsequence.
    nonisolated static func score(_ q: String, in name: String) -> Int? {
        if name.hasPrefix(q) { return 100 }
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." })
        if words.contains(where: { $0.hasPrefix(q) }) { return 80 }
        if name.contains(q) { return 60 }
        var rest = name[...]
        var gaps = 0
        for (i, ch) in q.enumerated() {
            guard let at = rest.firstIndex(of: ch) else { return nil }
            if i > 0 { gaps += rest.distance(from: rest.startIndex, to: at) }
            rest = rest[rest.index(after: at)...]
        }
        return max(1, 40 - gaps)
    }
}
