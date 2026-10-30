import AppKit

/// `Sunlight --setup-preview <scenario>`: the wizard against a made-up Mac, so every page can be looked
/// at in one build without touching SIP or the permissions. ← and → page through; buttons that would
/// relaunch, shut down or change the Mac do nothing. `--setup-preview list` prints the scenarios.
enum SetupReview {
    struct Scenario: Sendable {
        var name: String
        var status: SetupStatus
        var mac: SetupFlow.Mac
        /// What the person has done so far, fixed too.
        var record: SetupFlow.Record
    }

    private static let welcomed = SetupFlow.Record(welcomed: true, loginItemChosen: true, learnedBasics: true)
    private static let started = SetupFlow.Record(welcomed: true, loginItemChosen: true, learnedBasics: true, startedLive: true)
    private static let live = SetupFlow.Record(welcomed: true, loginItemChosen: true, learnedBasics: true, consented: true, startedLive: true)

    private static func status(accessibility: Bool = true, screenRecording: Bool = true, sip: Bool = true, bootArgument: Bool = true,
                               helper: SetupStatus.Helper = .daemonEnabled, loaded: Bool = true) -> SetupStatus {
        SetupStatus(accessibility: accessibility, screenRecording: screenRecording, sipAllowsLiveWindows: sip,
                    bootArgument: bootArgument, helper: helper, liveWindowsLoaded: loaded)
    }

    static let scenarios: [Scenario] = [
        Scenario(name: "fresh", status: status(accessibility: false, screenRecording: false, sip: false, bootArgument: false, helper: .daemonNotRegistered, loaded: false), mac: .supported, record: .fresh),
        Scenario(name: "login-item", status: status(accessibility: false, screenRecording: false, sip: false, bootArgument: false, helper: .daemonNotRegistered, loaded: false), mac: .supported, record: SetupFlow.Record(welcomed: true)),
        Scenario(name: "basics", status: status(sip: false, bootArgument: false, helper: .daemonNotRegistered, loaded: false), mac: .supported,
                 record: SetupFlow.Record(welcomed: true, loginItemChosen: true)),
        Scenario(name: "permissions-done", status: status(sip: false, bootArgument: false, helper: .daemonNotRegistered, loaded: false), mac: .supported, record: welcomed),
        Scenario(name: "helper-waiting", status: status(sip: false, bootArgument: false, helper: .daemonNeedsApproval, loaded: false), mac: .supported, record: live),
        Scenario(name: "sip-on", status: status(sip: false, bootArgument: false, loaded: false), mac: .supported, record: live),
        Scenario(name: "boot-arg-missing", status: status(bootArgument: false, loaded: false), mac: .supported, record: live),
        Scenario(name: "ready-to-load", status: status(loaded: false), mac: .supported, record: live),
        Scenario(name: "ad-hoc-build", status: status(helper: .asksForPassword, loaded: false), mac: .supported, record: live),
        Scenario(name: "done", status: status(), mac: .supported, record: live),
        Scenario(name: "intel", status: status(sip: false, bootArgument: false, helper: .daemonNotRegistered, loaded: false),
                 mac: SetupFlow.Mac(appleSilicon: false, osSupported: true, admin: true), record: welcomed),
        Scenario(name: "no-admin", status: status(sip: false, bootArgument: false, helper: .daemonNotRegistered, loaded: false),
                 mac: SetupFlow.Mac(appleSilicon: true, osSupported: true, admin: false), record: started),
    ]

    static func scenario(named name: String) -> Scenario? {
        scenarios.first { $0.name == name }
    }

    static var usage: String {
        "Sunlight --setup-preview <scenario>\n  " + scenarios.map(\.name).joined(separator: ", ")
    }

    /// Shows the wizard for a scenario and keeps it up until the window closes.
    @MainActor
    static func run(_ scenario: Scenario) -> SetupWizardController {
        let status = scenario.status
        let controller = SetupWizardController(mac: scenario.mac, statusProvider: { status }, reviewRecord: scenario.record)
        controller.window?.title = "Set Up Sunlight — review: \(scenario.name)  (← → pages)"
        controller.show(startingLive: false)
        return controller
    }
}
