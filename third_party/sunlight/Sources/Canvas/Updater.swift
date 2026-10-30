import AppKit
import Sparkle

/// Sparkle updates from the feed in Info.plist (`SUFeedURL`, with the `SUPublicEDKey` that checks each
/// update's signature). `scripts/package.sh` writes both from packaging/release.conf; a build without
/// them, `make run` from a checkout say, leaves Sparkle off and Check for Updates… disabled.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    /// The version Sparkle found on its own check, until it's installed; the menu bar panel offers it.
    private(set) var foundVersion: String?
    var onFoundUpdate: ((String?) -> Void)?

    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return !(info["SUFeedURL"] as? String ?? "").isEmpty && !(info["SUPublicEDKey"] as? String ?? "").isEmpty
    }

    override init() {
        super.init()
        // Sparkle asks once, on the second launch, whether to check automatically, and then follows that.
        controller = Self.isConfigured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
            : nil
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.foundVersion = version
                self.onFoundUpdate?(version)
            }
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.foundVersion = nil
                self.onFoundUpdate?(nil)
            }
        }
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates == true }

    /// Asks the feed first: until the first release is published (or while its repo is private) the feed
    /// is a 404, which Sparkle reports as "An error occurred in retrieving update information". That's
    /// not wrong, there's simply nothing newer yet, so it gets an up-to-date note instead. Anything else
    /// (offline, a server error, a real feed) goes to Sparkle as before.
    func checkForUpdates() {
        guard let controller else { return }
        guard let feed = (Bundle.main.infoDictionary?["SUFeedURL"] as? String).flatMap(URL.init(string:)) else {
            controller.checkForUpdates(nil)
            return
        }
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let notPublished = (response as? HTTPURLResponse)?.statusCode == 404
            DispatchQueue.main.async {
                if notPublished { Self.showNothingPublished() } else { controller.checkForUpdates(nil) }
            }
        }.resume()
    }

    private static func showNothingPublished() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Sunlight \(version) is the newest version. No update has been published yet."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
