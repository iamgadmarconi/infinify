import XCTest
@testable import Canvas

final class TutorialTests: XCTestCase {
    func testAHandfulOfStepsForEachInput() {
        for input in Tutorial.Input.allCases {
            let steps = input.steps
            XCTAssertTrue((5...7).contains(steps.count), "\(input)")
            let loops = steps.map(\.gesture) + steps.compactMap(\.also)
            XCTAssertEqual(Set(loops).count, loops.count, "\(input): no loop twice")
            XCTAssertEqual(Set(steps.map(\.title)).count, steps.count, "\(input)")
            for step in steps {
                XCTAssertFalse(step.line.isEmpty, step.title)
                XCTAssertFalse(step.how.isEmpty, step.title)
            }
        }
    }

    /// A trackpad step's words are its gesture's, so a gesture changed in `GestureGuide` changes here
    /// too; every mouse step brings its own.
    func testTrackpadStepsUseTheGesturesOwnWordsAndMouseStepsTheirOwn() {
        for step in Tutorial.trackpad {
            XCTAssertNil(step.mouse, step.title)
            XCTAssertEqual(step.how, step.gesture.how)
        }
        for step in Tutorial.mouse {
            XCTAssertNotNil(step.mouse, step.title)
            XCTAssertFalse(step.how.localizedCaseInsensitiveContains("finger"), step.title)
        }
    }

    /// Both teach the same moves in the same order: see everything first, then the click that goes into a
    /// window, before moving one. The mouse only lacks the four-finger pan.
    func testBothTeachTheSameMovesClickBeforeDrag() {
        XCTAssertEqual(Tutorial.trackpad.filter { $0.gesture != .fourFingerDrag }.map(\.title), Tutorial.mouse.map(\.title))
        for input in Tutorial.Input.allCases {
            let gestures = input.steps.map(\.gesture)
            XCTAssertEqual(gestures.first, .fourFingerTap, "\(input)")
            XCTAssertEqual(input.steps[0].resolved(seeAll: .swipeUp).gesture, .swipeUp, "\(input)")
            XCTAssertEqual(input.steps[1].resolved(seeAll: .swipeUp).gesture, input.steps[1].gesture, "\(input)")
            let click = gestures.firstIndex(of: .click)
            let drag = gestures.firstIndex(of: .drag)
            XCTAssertNotNil(click, "\(input)")
            XCTAssertNotNil(drag, "\(input)")
            if let click, let drag { XCTAssertLessThan(click, drag, "\(input)") }
            XCTAssertEqual(click.map { $0 + 1 }, gestures.firstIndex(of: .doubleClick), "\(input): double-click right after click")
        }
    }

    func testStepsStayInRange() {
        for input in Tutorial.Input.allCases {
            XCTAssertEqual(Tutorial.step(-3, for: input), input.steps.first)
            XCTAssertEqual(Tutorial.step(99, for: input), input.steps.last)
            XCTAssertFalse(Tutorial.isLast(0, for: input))
            XCTAssertTrue(Tutorial.isLast(input.steps.count - 1, for: input))
        }
    }

    /// Going into a window: a click or pinching in, side by side. Four-finger drag comes near the end.
    func testTwoWaysSideBySideAndFourFingerPanNearTheEnd() {
        let click = Tutorial.trackpad.first { $0.gesture == .click }
        XCTAssertEqual(click?.also, .pinchIn)
        XCTAssertTrue(Tutorial.mouse.allSatisfy { $0.also == nil }, "a mouse can't pinch")
        let pan = Tutorial.trackpad.firstIndex { $0.gesture == .fourFingerDrag }
        XCTAssertNotNil(pan)
        if let pan { XCTAssertGreaterThanOrEqual(pan, Tutorial.trackpad.count - 2) }
        XCTAssertFalse(Tutorial.mouse.contains { $0.gesture == .fourFingerDrag })
    }
}
