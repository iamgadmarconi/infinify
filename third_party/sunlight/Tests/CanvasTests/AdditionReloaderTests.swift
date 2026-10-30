import XCTest
@testable import Canvas

final class AdditionReloaderTests: XCTestCase {
    func testRuleIsPinnedToTheHelperAndChecked() throws {
        let helper = "/Applications/Sunlight.app/Contents/Helpers/SunlightLiveWindows"
        let rule = try XCTUnwrap(AdditionReloader.passwordlessRule(for: helper))
        XCTAssertTrue(rule.contains("shasum -a 256 \(helper)"))
        XCTAssertTrue(rule.contains("\(NSUserName()) ALL=(root) NOPASSWD: sha256:$h \(helper) load"))
        XCTAssertTrue(rule.contains("visudo -cf \"$t\" && install -m 0440 -o root -g wheel \"$t\" \(AdditionReloader.sudoersPath)"))
    }

    func testNoRuleForPathsSudoersCantNameSafely() {
        XCTAssertNil(AdditionReloader.passwordlessRule(for: "/Users/me/My Apps/Sunlight.app/Contents/Helpers/SunlightLiveWindows"))
        XCTAssertNil(AdditionReloader.passwordlessRule(for: "/tmp/helper, ALL"))
        XCTAssertNil(AdditionReloader.passwordlessRule(for: "relative/SunlightLiveWindows"))
    }
}

final class DockCrashGuardTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    /// A load, the Dock going down, the next load, down again…: the third restart in a row trips it.
    func testTripsOnThreeRestartsAroundLoads() {
        var guardian = DockCrashGuard()
        var now = t0
        for strike in 1...DockCrashGuard.limit {
            guardian.loadStarted(at: now)
            guardian.loadEnded(at: now + 2)
            now += 5
            XCTAssertEqual(guardian.dockRestarted(at: now), strike == DockCrashGuard.limit)
            now += 2   // dockSettle, then the next quiet load
        }
    }

    /// The helper restarting the Dock to install the add-on happens mid-load: one strike, not a trip.
    func testRestartDuringALoadIsOneStrike() {
        var guardian = DockCrashGuard()
        guardian.loadStarted(at: t0)
        XCTAssertFalse(guardian.dockRestarted(at: t0 + 1))
        XCTAssertEqual(guardian.strikes, 1)
    }

    /// A restart long after any load (`killall Dock`, a takeover change later on) clears the strikes.
    func testRestartAwayFromLoadsClearsStrikes() {
        var guardian = DockCrashGuard()
        guardian.loadStarted(at: t0)
        guardian.loadEnded(at: t0 + 1)
        _ = guardian.dockRestarted(at: t0 + 3)
        _ = guardian.dockRestarted(at: t0 + 4)
        XCTAssertEqual(guardian.strikes, 2)
        XCTAssertFalse(guardian.dockRestarted(at: t0 + 1 + DockCrashGuard.window + 1))
        XCTAssertEqual(guardian.strikes, 0)
    }

    func testResetStartsCountingAfresh() {
        var guardian = DockCrashGuard()
        guardian.loadStarted(at: t0)
        _ = guardian.dockRestarted(at: t0 + 1)
        _ = guardian.dockRestarted(at: t0 + 2)
        guardian.reset()
        XCTAssertFalse(guardian.dockRestarted(at: t0 + 3))
        XCTAssertEqual(guardian.strikes, 1)
    }
}
