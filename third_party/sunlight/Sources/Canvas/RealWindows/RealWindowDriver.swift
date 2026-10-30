import AppKit
import QuartzCore

/// Latest-frame mailbox: slow socket writes never queue an animation's entire history or block input.
/// One leased connection owns only the IDs in its snapshots. Closing it restores those windows in Dock.
///
/// A lease that fails mid-session is taken again before the failure counts: the Dock ends a session
/// of its own accord when no frame has reached it for three seconds (a long stall on this side), and
/// a frame can miss its acknowledgement when the window server is slow. Either way the addition is
/// still there, and a fresh lease carries on with the latest frame. Only when a new lease can't be had
/// is the failure reported, and the renderer falls back.
final class RealWindowDriver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "canvas.real-windows", qos: .userInteractive)
    private let lock = NSLock()
    /// The latest frame, and the shadow request to follow it (`LiveWindowsWire.shadow`), if any.
    private var pending: (frame: Data, shadow: Data?, full: Bool, at: CFTimeInterval)?
    /// The last full frame (every leased window): what a fresh lease gets first when the frame in hand
    /// is partial, so the windows that frame leaves out are taken too. Worker only.
    private var lastFull: Data?
    private var scheduled = false
    private var generation = 0
    private var connection: LiveWindowsConnection? // worker only
    /// The add-on's version as it answered when the lease was taken (`LiveWindowsConnection.version`),
    /// which says what it can do: `handoffInDock` (sunlight-3 and up) and `handoffTakesAnyWindow`
    /// (sunlight-5 and up). Worker only.
    private var additionVersion: String?
    private var handoffInDock: Bool { LiveWindowsWire.handoffInDock(additionVersion) }
    private var shadowInDock: Bool { LiveWindowsWire.shadowInDock(additionVersion) }
    private var partialFramesInDock: Bool { LiveWindowsWire.partialFramesInDock(additionVersion) }
    private var liftsCanvasInDock: Bool { LiveWindowsWire.liftsCanvasInDock(additionVersion) }
    /// A shadow request the add-on answered with a status: logged once per lease, then no more are
    /// sent on it. Shadows are cosmetic; the frames go on. Worker only.
    private var shadowDeclined = false
    private let socketPath: String
    var onFailure: ((String) -> Void)? // set once on main before submitting
    /// Why the last `restore` returned false: no lease and an add-on that needs one, the Dock's
    /// rejection, or the socket error. Read on the caller's thread right after the call.
    private(set) var lastRestoreFailure: String?
    /// Whether the last `restore` asked the add-on to keep windows on show (`keeping`), which one from
    /// sunlight-10 does. Read on the caller's thread right after the call.
    private(set) var lastRestoreKept = false

    init(socketPath: String = LiveWindowsConnection.socketPath) {
        self.socketPath = socketPath
    }

    /// How many fresh leases are tried for a frame after the one in hand fails, and how long each one
    /// waits first: the Dock's session thread releases its lock only once it has seen the old socket
    /// close and put the windows back.
    static let leaseRetries = 3
    static let leaseRetryDelay: TimeInterval = 0.1

    /// A session, leased now if there is none. Worker only.
    private func lease() throws -> LiveWindowsConnection {
        if let connection { return connection }
        additionVersion = LiveWindowsConnection.version(path: socketPath)
        let socket = try LiveWindowsConnection(path: socketPath, patience: LiveWindowsConnection.sessionPatience)
        try socket.send(LiveWindowsWire.message(LiveWindowsWire.session))
        guard try socket.receive(LiveWindowsWire.magic.count) == LiveWindowsWire.magic else {
            throw LiveWindowsError.protocolError("Live-window addition is unavailable")
        }
        connection = socket
        shadowDeclined = false
        return socket
    }

    /// A shadow request on the lease in hand, when the add-on has shadows and hasn't declined one on
    /// this lease. Nothing is thrown: a refusal is logged, a socket error ends the lease as the next
    /// frame will find. Worker only.
    private func sendShadow(_ data: Data, on leased: LiveWindowsConnection) {
        guard shadowInDock, !shadowDeclined else { return }
        do {
            let status = try leased.request(data)
            if status != 0 {
                shadowDeclined = true
                NSLog("Rendering: the add-on declined a shadow request (\(LiveWindowsConnection.reason(for: status))); this window's seams are left to AppKit")
            }
        } catch {
            NSLog("Rendering: a shadow request failed (\(error.localizedDescription))")
        }
    }

    private func isCurrent(_ epoch: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return epoch == generation
    }

    /// Delivers one frame, on the lease in hand or a new one, and its shadow request after it. A new
    /// lease knows no windows: a partial frame on it is preceded by the last full one, so the windows it
    /// leaves out (parked off screen) are leased again too. Worker only.
    private func deliver(_ data: Data, shadow: Data?, full: Bool, submitted: CFTimeInterval, epoch: Int) throws {
        var retries = RealWindowDriver.leaseRetries
        while true {
            let fresh = connection == nil
            do {
                let leased = try lease()
                if fresh, !full, let lastFull { try leased.acknowledge(lastFull) }
                let started = CACurrentMediaTime()
                try leased.acknowledge(data)
                PerfMonitor.shared.dockRoundTrip(CACurrentMediaTime() - started)
                if full {   // TEMP diagnostics
                    NSLog("Rendering: full frame acked in \(Int((CACurrentMediaTime() - started) * 1000)) ms, \(Int((CACurrentMediaTime() - submitted) * 1000)) ms after submit\(fresh ? " (fresh lease)" : "")")
                }
                if full { lastFull = data }
                if let shadow { sendShadow(shadow, on: leased) }
                return
            } catch {
                connection?.close(); connection = nil
                // A lease that was just made and still failed is the addition saying no; a lost one is
                // worth replacing, a few times — unless a restore has superseded the frame meanwhile.
                guard !fresh, retries > 0, isCurrent(epoch) else { throw error }
                retries -= 1
                NSLog("Rendering: the live-window lease failed (\(error.localizedDescription)); taking a new one")
                Thread.sleep(forTimeInterval: RealWindowDriver.leaseRetryDelay)
            }
        }
    }

    /// A frame, and with it the entered window's shadow for this tick (`LiveWindowsWire.shadow`), sent after
    /// the frame on the same lease when the add-on has shadows (sunlight-7). `full`: the frame carries
    /// every leased window (a legacy frame always does), so a fresh lease can start from it.
    func submit(_ data: Data, shadow: Data? = nil, full: Bool = true) {
        lock.lock()
        pending = (data, shadow, full, CACurrentMediaTime())
        if scheduled { lock.unlock(); return }
        scheduled = true
        let epoch = generation
        lock.unlock()
        queue.async { [self] in
            while true {
                lock.lock()
                guard epoch == generation else { lock.unlock(); return }
                guard let next = pending else { scheduled = false; lock.unlock(); return }
                pending = nil
                lock.unlock()
                do {
                    try deliver(next.frame, shadow: next.shadow, full: next.full, submitted: next.at, epoch: epoch)
                } catch {
                    connection?.close(); connection = nil
                    lock.lock()
                    let current = epoch == generation
                    if current { pending = nil; scheduled = false }
                    lock.unlock()
                    if current {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.lock.lock(); let current = epoch == self.generation; self.lock.unlock()
                            if current { self.onFailure?(error.localizedDescription) }
                        }
                    }
                    return
                }
            }
        }
    }

    /// Clear pending frames before the barrier, so an old frame cannot re-transform a released window.
    /// The bounded wait is used only for mode changes, handoff and shutdown, never camera ticks.
    ///
    /// A handoff puts every window back where the add-on found it, which for the entered window is
    /// behind the canvas, and for a window entered before is over the backdrop. `overlay` (the canvas
    /// window) and `backdrop` let the add-on finish the job in the same screen update: the backdrop
    /// straight under the canvas, the entered window above it. An add-on older than sunlight-3 gets the
    /// raise as a second request after its acknowledgement, which can show a frame in between.
    ///
    /// A handoff with no lease in hand (no frame has gone out since the canvas came back — a quick
    /// ⌘-Tab, or one entry cut short by the next) takes one for it: an add-on from sunlight-5 takes
    /// the window to its place from wherever it is. An older one knows only the windows its frames
    /// transformed, so there the handoff fails and the renderer falls back; the reason is in
    /// `lastRestoreFailure`.
    ///
    /// Never hold this process's own screen-update freeze (`SLSDisableUpdate`) across a request: the
    /// add-on freezes inside the Dock too, and its `SLSReenableUpdate` waits for every freeze to lift,
    /// while this side waits for the acknowledgement. The window server breaks that deadlock only with
    /// its one-second timeout — a second-long stall, and then the in-between frame anyway.
    /// `shadow`: the entered window's last shadow request (both looks the active one), sent on the lease
    /// just before the handoff, so the flight's last tick isn't what the window is left with.
    /// `keeping`: the windows in view around the entered one, bottom to top, with the native points
    /// where they are drawn; an add-on from sunlight-10 leaves them on show, in front of the canvas,
    /// and an older one puts them back with the rest.
    /// `above`: with no handoff, the app that took the front while the canvas was up (the canvas is
    /// deactivating for it), if any: an add-on from sunlight-11 brings the canvas down under its windows.
    @discardableResult
    func restore(handoff: (CGWindowID, CGPoint)? = nil, overlay: CGWindowID = 0, backdrop: CGWindowID = 0,
                 shadow: Data? = nil, keeping kept: [(CGWindowID, CGPoint)] = [], above: pid_t = 0) -> Bool {
        lock.lock(); generation += 1; pending = nil; scheduled = false; lock.unlock()
        return queue.sync {
            defer { connection?.close(); connection = nil }
            lastRestoreFailure = nil
            lastRestoreKept = false
            lastFull = nil   // the canvas sends a full frame first when it presents again
            do {
                guard let (id, point) = handoff else {
                    // Nothing leased, nothing to put back.
                    if let connection {
                        try connection.acknowledge(LiveWindowsWire.snapshot([], backdrop: handoffInDock ? backdrop : 0,
                                                                      overlay: handoffInDock ? overlay : 0,
                                                                      kind: partialFramesInDock ? .full : .legacy,
                                                                      above: liftsCanvasInDock ? above : 0))
                    }
                    return true
                }
                if connection == nil {
                    let version = LiveWindowsConnection.version(path: socketPath)
                    guard LiveWindowsWire.handoffTakesAnyWindow(version) else {
                        throw LiveWindowsError.protocolError("no window leased, and add-on \(version ?? "?") hands off only leased windows")
                    }
                }
                let leased = try lease()
                if let shadow { sendShadow(shadow, on: leased) }
                if handoffInDock {
                    let keeping = LiveWindowsWire.keepsWindowsInDock(additionVersion) ? kept : []
                    try leased.acknowledge(LiveWindowsWire.handoff(id, at: point, overlay: overlay, backdrop: backdrop, keeping: keeping))
                    lastRestoreKept = !keeping.isEmpty
                } else {
                    try leased.acknowledge(LiveWindowsWire.handoff(id, at: point))
                    if overlay != 0 { LiveWindowsConnection.command(LiveWindowsWire.order(id, relativeTo: overlay, order: 1), path: socketPath) }
                }
                return true
            } catch {
                lastRestoreFailure = error.localizedDescription
                return false
            }
        }
    }

    /// Shadow requests one after the other, `interval` apart, on the lease in hand or one taken for
    /// them, which the frames that follow then use: the entered window's active look eased back over a
    /// few frames before the canvas takes the screen back. `releasing`: no frame follows for a while (the
    /// canvas is behind the window just entered), so a lease taken just for this is given up again rather
    /// than left for the Dock to drop. `completion` runs on main once the last request has been
    /// answered — or at once when there is no add-on with shadows to answer.
    func ease(shadows: [Data], interval: TimeInterval, releasing: Bool = false, completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            let fresh = connection == nil
            if let leased = try? lease(), shadowInDock {
                for (i, shadow) in shadows.enumerated() {
                    sendShadow(shadow, on: leased)
                    if shadowDeclined { break }
                    if i + 1 < shadows.count { Thread.sleep(forTimeInterval: interval) }
                }
            }
            if releasing, fresh { connection?.close(); connection = nil }
            DispatchQueue.main.async(execute: completion)
        }
    }
}
