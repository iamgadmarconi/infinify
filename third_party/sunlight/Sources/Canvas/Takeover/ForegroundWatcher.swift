import AppKit
import ApplicationServices

/// What the rest of the system does while the canvas is not in front: app activations and exits from
/// NSWorkspace, plus one Accessibility observer on the entered (or about-to-be-entered) app.
@MainActor
final class ForegroundWatcher {
    var onForeignActivation: ((NSRunningApplication) -> Void)?
    /// Hidden or terminated.
    var onAppGone: ((pid_t) -> Void)?
    var onFocusedWindowChanged: ((pid_t, AXUIElement) -> Void)?
    var onWindowCreated: ((pid_t, AXUIElement) -> Void)?
    var onWindowMiniaturized: ((pid_t, AXUIElement) -> Void)?
    var onEnteredWindowDestroyed: ((pid_t) -> Void)?

    private var tokens: [NSObjectProtocol] = []
    private var observer: AXAppObserver?
    private(set) var observedPID: pid_t = 0

    func start() {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let app = ForegroundWatcher.application
        tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let a = app(n) else { return }
            MainActor.assumeIsolated { self?.onForeignActivation?(a) }
        })
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let a = app(n) else { return }
                MainActor.assumeIsolated { self?.onAppGone?(a.processIdentifier) }
            })
        }
    }

    nonisolated private static func application(_ n: Notification) -> NSRunningApplication? {
        n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    func stop() {
        tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        tokens = []
        stopObserving()
    }

    /// Watches one app's focus and windows; `window` is the entered window, whose destruction we care about.
    func observe(pid: pid_t, window: AXUIElement?) {
        if observedPID != pid || observer == nil {
            observer = AXAppObserver(pid: pid) { [weak self] name, element in
                self?.axEvent(pid: pid, name: name, element: element)
            }
            observedPID = pid
        }
        observer?.watch(window: window)
    }

    func stopObserving() {
        observer = nil
        observedPID = 0
    }

    private func axEvent(pid: pid_t, name: String, element: AXUIElement) {
        switch name {
        case kAXFocusedWindowChangedNotification: onFocusedWindowChanged?(pid, element)
        case kAXWindowCreatedNotification: onWindowCreated?(pid, element)
        case kAXWindowMiniaturizedNotification: onWindowMiniaturized?(pid, element)
        case kAXUIElementDestroyedNotification: onEnteredWindowDestroyed?(pid)
        default: break
        }
    }
}

/// One AXObserver on one app. Its run-loop source sits on the main run loop, so callbacks arrive on
/// the main thread.
final class AXAppObserver {
    typealias Handler = @MainActor (String, AXUIElement) -> Void

    let pid: pid_t
    private let observer: AXObserver
    private let app: AXUIElement
    private var window: AXUIElement?
    private let handler: Handler

    private static let appNotifications = [
        kAXFocusedWindowChangedNotification,
        kAXWindowCreatedNotification,
        kAXWindowMiniaturizedNotification,
    ]

    init?(pid: pid_t, handler: @escaping Handler) {
        var created: AXObserver?
        guard AXObserverCreate(pid, AXAppObserver.callback, &created) == .success, let created else {
            NSLog("AXObserver: create failed for pid \(pid)")
            return nil
        }
        self.pid = pid
        self.observer = created
        self.app = AXWindow.application(pid)
        self.handler = handler
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        for name in AXAppObserver.appNotifications { add(name, to: app) }
    }

    func watch(window element: AXUIElement?) {
        if let old = window {
            AXObserverRemoveNotification(observer, old, kAXUIElementDestroyedNotification as CFString)
        }
        window = element
        if let element { add(kAXUIElementDestroyedNotification, to: element) }
    }

    deinit {
        for name in AXAppObserver.appNotifications {
            AXObserverRemoveNotification(observer, app, name as CFString)
        }
        if let window {
            AXObserverRemoveNotification(observer, window, kAXUIElementDestroyedNotification as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    /// A launching app, or an Electron/Chromium app enabling accessibility lazily, answers
    /// `cannotComplete` for a while; keep trying for a few seconds.
    private func add(_ name: String, to element: AXUIElement, attempt: Int = 0) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let err = AXObserverAddNotification(observer, element, name as CFString, refcon)
        switch err {
        case .success, .notificationAlreadyRegistered:
            if attempt > 0 { NSLog("AXObserver: \(name) for pid \(pid) registered after \(attempt) retries") }
        case .cannotComplete where attempt < 20:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.add(name, to: element, attempt: attempt + 1)
            }
        default:
            NSLog("AXObserver: \(name) for pid \(pid) failed (\(err.rawValue))")
        }
    }

    private static let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let me = Unmanaged<AXAppObserver>.fromOpaque(refcon).takeUnretainedValue()
        let name = notification as String
        MainActor.assumeIsolated { me.handler(name, element) }
    }
}
