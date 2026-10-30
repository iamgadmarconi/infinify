import XCTest
@testable import Canvas

final class SystemPrefsTests: XCTestCase {
    private let createDesktop = "com.apple.finder|CreateDesktop"
    private let autohide = "com.apple.dock|autohide"

    func testTakeoverNoLongerTurnsDesktopIconsOff() {
        XCTAssertFalse(SystemPrefs.managed.contains { $0.id == createDesktop })
        XCTAssertTrue(SystemPrefs.retired.contains { $0.id == createDesktop })
    }

    func testARetiredPrefInTheSnapshotIsGivenBackAndDropped() {
        let snapshot: [String: Any] = [createDesktop: true, autohide: false]
        let retired = SystemPrefs.retiredInSnapshot(snapshot)
        XCTAssertEqual(retired.restore.count, 1)
        XCTAssertEqual(retired.restore.first?.0.id, createDesktop)
        XCTAssertEqual(retired.restore.first?.1 as? Bool, true)
        XCTAssertNil(retired.remaining[createDesktop])
        XCTAssertEqual(retired.remaining[autohide] as? Bool, false)
    }

    func testAnAbsentKeyIsDeletedNotDefaulted() {
        let retired = SystemPrefs.retiredInSnapshot([createDesktop: SystemPrefs.absent])
        XCTAssertEqual(retired.restore.count, 1)
        XCTAssertNil(retired.restore.first?.1)
    }

    func testASnapshotWithoutItHasNothingToGiveBack() {
        let retired = SystemPrefs.retiredInSnapshot([autohide: true])
        XCTAssertTrue(retired.restore.isEmpty)
        XCTAssertEqual(retired.remaining.count, 1)
    }
}
