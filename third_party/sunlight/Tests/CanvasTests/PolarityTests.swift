import XCTest
@testable import Canvas

final class PolarityTests: XCTestCase {
    private let hand = CGRect(x: 100, y: 100, width: 400, height: 300)
    /// A Firm-ish push reach, and the pull starting twice that out.
    private let reach: CGFloat = 8
    private var pull: Magnetism.Attraction { Magnetism.Attraction(reach: 16, gap: reach) }

    private func body(_ rect: CGRect, _ pole: Polarity?) -> Magnetism.Body { Magnetism.Body(rect, pole: pole) }
    private func moved(_ b: Magnetism.Body, _ r: Magnetism.BodyResolution, _ i: Int) -> Magnetism.Body { b.offsetBy(r.offsets[i]) }

    // MARK: Polarity

    func testRelationSameRepelsOppositeAttractsNilNeutral() {
        XCTAssertEqual(Polarity.relation(.plus, .plus), .repel)
        XCTAssertEqual(Polarity.relation(.minus, .minus), .repel)
        XCTAssertEqual(Polarity.relation(.plus, .minus), .attract)
        XCTAssertEqual(Polarity.relation(.minus, .plus), .attract)
        XCTAssertEqual(Polarity.relation(nil, .plus), .neutral)
        XCTAssertEqual(Polarity.relation(.minus, nil), .neutral)
        XCTAssertEqual(Polarity.relation(nil, nil), .neutral)
    }

    func testFlippedToggles() {
        XCTAssertEqual(Polarity.plus.flipped, .minus)
        XCTAssertEqual(Polarity.minus.flipped, .plus)
        XCTAssertEqual(Polarity.plus.flipped.flipped, .plus)
        XCTAssertNotEqual(Polarity.plus.glyph, Polarity.minus.glyph)
        XCTAssertEqual(Polarity(rawValue: "minus"), .minus)
    }

    // MARK: Grouping

    func testMembersOfUngroupedIsItself() {
        let g = Grouping()
        XCTAssertEqual(g.members(of: 7), [7])
        XCTAssertFalse(g.isGrouped(7))
        XCTAssertNil(g.group(of: 7))
        XCTAssertTrue(g.isEmpty)
    }

    func testMergeTwoFreeMakesOneGroup() {
        var g = Grouping()
        g.merge(2, 1)
        XCTAssertEqual(g.members(of: 1), [1, 2])
        XCTAssertEqual(g.members(of: 2), [2, 1], "the window asked about comes first")
        XCTAssertTrue(g.isGrouped(1))
        XCTAssertEqual(g.group(of: 1), g.group(of: 2))
        g.merge(1, 1)
        XCTAssertEqual(g.members(of: 1), [1, 2], "a window can't bond with itself")
    }

    func testMergeGroupWithGroupUnionsIDs() {
        var g = Grouping()
        g.merge(1, 2)
        g.merge(3, 4)
        g.merge(2, 3)
        XCTAssertEqual(g.members(of: 4), [4, 1, 2, 3])
        g.merge(1, 5)
        XCTAssertEqual(g.members(of: 5), [5, 1, 2, 3, 4], "a free window joins an existing group")
    }

    func testRemoveLeavesSingletonInert() {
        var g = Grouping()
        g.merge(1, 2)
        g.remove(1)
        XCTAssertEqual(g.members(of: 1), [1])
        XCTAssertEqual(g.members(of: 2), [2], "alone in its group: as good as free")
        XCTAssertFalse(g.isGrouped(2))
        XCTAssertNotNil(g.group(of: 2), "but still numbered, so a restore can add the second member later")
        g.dissolve(groupOf: 2)
        XCTAssertNil(g.group(of: 2))
    }

    func testDissolveFreesTheWholeGroup() {
        var g = Grouping()
        g.merge(1, 2)
        g.merge(2, 3)
        g.merge(8, 9)
        g.dissolve(groupOf: 2)
        XCTAssertEqual(g.members(of: 1), [1])
        XCTAssertEqual(g.members(of: 3), [3])
        XCTAssertEqual(g.members(of: 8), [8, 9], "another group is untouched")
    }

    func testGroupingIsAValueForUndo() {
        var g = Grouping()
        g.merge(1, 2)
        let before = g
        g.merge(2, 3)
        XCTAssertEqual(before.members(of: 1), [1, 2])
        XCTAssertNotEqual(before, g)
    }

    func testSavedNumbersOnlyGroupsWithAPartnerPresent() {
        var g = Grouping()
        g.merge(1, 2)
        g.merge(3, 4)
        g.merge(5, 6)
        let saved = g.saved(for: [4, 3, 1, 2, 5, 9])
        XCTAssertEqual(saved[4], 0)
        XCTAssertEqual(saved[3], 0)
        XCTAssertEqual(saved[1], 1)
        XCTAssertEqual(saved[2], 1)
        XCTAssertNil(saved[5], "its partner isn't being saved")
        XCTAssertNil(saved[9], "free")
    }

    func testAdoptRemapsSavedIDsAndIsStableAcrossArrivals() {
        var g = Grouping()
        g.merge(100, 101)   // a live group already numbered 0
        var remap: [Int: Int] = [:]
        g.adopt(saved: 0, for: 1, remap: &remap)
        XCTAssertEqual(g.members(of: 1), [1], "the first member back is alone for now")
        XCTAssertEqual(g.members(of: 100), [100, 101], "and not in the live group that happens to be number 0")
        g.adopt(saved: 0, for: 2, remap: &remap)
        g.adopt(saved: 1, for: 3, remap: &remap)
        XCTAssertEqual(g.members(of: 1), [1, 2])
        XCTAssertEqual(g.members(of: 3), [3])
        XCTAssertNotEqual(g.group(of: 1), g.group(of: 3))
    }

    func testSplitSeparatesWhatNoLongerTouches() {
        // Three in a row, a tile gap apart; take the middle one away.
        let a = CGRect(x: 0, y: 0, width: 200, height: 300)
        let b = CGRect(x: 208, y: 0, width: 200, height: 300)
        let c = CGRect(x: 416, y: 0, width: 200, height: 300)
        let rects: [CGWindowID: CGRect] = [1: a, 2: b, 3: c]
        XCTAssertEqual(Grouping.split([1, 2, 3], rects: rects, gap: 8), [[1, 2, 3]])
        XCTAssertEqual(Grouping.split([1, 3], rects: rects, gap: 8), [[1], [3]])
        XCTAssertEqual(Grouping.split([3, 1, 2], rects: rects, gap: 8), [[3, 2, 1]], "pieces start with the first ID given")
        XCTAssertEqual(Grouping.split([1, 3, 4], rects: rects, gap: 8), [[1, 4], [3]], "no rect: stays with the first piece")

        var g = Grouping()
        g.merge(1, 2)
        g.merge(2, 3)
        g.remove(2, rects: rects, gap: 8)
        XCTAssertEqual(g.members(of: 1), [1], "the two left don't touch: both free")
        XCTAssertEqual(g.members(of: 3), [3])

        var h = Grouping()
        h.merge(1, 2)
        h.merge(2, 3)
        h.remove(3, rects: rects, gap: 8)
        XCTAssertEqual(h.members(of: 1), [1, 2], "the two left still touch: still a group")
    }

    func testSplitKeepsAnLShapedGroupTogether() {
        let left = CGRect(x: 0, y: 0, width: 200, height: 500)
        let topRight = CGRect(x: 208, y: 0, width: 200, height: 200)
        let bottomRight = CGRect(x: 208, y: 208, width: 200, height: 292)
        let rects: [CGWindowID: CGRect] = [1: left, 2: topRight, 3: bottomRight]
        XCTAssertEqual(Grouping.split([2, 3], rects: rects, gap: 8), [[2, 3]], "one above the other")
        XCTAssertEqual(Grouping.split([1, 2, 3], rects: rects, gap: 8), [[1, 2, 3]])
        XCTAssertEqual(Grouping.split([2, 3], rects: rects, gap: 4), [[2], [3]], "a gap too wide")
    }

    // MARK: Bodies

    func testSingleRectWrapperMatchesLegacyResolve() {
        var others: [CGRect] = []
        for i in 0..<4 {
            for j in 0..<3 {
                others.append(CGRect(x: 300 + i * 210, y: 50 + j * 160, width: 200, height: 150))
            }
        }
        let legacy = Magnetism.resolve(fixed: hand, others: others, reach: 6)
        let bodies = Magnetism.resolve(fixed: Magnetism.Body(hand), others: others.map { Magnetism.Body($0) }, reach: 6)
        XCTAssertEqual(bodies.offsets.count, others.count)
        XCTAssertEqual(legacy.moved, bodies.moved)
        XCTAssertTrue(bodies.pulled.isEmpty, "nothing is pulled without attraction")
        for (i, rect) in others.enumerated() {
            XCTAssertEqual(legacy.rects[i], rect.offsetBy(dx: bodies.offsets[i].dx, dy: bodies.offsets[i].dy))
        }
    }

    func testBodyDisplacementMatchesRectDisplacementForOneWindow() {
        let r = CGRect(x: 460, y: 320, width: 300, height: 200)
        XCTAssertEqual(Magnetism.displacement(of: Magnetism.Body(r), outOf: Magnetism.Body(hand), reach: 4),
                       Magnetism.displacement(of: r, outOf: hand, reach: 4))
        let inside = CGRect(x: 110, y: 120, width: 20, height: 20)
        XCTAssertEqual(Magnetism.displacement(of: Magnetism.Body(inside), outOf: Magnetism.Body(hand), reach: 0),
                       Magnetism.displacement(of: inside, outOf: hand, reach: 0))
    }

    func testBodyAxisComesFromUnionMagnitudeFromDeepestMember() {
        // Two windows one above the other, both into the hand's right edge: one by 60, one by 30.
        let top = CGRect(x: 440, y: 100, width: 200, height: 100)
        let bottom = CGRect(x: 470, y: 200, width: 200, height: 200)
        let group = Magnetism.Body(rects: [top, bottom], poles: [nil, nil])
        let r = Magnetism.resolve(fixed: Magnetism.Body(hand), others: [group], reach: 0)
        XCTAssertEqual(r.offsets, [CGVector(dx: 60, dy: 0)], "the deeper one decides how far; both go")
        XCTAssertEqual(r.moved, [0])
    }

    func testPushedBodyIsRigid() {
        let top = CGRect(x: 440, y: 100, width: 200, height: 100)
        let bottom = CGRect(x: 470, y: 200, width: 200, height: 200)
        let group = Magnetism.Body(rects: [top, bottom], poles: [nil, nil])
        let r = Magnetism.resolve(fixed: Magnetism.Body(hand), others: [group], reach: 6)
        let after = moved(group, r, 0)
        XCTAssertEqual(after.rects[1].minX - after.rects[0].minX, bottom.minX - top.minX)
        XCTAssertEqual(after.rects[1].minY - after.rects[0].minY, bottom.minY - top.minY)
        for rect in after.rects { XCTAssertFalse(hand.insetBy(dx: -6, dy: -6).intersects(rect)) }
    }

    func testBodyStraddlingThePusherMovesOneWayAndEndsClear() {
        // One member into the hand's left edge, one into its right: no single sideways move frees both,
        // so the body goes along the other axis, as one.
        let left = CGRect(x: -140, y: 150, width: 250, height: 100)
        let right = CGRect(x: 490, y: 150, width: 250, height: 100)
        let group = Magnetism.Body(rects: [left, right], poles: [nil, nil])
        let r = Magnetism.resolve(fixed: Magnetism.Body(hand), others: [group], reach: 0)
        XCTAssertEqual(r.offsets.count, 1)
        XCTAssertEqual(r.offsets[0].dx, 0)
        XCTAssertNotEqual(r.offsets[0].dy, 0)
        for rect in moved(group, r, 0).rects { XCTAssertFalse(hand.intersects(rect), "\(rect) still under the hand") }
    }

    func testBodyWhoseUnionButNoMemberOverlapsIsLeftAlone() {
        // An L around the hand's corner: its bounds cover the hand, its arms don't touch it.
        let upright = CGRect(x: 520, y: 0, width: 100, height: 500)
        let foot = CGRect(x: 100, y: 420, width: 520, height: 100)
        let l = Magnetism.Body(rects: [upright, foot], poles: [nil, nil])
        XCTAssertTrue(l.bounds.intersects(hand))
        XCTAssertEqual(Magnetism.displacement(of: l, outOf: Magnetism.Body(hand), reach: 0), .zero)
        let r = Magnetism.resolve(fixed: Magnetism.Body(hand), others: [l], reach: 0)
        XCTAssertTrue(r.moved.isEmpty)
        // And the other way about: the hand as an L doesn't push a window in its notch.
        let notch = Magnetism.Body(hand)
        XCTAssertEqual(Magnetism.displacement(of: notch, outOf: l, reach: 0), .zero)
    }

    func testChainPushesThroughAGroup() {
        // The hand overlaps the group by 60; the group's far member touches a free window behind it.
        let near = CGRect(x: 440, y: 100, width: 200, height: 150)
        let far = CGRect(x: 640, y: 100, width: 200, height: 150)
        let behind = CGRect(x: 840, y: 100, width: 200, height: 150)
        let group = Magnetism.Body(rects: [near, far], poles: [nil, nil])
        let r = Magnetism.resolve(fixed: Magnetism.Body(hand), others: [Magnetism.Body(behind), group], reach: 0)
        XCTAssertEqual(r.offsets, [CGVector(dx: 60, dy: 0), CGVector(dx: 60, dy: 0)])
        XCTAssertEqual(r.moved, [0, 1])
    }

    func testStackedBodiesAreLeftToEachOther() {
        // A group beside the hand, with a free window lying across it: pushing the group mustn't scatter it.
        let a = CGRect(x: 480, y: 120, width: 200, height: 200)
        let b = CGRect(x: 688, y: 120, width: 200, height: 200)
        let across = CGRect(x: 600, y: 160, width: 300, height: 100)
        let group = Magnetism.Body(rects: [a, b], poles: [nil, nil])
        let r = Magnetism.resolve(fixed: Magnetism.Body(hand), others: [group, Magnetism.Body(across)], reach: 0)
        XCTAssertEqual(r.offsets[0], CGVector(dx: 20, dy: 0))
        XCTAssertEqual(r.offsets[1], .zero, "lying across the group to begin with, so left there")
    }

    // MARK: Attraction

    func testOppositePoleWithinReachIsPulledToGap() {
        let other = CGRect(x: 512, y: 150, width: 200, height: 100)   // 12 pt off the hand's right edge
        let r = Magnetism.resolve(fixed: body(hand, .plus), others: [body(other, .minus)], reach: reach, attraction: pull)
        XCTAssertEqual(r.offsets, [CGVector(dx: -4, dy: 0)], "in to the gap of 8")
        XCTAssertEqual(r.pulled, [0])
        XCTAssertEqual(r.moved, [0])
        XCTAssertEqual(moved(body(other, .minus), r, 0).rects[0].minX, hand.maxX + reach)
    }

    func testPulledKeepsItsOtherCoordinate() {
        let other = CGRect(x: 512, y: 150, width: 200, height: 100)
        let r = Magnetism.resolve(fixed: body(hand, .plus), others: [body(other, .minus)], reach: reach, attraction: pull)
        XCTAssertEqual(r.offsets[0].dy, 0)
        let below = CGRect(x: 150, y: 414, width: 200, height: 100)   // 14 pt under the hand
        let d = Magnetism.resolve(fixed: body(hand, .minus), others: [body(below, .plus)], reach: reach, attraction: pull)
        XCTAssertEqual(d.offsets, [CGVector(dx: 0, dy: -6)])
    }

    func testOppositePoleAlreadyAtTheGapIsHeldNotMoved() {
        let other = CGRect(x: 508, y: 150, width: 200, height: 100)
        let r = Magnetism.resolve(fixed: body(hand, .plus), others: [body(other, .minus)], reach: reach, attraction: pull)
        XCTAssertEqual(r.offsets, [.zero])
        XCTAssertEqual(r.pulled, [0], "held: the view bonds it")
        XCTAssertTrue(r.moved.isEmpty)
    }

    func testOppositePoleBeyondReachIsLeftAlone() {
        let other = CGRect(x: 530, y: 150, width: 200, height: 100)   // 30 pt off
        let r = Magnetism.resolve(fixed: body(hand, .plus), others: [body(other, .minus)], reach: reach, attraction: pull)
        XCTAssertEqual(r.offsets, [.zero])
        XCTAssertTrue(r.pulled.isEmpty)
        XCTAssertTrue(r.moved.isEmpty)
    }

    func testLikePoleIsPushedNotPulled() {
        let other = CGRect(x: 460, y: 320, width: 300, height: 200)   // 40 in from the right, 80 from the bottom
        let r = Magnetism.resolve(fixed: body(hand, .plus), others: [body(other, .plus)], reach: 0, attraction: pull)
        XCTAssertEqual(r.offsets, [CGVector(dx: 40, dy: 0)], "today's push")
        XCTAssertTrue(r.pulled.isEmpty)
        let near = CGRect(x: 510, y: 150, width: 200, height: 100)   // within reach, but like poles
        let n = Magnetism.resolve(fixed: body(hand, .minus), others: [body(near, .minus)], reach: reach, attraction: pull)
        XCTAssertEqual(n.offsets, [.zero])
        XCTAssertTrue(n.pulled.isEmpty)
    }

    func testNeutralIsNeverPulled() {
        let widget = CGRect(x: 512, y: 150, width: 200, height: 100)
        let r = Magnetism.resolve(fixed: body(hand, .plus), others: [body(widget, nil)], reach: reach, attraction: pull)
        XCTAssertEqual(r.offsets, [.zero])
        XCTAssertTrue(r.pulled.isEmpty)
        let unpoled = Magnetism.resolve(fixed: body(hand, nil), others: [body(widget, .minus)], reach: reach, attraction: pull)
        XCTAssertTrue(unpoled.pulled.isEmpty, "a hand without a pole pulls nothing")
    }

    func testOverlappingOppositePoleIsPushedOutToGapOnSmallerAxis() {
        let other = CGRect(x: 460, y: 320, width: 300, height: 200)   // 40 in from the right, 80 from the bottom
        let r = Magnetism.resolve(fixed: body(hand, .plus), others: [body(other, .minus)], reach: reach, attraction: pull)
        XCTAssertEqual(r.offsets, [CGVector(dx: 48, dy: 0)], "out to the right, to the gap, same y")
        XCTAssertEqual(r.pulled, [0], "and held there")
    }

    func testDiagonalOppositePoleIsNotPulled() {
        let corner = CGRect(x: 510, y: 410, width: 100, height: 100)   // off the bottom-right corner
        XCTAssertNil(Magnetism.attach(corner, to: hand, gap: reach, reach: 16))
        let r = Magnetism.resolve(fixed: body(hand, .plus), others: [body(corner, .minus)], reach: reach, attraction: pull)
        XCTAssertEqual(r.offsets, [.zero])
        XCTAssertTrue(r.pulled.isEmpty)
    }

    func testAttachAcceptsATouchingNeighbour() {
        let touching = CGRect(x: 500, y: 150, width: 200, height: 100)
        XCTAssertEqual(Magnetism.attach(touching, to: hand, gap: reach, reach: 16), CGVector(dx: 8, dy: 0))
        XCTAssertEqual(Magnetism.attach(touching, to: hand, gap: 0, reach: 16), .zero, "Gentle: touching is the gap")
    }

    func testPullPicksNearestOppositeMemberOfHeldGroup() {
        // The hand is a bonded pair, both +; a − window is just off the right-hand member.
        let a = hand
        let b = CGRect(x: 508, y: 100, width: 200, height: 300)
        let held = Magnetism.Body(rects: [a, b], poles: [.plus, .plus])
        let other = CGRect(x: 720, y: 150, width: 200, height: 100)   // 12 off b
        let r = Magnetism.resolve(fixed: held, others: [body(other, .minus)], reach: reach, attraction: pull)
        XCTAssertEqual(r.offsets, [CGVector(dx: -4, dy: 0)])
        XCTAssertEqual(r.pulled, [0])
    }

    func testAttachmentThatWouldLandOnALikePoledMemberIsRefused() {
        // The hand is [A+][B−], B hanging 50 pt below A. A − window under A is drawn to A, but the spot
        // under A is beside B's overhang, where B (its like pole) would push it: no pull, just the push.
        let a = hand
        let b = CGRect(x: 508, y: 100, width: 200, height: 350)
        let held = Magnetism.Body(rects: [a, b], poles: [.plus, .minus])
        let c = CGRect(x: 300, y: 412, width: 400, height: 100)
        XCTAssertNil(Magnetism.attachment(of: body(c, .minus), to: held, pull, clearOf: reach))
        let r = Magnetism.resolve(fixed: held, others: [body(c, .minus)], reach: reach, attraction: pull)
        XCTAssertTrue(r.pulled.isEmpty)
        XCTAssertEqual(r.moved, [0], "pushed clear of B instead")
        let after = moved(body(c, .minus), r, 0)
        XCTAssertFalse(b.insetBy(dx: -reach, dy: -reach).intersects(after.rects[0]))
        // Settled: asking again changes nothing.
        let again = Magnetism.resolve(fixed: held, others: [after], reach: reach, attraction: pull)
        XCTAssertEqual(again.offsets, [.zero])
    }

    func testWindowCaughtBetweenTheHandAndAPulledWindowGoesSideways() {
        // E (neutral) overlaps the hand's right edge by 40; D (−) is 12 pt off that edge, pulled in to 8.
        // E can't go right (into D) and can't stay: it leaves along y, and nothing overlaps at the end.
        let e = CGRect(x: 460, y: 150, width: 100, height: 100)
        let d = CGRect(x: 512, y: 150, width: 200, height: 100)
        let r = Magnetism.resolve(fixed: body(hand, .plus), others: [body(e, nil), body(d, .minus)], reach: reach, attraction: pull)
        XCTAssertEqual(r.pulled, [1])
        XCTAssertEqual(r.offsets[1], CGVector(dx: -4, dy: 0), "D is pulled to the gap, nothing shoves it")
        XCTAssertEqual(r.offsets[0].dx, 0, "E leaves along y")
        let eAfter = moved(body(e, nil), r, 0).rects[0], dAfter = moved(body(d, .minus), r, 1).rects[0]
        XCTAssertFalse(hand.insetBy(dx: -reach, dy: -reach).intersects(eAfter))
        XCTAssertFalse(dAfter.insetBy(dx: -reach, dy: -reach).intersects(eAfter))
    }

    func testPulledBodyPushesWhatIsBehindIt() {
        // D (−) lies 40 over the hand: out it goes to the gap, and F behind it is shoved along.
        let d = CGRect(x: 460, y: 150, width: 300, height: 100)
        let f = CGRect(x: 770, y: 150, width: 200, height: 100)
        let r = Magnetism.resolve(fixed: body(hand, .plus), others: [body(d, .minus), body(f, nil)], reach: reach, attraction: pull)
        XCTAssertEqual(r.pulled, [0])
        XCTAssertEqual(r.offsets[0], CGVector(dx: 48, dy: 0))
        XCTAssertEqual(r.offsets[1], CGVector(dx: 46, dy: 0), "D's new right edge plus the reach")
        XCTAssertEqual(r.moved, [0, 1])
    }

    func testPulledGroupMovesAsOne() {
        // A free pair [C−][E−] (a group of its own) just off the hand: pulled in together.
        let c = CGRect(x: 512, y: 150, width: 200, height: 100)
        let e = CGRect(x: 720, y: 150, width: 200, height: 100)
        let group = Magnetism.Body(rects: [c, e], poles: [.minus, .minus])
        let r = Magnetism.resolve(fixed: body(hand, .plus), others: [group], reach: reach, attraction: pull)
        XCTAssertEqual(r.offsets, [CGVector(dx: -4, dy: 0)])
        XCTAssertEqual(r.pulled, [0])
    }

    func testResolvingAgainAfterAttractionChangesNothing() {
        let others = [
            body(CGRect(x: 512, y: 150, width: 200, height: 100), .minus),    // pulled
            body(CGRect(x: 460, y: 320, width: 300, height: 200), .plus),     // pushed
            body(CGRect(x: 150, y: 410, width: 200, height: 100), .minus),    // pulled up
            body(CGRect(x: 760, y: 320, width: 300, height: 200), nil),       // behind the pushed one
        ]
        let once = Magnetism.resolve(fixed: body(hand, .plus), others: others, reach: reach, attraction: pull)
        let settled = others.indices.map { moved(others[$0], once, $0) }
        let twice = Magnetism.resolve(fixed: body(hand, .plus), others: settled, reach: reach, attraction: pull)
        XCTAssertEqual(twice.offsets, [CGVector](repeating: .zero, count: others.count))
        XCTAssertTrue(twice.moved.isEmpty)
        XCTAssertEqual(twice.pulled, once.pulled, "still held")
        for (i, a) in settled.enumerated() {
            XCTAssertFalse(a.overlaps(body(hand, .plus)), "\(i) under the hand")
            for (j, b) in settled.enumerated() where j > i {
                XCTAssertFalse(a.overlaps(b), "\(i) and \(j) overlap")
            }
        }
    }

    func testAdjacentIsSideBySideWithinTheGap() {
        let a = CGRect(x: 0, y: 0, width: 200, height: 300)
        XCTAssertTrue(Magnetism.adjacent(a, CGRect(x: 208, y: 0, width: 200, height: 300), within: 8))
        XCTAssertTrue(Magnetism.adjacent(a, CGRect(x: 208.4, y: 100, width: 200, height: 300), within: 8), "half a point of slack")
        XCTAssertFalse(Magnetism.adjacent(a, CGRect(x: 210, y: 0, width: 200, height: 300), within: 8))
        XCTAssertTrue(Magnetism.adjacent(a, CGRect(x: 0, y: 308, width: 200, height: 300), within: 8))
        XCTAssertFalse(Magnetism.adjacent(a, CGRect(x: 208, y: 308, width: 200, height: 300), within: 8), "corner to corner")
        XCTAssertTrue(Magnetism.adjacent(a, CGRect(x: 100, y: 100, width: 200, height: 300), within: 0), "on top of each other")
    }
}
