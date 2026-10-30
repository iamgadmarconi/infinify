import XCTest
@testable import Canvas

final class HapticsTests: XCTestCase {
    // MARK: Vocabulary

    func testEveryCueHasItsOwnFeel() {
        let cues = Haptics.Cue.allCases
        for cue in cues {
            XCTAssertEqual(cue.steps.first?.delay, 0, "\(cue) starts at once")
            XCTAssertEqual(cue.steps.map(\.delay), cue.steps.map(\.delay).sorted(), "\(cue) plays in order")
            XCTAssertLessThanOrEqual(cue.duration, 0.1, "\(cue) is over before it's a buzz")
        }
        for a in cues {
            for b in cues where a != b {
                XCTAssertNotEqual(a.steps, b.steps, "\(a) and \(b) feel alike")
            }
        }
        // The heaviest tap is kept for the bond alone.
        XCTAssertEqual(cues.filter { $0.steps.contains { $0.tap == .heavy } }, [.bond])
    }

    func testTapsMapToTheMacsPatterns() {
        XCTAssertEqual(Haptics.Tap.light.pattern, .alignment)
        XCTAssertEqual(Haptics.Tap.medium.pattern, .generic)
        XCTAssertEqual(Haptics.Tap.heavy.pattern, .levelChange)
    }

    // MARK: Gate

    func testACueWaitsForTheLastToEnd() {
        var gate = Haptics.Gate()
        XCTAssertTrue(gate.admit(.bump, at: 0))
        XCTAssertFalse(gate.admit(.detent, at: 0.02), "on the heels of the bump")
        XCTAssertTrue(gate.admit(.detent, at: 0.07))
    }

    func testSpacingCountsFromTheEndOfATwoTapCue() {
        var gate = Haptics.Gate()
        XCTAssertTrue(gate.admit(.cushion, at: 0))   // second tap at 0.045
        XCTAssertFalse(gate.admit(.bump, at: 0.08))
        XCTAssertTrue(gate.admit(.bump, at: 0.11))
    }

    func testTheSameWindowIsNotBumpedAgainAtOnce() {
        var gate = Haptics.Gate()
        XCTAssertTrue(gate.admit(.bump, key: 1, at: 0))
        XCTAssertFalse(gate.admit(.bump, key: 1, at: 0.2), "still cooling down")
        XCTAssertTrue(gate.admit(.bump, key: 2, at: 0.2), "another window is another bump")
        XCTAssertTrue(gate.admit(.bump, key: 1, at: 0.6))
    }

    func testCooldownIsPerCueAsWellAsPerKey() {
        var gate = Haptics.Gate()
        XCTAssertTrue(gate.admit(.catch, key: 1, at: 0))
        // The same window bonding right after it was caught is a different thing to feel.
        XCTAssertTrue(gate.admit(.bond, key: 1, at: 0.1))
    }

    func testASweepThroughAClusterIsCapped() {
        var gate = Haptics.Gate()
        for i in 0..<Haptics.Gate.budget {
            XCTAssertTrue(gate.admit(.detent, key: i, at: Double(i) * 0.1))
        }
        XCTAssertFalse(gate.admit(.detent, key: 100, at: 0.6), "the budget for the second is spent")
        XCTAssertFalse(gate.admit(.bump, key: 101, at: 0.9))
        XCTAssertTrue(gate.admit(.detent, key: 102, at: 1.05), "the first has dropped out of the window")
    }

    func testBondGoesThroughABusyHand() {
        var gate = Haptics.Gate()
        for i in 0..<Haptics.Gate.budget {
            XCTAssertTrue(gate.admit(.bump, key: i, at: Double(i) * 0.1))
        }
        XCTAssertTrue(gate.admit(.bond, key: 50, at: 0.6), "the budget doesn't hold a bond")
        XCTAssertFalse(gate.admit(.bump, key: 51, at: 0.62), "but the bond holds the rest off")
    }

    func testBondCutsALighterCueShortButNotATapThatJustWent() {
        var gate = Haptics.Gate()
        XCTAssertTrue(gate.admit(.catch, at: 0))   // its second tap is due at 0.07
        XCTAssertFalse(gate.admit(.bond, at: 0.01), "two taps at once would be one")
        XCTAssertTrue(gate.admit(.bond, at: 0.04), "through the catch, which loses its second tap")
    }

    func testANewGestureStartsClean() {
        var gate = Haptics.Gate()
        XCTAssertTrue(gate.admit(.bump, key: 1, at: 0))
        gate.reset()
        XCTAssertTrue(gate.admit(.bump, key: 1, at: 0.01))
    }

    // MARK: Player

    /// The setting as the test wants it, and as it was afterwards.
    @MainActor
    private func withHaptics(_ on: Bool, _ body: () async -> Void) async {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "CanvasHaptics")
        defer { defaults.set(saved, forKey: "CanvasHaptics") }
        Settings.haptics = on
        await body()
    }

    @MainActor
    func testTheSettingSilencesThePlayer() async {
        await withHaptics(false) {
            let player = Haptics.Player()
            var taps: [Haptics.Tap] = []
            player.perform = { tap, _ in taps.append(tap) }
            XCTAssertFalse(player.play(.bump, at: 0))
            XCTAssertTrue(taps.isEmpty)
        }
    }

    @MainActor
    func testTheFirstTapGoesWithTheFrameAndTheRestFollow() async {
        await withHaptics(true) {
            let player = Haptics.Player()
            var taps: [(Haptics.Tap, Bool)] = []
            let second = expectation(description: "the second tap")
            player.perform = { tap, now in
                taps.append((tap, now))
                if taps.count == 2 { second.fulfill() }
            }
            XCTAssertTrue(player.play(.catch, at: 0))
            XCTAssertEqual(taps.count, 1)
            XCTAssertEqual(taps.first?.0, .light)
            XCTAssertEqual(taps.first?.1, false, "with the next frame, as the guide is drawn")
            await fulfillment(of: [second], timeout: 1)
            XCTAssertEqual(taps.last?.0, .medium)
            XCTAssertEqual(taps.last?.1, true, "on its delay, at once")
        }
    }

    @MainActor
    func testANewGestureDropsTheTapsStillToCome() async {
        await withHaptics(true) {
            let player = Haptics.Player()
            var taps: [Haptics.Tap] = []
            player.perform = { tap, _ in taps.append(tap) }
            XCTAssertTrue(player.play(.cushion, at: 0))
            player.begin()
            try? await Task.sleep(nanoseconds: 150_000_000)   // past the cushion's second tap
            XCTAssertEqual(taps, [.light])
        }
    }
}
