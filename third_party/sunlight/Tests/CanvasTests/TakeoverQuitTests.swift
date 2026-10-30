import AppKit
import XCTest
@testable import Canvas

final class TakeoverQuitTests: XCTestCase {
    private func code(_ s: String) -> UInt32 { TakeoverMode.fourCharCode(s) }

    private func quit(reason: String?) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: code("aevt"), eventID: code("quit"),
                                                      targetDescriptor: nil, returnID: -1, transactionID: 0)
        if let reason { event.setParam(NSAppleEventDescriptor(enumCode: code(reason)), forKeyword: code("why?")) }
        return event
    }

    func testFourCharCodes() {
        XCTAssertEqual(code("quit"), 0x7175_6974)
        XCTAssertEqual(code("why?"), 0x7768_793F)
    }

    func testAQuitWithNoEventIsTheUsers() {
        XCTAssertFalse(TakeoverMode.isSessionEnding(nil))
    }

    func testAQuitWithNoReasonIsTheUsers() {
        XCTAssertFalse(TakeoverMode.isSessionEnding(quit(reason: nil)))
    }

    func testLogOutRestartAndShutDownEndTheSession() {
        for reason in ["logo", "rlgo", "rrst", "rsdn", "rest", "shut"] {
            XCTAssertTrue(TakeoverMode.isSessionEnding(quit(reason: reason)), reason)
        }
    }

    func testAnotherReasonDoesnt() {
        XCTAssertFalse(TakeoverMode.isSessionEnding(quit(reason: "abcd")))
    }
}
