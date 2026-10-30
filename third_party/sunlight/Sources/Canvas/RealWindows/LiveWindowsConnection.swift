import Foundation
import CoreGraphics
import Darwin

/// The wire format of Sunlight's Dock add-on (LiveWindows/osax), which is adapted from yabai's
/// scripting addition and keeps its envelope: native int16 payload length, uint8 opcode, then
/// memcpy-packed fields (no struct padding). The live-window extension is versioned separately;
/// a stock addition is never sent a transform or a thumbnail toggle.
enum LiveWindowsWire {
    static let capability: UInt8 = 0x70
    static let session: UInt8 = 0x71
    static let frame: UInt8 = 0x72
    static let handoff: UInt8 = 0x73
    static let shadow: UInt8 = 0x74
    static let magic = Data("SUNBEAM1\n".utf8)
    static let maxWindows = 128
    /// The add-on this build carries (LiveWindows/osax/common.h). An older one in the Dock still works,
    /// with what it has; the app asks to reload it once it answers.
    static let additionVersion = "sunlight-14"
    /// The first add-on that holds a lease per canvas, so that every display's canvas can show live
    /// windows; with an older one only the main display's does, and the others show pictures.
    static let leasePerCanvas = 13
    /// The number in a Sunlight add-on's version ("sunlight-5" is 5); 0 for anything else (a stock
    /// yabai, nothing answering).
    static func additionNumber(_ version: String?) -> Int {
        guard let version, version.hasPrefix("sunlight-"), let n = Int(version.dropFirst("sunlight-".count)) else { return 0 }
        return n
    }
    /// Whether an add-on of this version takes the canvas's IDs in a handoff (`handoff(_:at:overlay:backdrop:)`)
    /// and in an empty frame, and does the raise and the tuck itself; sunlight-3 and up.
    static func handoffInDock(_ version: String?) -> Bool { additionNumber(version) >= 3 }
    /// Whether an add-on of this version hands off a window it hasn't leased, taking it to its place
    /// from wherever it is; sunlight-5 and up. Earlier ones know only the windows their frames
    /// transformed, and refuse the rest (status 7).
    static func handoffTakesAnyWindow(_ version: String?) -> Bool { additionNumber(version) >= 5 }
    /// Whether an add-on of this version rewrites a window's two shadow looks
    /// (`shadow(_:inactiveWeight:activeWeight:inactive:active:)`); sunlight-7 and up.
    static func shadowInDock(_ version: String?) -> Bool { additionNumber(version) >= 7 }
    /// Whether an add-on of this version takes a frame's flags byte (`snapshot(_:backdrop:overlay:kind:)`):
    /// a partial frame moves only the windows in it and leaves the rest leased as they are, and a full
    /// one asserts level and stacking; sunlight-8 and up. Earlier ones take every frame as the whole
    /// set, and reassert everything on a clock of their own.
    static func partialFramesInDock(_ version: String?) -> Bool { additionNumber(version) >= 8 }
    /// Whether an add-on of this version keeps windows on show through a handoff (`handoff(_:at:overlay:backdrop:keeping:)`):
    /// the ones in view around the entered window go to their places natively and stay in front of the
    /// canvas with it; sunlight-10 and up. Earlier ones put every other window back under the backdrop.
    static func keepsWindowsInDock(_ version: String?) -> Bool { additionNumber(version) >= 10 }
    /// Whether an add-on of this version lifts the canvas (backdrop, windows, overlay) one window level
    /// above the normal one while the canvas is up, so a new window is born behind the backdrop rather
    /// than on top of the canvas at full size, and takes in an empty frame the app that has the front
    /// (`snapshot(_:backdrop:overlay:kind:above:)`) to come down under its windows; sunlight-11 and up.
    static func liftsCanvasInDock(_ version: String?) -> Bool { additionNumber(version) >= 11 }

    /// What a frame says about the windows it leaves out (sunlight-8). `legacy` carries no flags byte,
    /// for an older add-on: every frame is the whole set.
    enum FrameKind: Equatable {
        /// Every leased window, level and stacking asserted; one left out is put back.
        case full
        /// Only the windows in it move; the rest stay leased as they are. Empty, it is a keepalive.
        case partial
        case legacy
    }
    static let frameFull: UInt8 = 0x01

    static func pack<T>(_ value: T, into data: inout Data) {
        var value = value
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    static func message(_ opcode: UInt8, _ payload: Data = Data()) -> Data {
        precondition(payload.count + 1 < 0x1000)
        var bytes = Data()
        pack(Int16(payload.count + 1), into: &bytes)
        bytes.append(opcode)
        bytes.append(payload)
        return bytes
    }

    static func move(_ id: CGWindowID, x: Int32, y: Int32) -> Data {
        var data = Data(); pack(id, into: &data); pack(x, into: &data); pack(y, into: &data)
        return message(0x06, data)
    }

    static func order(_ id: CGWindowID, relativeTo other: CGWindowID, order: Int32) -> Data {
        var data = Data(); pack(id, into: &data); pack(order, into: &data); pack(other, into: &data)
        return message(0x10, data)
    }

    /// The handoff: the entered window goes to `point` natively, every other leased window is put back.
    /// With `overlay` and `backdrop` (sunlight-3 and up) the add-on also tucks the backdrop under the
    /// canvas and raises the window above it, all in its one screen update. `keeping` (sunlight-10 and
    /// up, with the canvas's IDs): windows that stay on show with it, bottom to top, each going to its
    /// point natively and staying in front of the canvas, under the entered window; a count byte, then
    /// window, x, y for each. At most `maxKept`.
    static func handoff(_ id: CGWindowID, at point: CGPoint, overlay: CGWindowID = 0, backdrop: CGWindowID = 0,
                        keeping kept: [(CGWindowID, CGPoint)] = []) -> Data {
        var data = Data()
        pack(id, into: &data)
        pack(Float(point.x), into: &data)
        pack(Float(point.y), into: &data)
        if overlay != 0 || backdrop != 0 {
            pack(overlay, into: &data)
            pack(backdrop, into: &data)
            let kept = kept.suffix(maxKept)   // the top ones, if ever there were more
            if !kept.isEmpty {
                data.append(UInt8(kept.count))
                for (keptID, keptPoint) in kept {
                    pack(keptID, into: &data)
                    pack(Float(keptPoint.x), into: &data)
                    pack(Float(keptPoint.y), into: &data)
                }
            }
        }
        return message(handoff, data)
    }
    /// The most windows a handoff keeps on show; more than a screen holds in practice.
    static let maxKept = 64

    /// A window's shadow look as AppKit's shadow dictionary has it: the blur radius and vertical offset
    /// in points, the shadow's density and the rim's. macOS keeps two per window, set once as the window
    /// is made, and the window server switches between them in one frame as the window becomes or stops
    /// being key — at the seam, a shadow blink. The add-on rewrites the two so they meet at the seam
    /// (`shadow(_:inactiveWeight:activeWeight:inactive:active:)`).
    struct ShadowLook: Equatable {
        var radius: Float
        var density: Float
        var rimDensity: Float
        var offset: Float

        /// A titled window's two looks, as AppKit sets them on macOS 27.2 (read off its
        /// `SLSTransactionSetWindowShadowProperties` call). The add-on leaves a window whose shadow
        /// isn't this kind alone (status 9).
        static let inactive = ShadowLook(radius: 8, density: 0.22, rimDensity: 0.55, offset: 7)
        static let active = ShadowLook(radius: 20, density: 0.4, rimDensity: 0.6, offset: 18)
    }

    /// Sets a window's inactive look `inactiveWeight` of the way, and its active look `activeWeight` of
    /// the way, from the standard inactive look to the standard active one (sunlight-7). 0 and 1 are the
    /// window's own looks; over a flight in the first rises to 1, so the switch to key changes nothing;
    /// before the canvas takes the screen back the second falls to 0, so the switch back changes nothing.
    static func shadow(_ id: CGWindowID, inactiveWeight: Float, activeWeight: Float,
                       inactive: ShadowLook = .inactive, active: ShadowLook = .active) -> Data {
        var data = Data()
        pack(id, into: &data)
        pack(inactiveWeight, into: &data)
        pack(activeWeight, into: &data)
        for look in [inactive, active] {
            pack(look.radius, into: &data); pack(look.density, into: &data)
            pack(look.rimDensity, into: &data); pack(look.offset, into: &data)
        }
        return message(shadow, data)
    }

    struct Window: Equatable {
        let id: CGWindowID
        let transform: CGAffineTransform

        /// SkyLight stores the inverse mapping: screen points -> unscaled window-local points.
        /// Native identity is a translation by minus the window's real origin, not .identity.
        /// `pop` below 1 draws the window that much smaller about the centre of its on-screen rect (a
        /// window arriving on the canvas, see `WindowProxy.entranceScale`); the inverse scale and the
        /// translation follow. Never below a half: the addition rejects an inverse scale past 100.
        init(id: CGWindowID, worldRect: CGRect, inset: CGFloat, camera: Camera, pop: CGFloat = 1) {
            self.id = id
            let scale = max(0.5, pop)
            var target = camera.toScreen(worldRect.insetBy(dx: -inset, dy: -inset))
            if scale != 1 {
                target = target.insetBy(dx: target.width * (1 - scale) / 2, dy: target.height * (1 - scale) / 2)
            }
            let inverse = 1 / (camera.zoom * scale)
            transform = CGAffineTransform(a: inverse, b: 0, c: 0, d: inverse,
                                          tx: -target.minX * inverse, ty: -target.minY * inverse)
        }
    }

    /// `above`: in an empty frame (every window released), the app that has the front, if one took it
    /// while the canvas was up: an add-on from sunlight-11 brings the canvas down under its windows.
    static func snapshot(_ windows: [Window], backdrop: CGWindowID, overlay: CGWindowID,
                         kind: FrameKind = .legacy, above pid: pid_t = 0) throws -> Data {
        guard windows.count <= maxWindows, Set(windows.map(\.id)).count == windows.count else {
            throw LiveWindowsError.protocolError("Too many or duplicate live windows")
        }
        var data = Data()
        pack(backdrop, into: &data); pack(overlay, into: &data); pack(UInt16(windows.count), into: &data)
        switch kind {
        case .full: data.append(frameFull)
        case .partial: data.append(0)
        case .legacy: break
        }
        if windows.isEmpty, kind != .legacy, pid != 0 { pack(Int32(pid), into: &data) }
        for window in windows {
            guard window.id != 0, window.id != backdrop, window.id != overlay else {
                throw LiveWindowsError.protocolError("Invalid managed window")
            }
            pack(window.id, into: &data)
            let t = window.transform
            for value in [t.a, t.b, t.c, t.d, t.tx, t.ty] {
                guard value.isFinite, Float(value).isFinite else {
                    throw LiveWindowsError.protocolError("Invalid window transform")
                }
                pack(Float(value), into: &data)
            }
        }
        return message(frame, data)
    }
}

enum LiveWindowsError: Error, LocalizedError {
    case system(String, Int32)
    case protocolError(String)
    var errorDescription: String? {
        switch self {
        case .system(let operation, let code): return "\(operation): \(String(cString: strerror(code)))"
        case .protocolError(let message): return message
        }
    }
}

/// Blocking I/O is confined to the driver's worker. Both connect and I/O have bounded waits: the socket
/// times out every quarter second, and a read or write keeps waiting through those until `patience`
/// has passed. A probe or a one-off command gets one quarter second; the leased session gets longer,
/// because the Dock answers a frame only once the window server has taken every transform in it, and
/// the window server has slow moments (a display waking, a Space changing) that are no reason to give
/// the windows up.
final class LiveWindowsConnection {
    private var fd: Int32 = -1
    /// How long a read or write waits for the other side in all, in seconds.
    let patience: TimeInterval
    /// The socket's own timeout: how long one `recv` or `send` blocks before it is tried again.
    static let socketTimeout: TimeInterval = 0.25
    /// What a leased session waits for an acknowledgement.
    static let sessionPatience: TimeInterval = 1.5
    static var socketPath: String {
        let user = getpwuid(getuid()).map { String(cString: $0.pointee.pw_name) } ?? NSUserName()
        return "/tmp/sunlight-live_\(user).socket"   // LiveWindows/osax/common.h
    }

    init(path: String = LiveWindowsConnection.socketPath, patience: TimeInterval = LiveWindowsConnection.socketTimeout) throws {
        self.patience = patience
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let encoded = Array(path.utf8) + [0]
        guard encoded.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw LiveWindowsError.protocolError("Socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: encoded) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LiveWindowsError.system("socket", errno) }
        do {
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw LiveWindowsError.system("connect", errno) }
                var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&pollFD, 1, 250) > 0 else { throw LiveWindowsError.system("connect timeout", ETIMEDOUT) }
                var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                    throw LiveWindowsError.system("connect", error == 0 ? errno : error)
                }
            }
            _ = fcntl(fd, F_SETFL, 0)
        } catch { close(); throw error }
    }

    deinit { close() }
    func close() {
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1 }
    }

    /// Whether a failed call only timed out, and there is enough patience left for another wait to
    /// be worth it (a socket timeout can come back a hair early; half of one is the margin).
    private func mayWaitLonger(_ code: Int32, until deadline: DispatchTime) -> Bool {
        (code == EAGAIN || code == EWOULDBLOCK) && DispatchTime.now() + LiveWindowsConnection.socketTimeout / 2 < deadline
    }

    func send(_ bytes: Data) throws {
        let deadline = DispatchTime.now() + patience
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count < 0, errno == EINTR || mayWaitLonger(errno, until: deadline) { continue }
                guard count > 0 else { throw LiveWindowsError.system("send", errno) }
                offset += count
            }
        }
    }

    func receive(_ count: Int) throws -> Data {
        let deadline = DispatchTime.now() + patience
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let n = recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                if n < 0, errno == EINTR || mayWaitLonger(errno, until: deadline) { continue }
                guard n > 0 else { throw LiveWindowsError.system("receive", n == 0 ? ECONNRESET : errno) }
                offset += n
            }
        }
        return data
    }

    /// The add-on's version (its stock `0x01` request: `OSAX_VERSION` and a newline), or nil when
    /// nothing answers it.
    static func version(path: String = socketPath) -> String? {
        do {
            let socket = try LiveWindowsConnection(path: path)
            defer { socket.close() }
            try socket.send(LiveWindowsWire.message(0x01))
            var reply = Data()
            while reply.count < 32 {
                let byte = try socket.receive(1)
                if byte[0] == UInt8(ascii: "\n") { break }
                reply.append(byte)
            }
            let version = String(decoding: reply, as: UTF8.self)
            return version.isEmpty ? nil : version
        } catch { return nil }
    }

    static func probe(path: String = socketPath) -> Bool {
        do {
            let socket = try LiveWindowsConnection(path: path)
            defer { socket.close() }
            try socket.send(LiveWindowsWire.message(LiveWindowsWire.capability))
            return try socket.receive(LiveWindowsWire.magic.count) == LiveWindowsWire.magic
        } catch { return false }
    }

    /// A stock request on its own connection, served by yabai's ordinary listener (not the lease).
    /// The addition closes the connection once the request has been carried out, so the close is
    /// the barrier: on return the window server has it.
    @discardableResult
    static func command(_ message: Data, path: String = socketPath) -> Bool {
        do {
            let socket = try LiveWindowsConnection(path: path)
            defer { socket.close() }
            try socket.send(message)
            _ = try? socket.receive(1)   // nothing comes back; this waits for the close
            return true
        } catch { return false }
    }

    /// A request on the lease and the add-on's one-byte status for it: 0 when carried out.
    func request(_ data: Data) throws -> UInt8 {
        try send(data)
        return try receive(1)[0]
    }

    static func reason(for status: UInt8) -> String {
        [1: "invalid request", 2: "reading native state", 3: "setting transform",
         4: "setting window level", 5: "ordering window", 6: "ordering input overlay",
         7: "committing handoff", 8: "setting shadow", 9: "not a standard shadow"][Int(status)] ?? "status \(status)"
    }

    func acknowledge(_ data: Data) throws {
        let status = try request(data)
        guard status == 0 else {
            throw LiveWindowsError.protocolError("Dock rejected live-window update: \(LiveWindowsConnection.reason(for: status))")
        }
    }
}
