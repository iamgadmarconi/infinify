import AppKit
import Carbon.HIToolbox
import os

/// A session-level CGEvent tap that claims the app switcher and the Mission Control key while takeover
/// is on. It lives on its own thread so a stalled main thread (AX calls, ScreenCaptureKit) can never
/// get the tap disabled or lag a keystroke; commands are forwarded to the main actor.
///
/// Needs Accessibility (an active session tap is refused without it). Carbon hotkeys can't claim ⌘Tab,
/// which is why this exists alongside `Hotkey`.
final class KeyTap: @unchecked Sendable {
    enum Command: Sendable, Equatable {
        case appSwitchBegin(reverse: Bool)
        case appSwitchStep(reverse: Bool)
        /// ⌘` or ⌘↓ (⇧⌘` or ⌘↑ back) while switching: the highlighted app's next window.
        case appSwitchWindowStep(reverse: Bool)
        case appSwitchCommit
        case appSwitchCancel
        case missionControl
        case showDesktop
    }

    struct State: Sendable {
        var entered = false
        var switcherOpen = false
        /// Key codes whose keyDown we swallowed; their keyUp is swallowed too so apps never see an orphan.
        var swallowed = Set<Int64>()
    }

    enum Action: Equatable {
        case pass
        case swallow
        case send(Command)
    }

    private static let tab: Int64 = 48
    /// The key left of 1 (` on US layouts): ⌘` walks an app's windows, as on the Mac.
    private static let grave: Int64 = 50
    private static let escape: Int64 = 53
    private static let f11: Int64 = 103
    private static let leftArrow: Int64 = 123
    private static let rightArrow: Int64 = 124
    private static let downArrow: Int64 = 125
    private static let upArrow: Int64 = 126
    /// The dedicated Mission Control key on Apple keyboards.
    private static let missionControlKey: Int64 = 160

    private let handler: @MainActor @Sendable (Command) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var port: CFMachPort?

    init(handler: @escaping @MainActor @Sendable (Command) -> Void) {
        self.handler = handler
    }

    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "canvas.keytap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        guard let runLoop else { return }
        self.runLoop = nil
        thread = nil
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            if let port { CFMachPortInvalidate(port) }
            self.port = nil
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
        state.withLock { $0 = State() }
    }

    /// Whether a real window is in front (changes what ⌘Tab means).
    func update(entered: Bool) {
        state.withLock { $0.entered = entered }
    }

    // MARK: Tap thread

    private func threadMain() {
        runLoop = CFRunLoopGetCurrent()
        installTap()
        // The system disables a tap that stalls; make sure we always come back.
        let watchdog = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.checkTap() }
        RunLoop.current.add(watchdog, forMode: .common)
        CFRunLoopRun()
        watchdog.invalidate()
    }

    private func installTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: KeyTap.callback, userInfo: info) else {
            NSLog("KeyTap: tapCreate failed — Accessibility granted? Retrying in 3 s")
            let retry = Timer(timeInterval: 3, repeats: false) { [weak self] _ in self?.installTap() }
            RunLoop.current.add(retry, forMode: .common)
            return
        }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        NSLog("KeyTap: installed")
    }

    private func checkTap() {
        guard let port else { return }
        if !CFMachPortIsValid(port) {
            NSLog("KeyTap: port invalidated, reinstalling")
            self.port = nil
            installTap()
        } else if !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let tap = Unmanaged<KeyTap>.fromOpaque(info).takeUnretainedValue()
        return tap.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])

        let action: Action
        switch type {
        case .keyDown:
            action = state.withLock { s -> Action in
                let a = KeyTap.action(keyCode: keyCode, flags: flags, state: &s)
                if case .pass = a {} else { s.swallowed.insert(keyCode) }
                return a
            }
        case .keyUp:
            action = state.withLock { $0.swallowed.remove(keyCode) != nil ? .swallow : .pass }
        case .flagsChanged:
            // Letting go of ⌘ while the switcher is open picks the highlighted window.
            let commit = state.withLock { s -> Bool in
                guard s.switcherOpen, !flags.contains(.maskCommand) else { return false }
                s.switcherOpen = false
                return true
            }
            action = commit ? .send(.appSwitchCommit) : .pass
            if case .send(let cmd) = action { send(cmd) }
            return Unmanaged.passUnretained(event)
        default:
            action = .pass
        }

        switch action {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .send(let cmd):
            send(cmd)
            return nil
        }
    }

    static func action(keyCode: Int64, flags: CGEventFlags, state: inout State) -> Action {
        let command = flags.contains(.maskCommand)
        let control = flags.contains(.maskControl)
        let option = flags.contains(.maskAlternate)
        let shift = flags.contains(.maskShift)

        switch keyCode {
        case tab where command && !control && !option:
            if state.switcherOpen { return .send(.appSwitchStep(reverse: shift)) }
            state.switcherOpen = true
            return .send(.appSwitchBegin(reverse: shift))
        case escape where state.switcherOpen:
            state.switcherOpen = false
            return .send(.appSwitchCancel)
        // While switching, ⌘ is down: the Mac's ⌘-Tab extras. Arrows across the strip step apps,
        // ` and the arrows along an app's windows step its windows.
        case grave where state.switcherOpen && command && !control && !option:
            return .send(.appSwitchWindowStep(reverse: shift))
        case downArrow where state.switcherOpen && command && !control && !option:
            return .send(.appSwitchWindowStep(reverse: false))
        case upArrow where state.switcherOpen && command && !control && !option:
            return .send(.appSwitchWindowStep(reverse: true))
        case rightArrow where state.switcherOpen && command && !control && !option:
            return .send(.appSwitchStep(reverse: false))
        case leftArrow where state.switcherOpen && command && !control && !option:
            return .send(.appSwitchStep(reverse: true))
        case leftArrow, rightArrow:
            // Spaces switching: there is only one Space in this environment.
            return (control && !command && !option) ? .swallow : .pass
        case missionControlKey where !command && !control && !option:
            return .send(.missionControl)
        case f11 where !command && !control && !option:
            return .send(.showDesktop)
        default:
            return .pass
        }
    }

    private func send(_ command: Command) {
        let handler = self.handler
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler(command) }
        }
    }
}
