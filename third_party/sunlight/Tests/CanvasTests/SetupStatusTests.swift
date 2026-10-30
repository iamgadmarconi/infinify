import XCTest
@testable import Canvas

final class SetupStatusTests: XCTestCase {
    private func status(accessibility: Bool = true, screenRecording: Bool = true, sip: Bool = true, bootArgument: Bool = true,
                        helper: SetupStatus.Helper = .daemonEnabled, loaded: Bool = true) -> SetupStatus {
        SetupStatus(accessibility: accessibility, screenRecording: screenRecording, sipAllowsLiveWindows: sip,
                    bootArgument: bootArgument, helper: helper, liveWindowsLoaded: loaded)
    }

    private func item(_ step: SetupStatus.Step, in status: SetupStatus) throws -> SetupStatus.Item {
        try XCTUnwrap(status.items.first { $0.step == step })
    }

    func testEverythingDone() {
        let done = status()
        XCTAssertTrue(done.isComplete)
        XCTAssertEqual(done.summary, "Everything's set up.")
        XCTAssertTrue(done.items.allSatisfy { $0.state == .done && $0.fix == nil })
    }

    func testScreenRecordingIsntRequired() throws {
        let noRecording = status(screenRecording: false)
        XCTAssertTrue(noRecording.isComplete)
        XCTAssertEqual(try item(.screenRecording, in: noRecording).fix, .allowScreenRecording)
        XCTAssertTrue(noRecording.summary.contains("Screen Recording"))
    }

    /// A fresh Mac: the helper, then Recovery, and the steps that depend on Recovery wait rather than
    /// offering a fix.
    func testFreshMacStartsWithTheHelperThenRecovery() throws {
        let fresh = status(accessibility: false, screenRecording: false, sip: false, bootArgument: false,
                           helper: .daemonNotRegistered, loaded: false)
        XCTAssertEqual(fresh.missing.map(\.step), [.accessibility, .helper, .systemIntegrity, .bootArgument, .liveWindows])
        XCTAssertEqual(try item(.systemIntegrity, in: fresh).fix, .showRecoverySteps)
        XCTAssertEqual(try item(.bootArgument, in: fresh).state, .waiting)
        XCTAssertNil(try item(.bootArgument, in: fresh).fix)
        XCTAssertEqual(try item(.helper, in: fresh).fix, .approveHelper)
        XCTAssertEqual(try item(.liveWindows, in: fresh).state, .waiting)
        XCTAssertEqual(fresh.summary, "5 steps left, starting with accessibility.")
    }

    func testBootArgumentOfferedOnceSIPIsOff() throws {
        let afterRecovery = status(bootArgument: false, loaded: false)
        XCTAssertEqual(try item(.bootArgument, in: afterRecovery).fix, .setBootArgument)
        XCTAssertNil(try item(.liveWindows, in: afterRecovery).fix)
    }

    /// Loading waits for the helper's OK; a build without the daemon can load with a password.
    func testLoadingWaitsForTheHelper() throws {
        XCTAssertNil(try item(.liveWindows, in: status(helper: .daemonNeedsApproval, loaded: false)).fix)
        XCTAssertEqual(try item(.liveWindows, in: status(helper: .asksForPassword, loaded: false)).fix, .loadLiveWindows)
        XCTAssertEqual(try item(.liveWindows, in: status(helper: .daemonEnabled, loaded: false)).fix, .loadLiveWindows)
        XCTAssertEqual(try item(.helper, in: status(helper: .missing)).state, .todo)
    }

    /// The two permissions alone make a usable preview; live windows' steps don't count against it.
    func testPreviewNeedsOnlyThePermissions() {
        XCTAssertTrue(status(sip: false, bootArgument: false, helper: .daemonNotRegistered, loaded: false).previewReady)
        XCTAssertFalse(status(screenRecording: false).previewReady)
        XCTAssertFalse(status(accessibility: false).previewReady)
    }

    /// The setup window lists the steps in this order: the preview's permissions first.
    func testThePermissionsComeFirst() {
        XCTAssertEqual(Array(SetupStatus.Step.allCases.prefix(2)), [.accessibility, .screenRecording])
        XCTAssertEqual(status().items.map(\.step), SetupStatus.Step.allCases)
    }

    func testRecoveryCommandsCoverBothProtectionsAndTheBootArgument() {
        XCTAssertTrue(SetupStatus.recoveryCommands.contains("csrutil enable --without fs --without debug --without nvram"))
        XCTAssertTrue(SetupStatus.recoveryCommands.contains("nvram boot-args=-arm64e_preview_abi"))
    }
}
