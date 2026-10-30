import XCTest
@testable import Canvas

final class MagnetismTests: XCTestCase {
    private let hand = CGRect(x: 100, y: 100, width: 400, height: 300)

    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool { a.intersects(b) }

    // MARK: Resolve

    func testClearWindowsAreLeftAlone() {
        let far = CGRect(x: 1000, y: 100, width: 300, height: 200)
        let r = Magnetism.resolve(fixed: hand, others: [far], reach: 0)
        XCTAssertEqual(r.rects, [far])
        XCTAssertTrue(r.moved.isEmpty)
    }

    func testOverlapLeavesAlongTheSmallerAxisKeepingTheOther() {
        // 40 pt in from the right, 80 pt in from the bottom: out to the right it goes, same y.
        let neighbour = CGRect(x: 460, y: 320, width: 300, height: 200)
        let r = Magnetism.resolve(fixed: hand, others: [neighbour], reach: 0)
        XCTAssertEqual(r.rects[0], CGRect(x: 500, y: 320, width: 300, height: 200))
        XCTAssertEqual(r.moved, [0])
    }

    func testPushGoesAwayFromTheHandsCentre() {
        let left = CGRect(x: -150, y: 150, width: 300, height: 100)   // overlaps 50 on the left
        let above = CGRect(x: 150, y: -50, width: 100, height: 200)   // overlaps 50 on top
        let r = Magnetism.resolve(fixed: hand, others: [left, above], reach: 0)
        XCTAssertEqual(r.rects[0].maxX, 100)
        XCTAssertEqual(r.rects[1].maxY, 100)
    }

    func testReachLeavesAGap() {
        let neighbour = CGRect(x: 460, y: 320, width: 300, height: 200)
        let r = Magnetism.resolve(fixed: hand, others: [neighbour], reach: 8)
        XCTAssertEqual(r.rects[0].minX, 508)
        // Already a gap away: nothing happens.
        let spaced = CGRect(x: 508, y: 320, width: 300, height: 200)
        XCTAssertTrue(Magnetism.resolve(fixed: hand, others: [spaced], reach: 8).moved.isEmpty)
    }

    func testAChainShunts() {
        // Three in a row to the right, touching; the hand overlaps the first by 60.
        let a = CGRect(x: 440, y: 100, width: 200, height: 300)
        let b = CGRect(x: 640, y: 100, width: 200, height: 300)
        let c = CGRect(x: 840, y: 100, width: 200, height: 300)
        let r = Magnetism.resolve(fixed: hand, others: [c, b, a], reach: 0)   // any order in
        XCTAssertEqual(r.rects, [c.offsetBy(dx: 60, dy: 0), b.offsetBy(dx: 60, dy: 0), a.offsetBy(dx: 60, dy: 0)])
        XCTAssertEqual(r.moved, [0, 1, 2])
    }

    func testNothingOverlapsAfterwardsInACluster() {
        var others: [CGRect] = []
        for i in 0..<4 {
            for j in 0..<3 {
                others.append(CGRect(x: 300 + i * 210, y: 50 + j * 160, width: 200, height: 150))
            }
        }
        let r = Magnetism.resolve(fixed: hand, others: others, reach: 6)
        let grown = hand.insetBy(dx: -6, dy: -6)
        for rect in r.rects {
            XCTAssertFalse(overlaps(grown, rect), "\(rect) still under the hand")
        }
        for i in r.rects.indices {
            for j in r.rects.indices where j > i {
                if others[i].intersects(others[j]) { continue }   // a stack the user made is theirs
                XCTAssertFalse(overlaps(r.rects[i].insetBy(dx: -6, dy: -6), r.rects[j]), "\(i) and \(j) overlap")
            }
        }
    }

    func testResolvingAgainChangesNothing() {
        let others = [
            CGRect(x: 460, y: 320, width: 300, height: 200),
            CGRect(x: 760, y: 320, width: 300, height: 200),
            CGRect(x: 50, y: 350, width: 400, height: 100),
        ]
        let once = Magnetism.resolve(fixed: hand, others: others, reach: 4)
        let twice = Magnetism.resolve(fixed: hand, others: once.rects, reach: 4)
        XCTAssertEqual(twice.rects, once.rects)
        XCTAssertTrue(twice.moved.isEmpty)
    }

    func testAStackTheUserMadeIsNotExploded() {
        // Two windows on top of each other, beside the hand. Pushing the first must not scatter the second.
        let top = CGRect(x: 480, y: 120, width: 300, height: 200)
        let under = CGRect(x: 520, y: 160, width: 300, height: 200)
        let r = Magnetism.resolve(fixed: hand, others: [top, under], reach: 0)
        XCTAssertEqual(r.rects[0].minX, 500)
        XCTAssertEqual(r.rects[1].minX, 520, "under the first, so pushed only by the hand, which doesn't reach it")
    }

    func testDisplacementIsZeroWhenClear() {
        XCTAssertEqual(Magnetism.displacement(of: CGRect(x: 500, y: 100, width: 10, height: 10), outOf: hand, reach: 0), .zero)
        XCTAssertEqual(Magnetism.displacement(of: CGRect(x: 500, y: 100, width: 10, height: 10), outOf: hand, reach: 4), CGVector(dx: 4, dy: 0))
    }

    // MARK: Strength

    func testStrengthMapsGentleToContactAndFirmToAFullGap() {
        XCTAssertEqual(Magnetism.Strength(0).reach(gap: 8), 0)
        XCTAssertEqual(Magnetism.Strength(1).reach(gap: 8), 8)
        XCTAssertEqual(Magnetism.Strength(0.5).reach(gap: 8), 4)
        XCTAssertEqual(Magnetism.Strength(2).value, 1, "clamped")
        XCTAssertEqual(Magnetism.Strength(0).response, 0.30, accuracy: 1e-9)
        XCTAssertEqual(Magnetism.Strength(1).response, 0.12, accuracy: 1e-9)
    }

    // MARK: Follow

    func testFollowArrivesWithoutOvershoot() {
        var f = Magnetism.Follow(position: .zero)
        let target = CGPoint(x: 100, y: -50)
        var lastDistance = CGFloat.infinity
        for _ in 0..<120 {   // one second at 120 Hz
            f.step(toward: target, dt: 1 / 120, response: 0.2)
            let d = hypot(f.position.x - target.x, f.position.y - target.y)
            XCTAssertLessThanOrEqual(d, lastDistance + 1e-6, "never moves away")
            XCTAssertLessThanOrEqual(f.position.x, target.x + 1e-6, "never past")
            lastDistance = d
        }
        XCTAssertTrue(f.isAtRest(at: target))
    }

    func testFollowCoversMostOfTheWayWithinTheResponseTime() {
        var f = Magnetism.Follow(position: .zero)
        f.step(toward: CGPoint(x: 100, y: 0), dt: 0.2, response: 0.2)
        XCTAssertGreaterThan(f.position.x, 88)
        XCTAssertLessThan(f.position.x, 95)
    }

    func testFollowWithNoResponseSnaps() {
        var f = Magnetism.Follow(position: .zero, velocity: CGVector(dx: 500, dy: 0))
        f.step(toward: CGPoint(x: 100, y: 0), dt: 0.01, response: 0)
        XCTAssertEqual(f.position, CGPoint(x: 100, y: 0))
        XCTAssertEqual(f.velocity, .zero)
    }

    // MARK: Inertia

    func testVelocityFollowsASteadyMove() {
        var v = Magnetism.Velocity()
        for i in 0...30 {
            v.add(CGPoint(x: CGFloat(i) * 10, y: 0), at: CFTimeInterval(i) / 120)   // 1200 pt/s
        }
        XCTAssertEqual(v.release(at: 30.0 / 120 + 0.01).dx, 1200, accuracy: 10)
        XCTAssertEqual(v.release(at: 30.0 / 120 + 0.5), .zero, "the hand had stopped")
    }

    func testCoastNeedsSpeedAndStaysShort() {
        XCTAssertNil(Magnetism.Coast(from: .zero, screenVelocity: CGVector(dx: 800, dy: 0), zoom: 1, width: 400, at: 0))
        let c = Magnetism.Coast(from: .zero, screenVelocity: CGVector(dx: 1500, dy: 0), zoom: 1, width: 400, at: 0)!
        XCTAssertEqual(c.end.x, 100, accuracy: 1e-6, "a quarter of the width, not v·τ = 270")
        XCTAssertEqual(c.position(at: 0), .zero)
        XCTAssertLessThan(c.position(at: 0.18).x, c.end.x)
        XCTAssertGreaterThan(c.position(at: 0.18).x, c.end.x * 0.6)
        XCTAssertTrue(c.isOver(at: 1))
        XCTAssertFalse(c.isOver(at: 0.5))
    }

    func testCoastIsCappedOnScreenWhateverTheZoom() {
        // Zoomed out to a quarter: 160 screen points is 640 in the world, but the window is only 2000 wide.
        let c = Magnetism.Coast(from: .zero, screenVelocity: CGVector(dx: 0, dy: 4000), zoom: 0.25, width: 2000, at: 0)!
        XCTAssertEqual(c.end.y, 500, accuracy: 1e-6, "a quarter of the width wins over the 640 the screen would allow")
        let wide = Magnetism.Coast(from: .zero, screenVelocity: CGVector(dx: 0, dy: 4000), zoom: 0.25, width: 20000, at: 0)!
        XCTAssertEqual(wide.end.y, 640, accuracy: 1e-6)
    }

    func testCoastAtTheThresholdIsAlreadyAtTheCap() {
        // 1200 pt/s for 0.18 s would be 216 pt: more than the cap, so a wide window never coasts past 160.
        let c = Magnetism.Coast(from: .zero, screenVelocity: CGVector(dx: 1200, dy: 0), zoom: 1, width: 4000, at: 0)!
        XCTAssertEqual(c.end.x, 160, accuracy: 1e-6)
    }

    // MARK: Settings

    func testMagnetismIsOffByDefaultAndRoundTrips() async {
        await MainActor.run {
            let defaults = UserDefaults.standard
            let on = defaults.object(forKey: "CanvasMagnetism"), strength = defaults.object(forKey: "CanvasMagnetismStrength")
            defer {
                defaults.set(on, forKey: "CanvasMagnetism")
                defaults.set(strength, forKey: "CanvasMagnetismStrength")
            }
            defaults.removeObject(forKey: "CanvasMagnetism")
            defaults.removeObject(forKey: "CanvasMagnetismStrength")
            XCTAssertFalse(Settings.magnetism)
            XCTAssertEqual(Settings.magnetismStrength, 0.5)
            Settings.magnetism = true
            Settings.magnetismStrength = 0.8
            XCTAssertTrue(Settings.magnetism)
            XCTAssertEqual(Settings.magnetismStrength, 0.8)
            Settings.magnetismStrength = 3
            XCTAssertEqual(Settings.magnetismStrength, 1, "clamped")
        }
    }
}
