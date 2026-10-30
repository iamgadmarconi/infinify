import XCTest
@testable import Canvas

@MainActor
final class StreamLimitTests: XCTestCase {
    private typealias Candidate = (id: ObjectIdentifier, area: CGFloat, streaming: Bool, capped: Bool)
    private let objects = (0..<12).map { _ in NSObject() }

    private func candidate(_ i: Int, area: CGFloat, streaming: Bool = false, capped: Bool = false) -> Candidate {
        (ObjectIdentifier(objects[i]), area, streaming, capped)
    }

    func testEveryoneStreamsUpToTheLimit() {
        let all = (0..<3).map { candidate($0, area: 0) }
        XCTAssertEqual(CanvasController.streamed(all, moving: false, limit: 3).count, 3)
    }

    func testTheLargestStreamPastTheLimit() {
        let all = (0..<5).map { candidate($0, area: CGFloat($0 + 1) * 100) }
        let chosen = CanvasController.streamed(all, moving: false, limit: 2)
        XCTAssertEqual(chosen, [all[4].id, all[3].id])
    }

    func testAStreamHoldsAgainstASlightlyLargerNewcomer() {
        let all = [candidate(0, area: 100, streaming: true), candidate(1, area: 120), candidate(2, area: 10)]
        XCTAssertEqual(CanvasController.streamed(all, moving: false, limit: 1), [all[0].id])
        let bigger = [candidate(0, area: 100, streaming: true), candidate(1, area: 200)]
        XCTAssertEqual(CanvasController.streamed(bigger, moving: false, limit: 1), [bigger[1].id])
    }

    func testNoNewStreamForAStillWhileTheCameraMoves() {
        let all = [candidate(0, area: 100, streaming: true), candidate(1, area: 1000, capped: true), candidate(2, area: 10)]
        XCTAssertEqual(CanvasController.streamed(all, moving: true, limit: 2), [all[0].id, all[2].id])
        XCTAssertTrue(CanvasController.streamed(all, moving: false, limit: 2).contains(all[1].id))
    }

    func testNoStreamsWithoutScreenCaptureMode() {
        let all = (0..<3).map { candidate($0, area: 100, streaming: $0 == 0) }
        XCTAssertTrue(CanvasController.streamed(all, moving: false, limit: 0).isEmpty)
    }
}
