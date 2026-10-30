import XCTest
@testable import Canvas

final class MoveToApplicationsTests: XCTestCase {
    private typealias Move = MoveToApplications
    private let home = "/Users/someone"

    private func situation(_ path: String, bundle: Bool = true, checkout: Bool = false, arguments: [String] = [],
                           declined: String? = nil) -> Move.Situation {
        Move.Situation(bundlePath: path, home: home, isAppBundle: bundle, insideSourceCheckout: checkout,
                       arguments: arguments, declinedFor: declined)
    }

    func testACopyInAnApplicationsFolderStays() {
        XCTAssertEqual(Move.verdict(for: situation("/Applications/Sunlight.app")), .stay("already in Applications"))
        XCTAssertEqual(Move.verdict(for: situation("/Applications/Utilities/Sunlight.app")), .stay("already in Applications"))
        XCTAssertEqual(Move.verdict(for: situation("/Users/someone/Applications/Sunlight.app")), .stay("already in Applications"))
    }

    /// `make run` runs `build/Sunlight.app` straight from the checkout, and `swift run` a bare binary.
    func testADeveloperBuildStays() {
        XCTAssertEqual(Move.verdict(for: situation("/Users/someone/GitHub/sunbeam/build/Sunlight.app", checkout: true)), .stay("a developer build"))
        XCTAssertEqual(Move.verdict(for: situation("/Users/someone/GitHub/sunbeam/.build/release/Sunlight", bundle: false)), .stay("not an app bundle"))
    }

    func testTheReviewNeverAsks() {
        XCTAssertEqual(Move.verdict(for: situation("/Volumes/Sunlight 0.1/Sunlight.app", arguments: ["--setup-preview", "fresh"])), .stay("review mode"))
    }

    func testTheDiskImageDownloadsAndATranslocatedCopyAreOffered() {
        XCTAssertEqual(Move.verdict(for: situation("/Volumes/Sunlight 0.1/Sunlight.app")), .offer(.volume))
        XCTAssertEqual(Move.verdict(for: situation("/Users/someone/Downloads/Sunlight.app")), .offer(.downloads))
        XCTAssertEqual(Move.verdict(for: situation("/private/var/folders/ab/cd/T/AppTranslocation/0F3B-91C2/d/Sunlight.app")), .offer(.translocated))
        XCTAssertEqual(Move.verdict(for: situation("/Users/someone/Desktop/Sunlight.app")), .offer(.elsewhere))
    }

    func testNotNowIsRememberedForThatCopyOnly() {
        let downloads = "/Users/someone/Downloads/Sunlight.app"
        XCTAssertEqual(Move.verdict(for: situation(downloads, declined: downloads)), .stay("declined for this copy"))
        XCTAssertEqual(Move.verdict(for: situation("/Users/someone/Desktop/Sunlight.app", declined: downloads)), .offer(.elsewhere))
    }

    func testACheckoutIsKnownByItsPackageManifest() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sunlight-move-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let checkout = root.appendingPathComponent("sunbeam")
        let built = checkout.appendingPathComponent("build/Sunlight.app")
        let downloaded = root.appendingPathComponent("Downloads/Sunlight.app")
        try fm.createDirectory(at: built, withIntermediateDirectories: true)
        try fm.createDirectory(at: downloaded, withIntermediateDirectories: true)
        XCTAssertFalse(Move.isInsideSourceCheckout(built), "no manifest yet")
        try Data().write(to: checkout.appendingPathComponent("Package.swift"))
        XCTAssertTrue(Move.isInsideSourceCheckout(built))
        XCTAssertFalse(Move.isInsideSourceCheckout(downloaded))
    }

    /// This checkout: `make app` puts its build under it, so that build is never offered the move.
    func testThisCheckoutsOwnBuildStays() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let built = root.appendingPathComponent("build/Sunlight.app")
        XCTAssertTrue(Move.isInsideSourceCheckout(built))
        let here = Move.Situation(bundlePath: built.path, home: NSHomeDirectory(), isAppBundle: true,
                                  insideSourceCheckout: Move.isInsideSourceCheckout(built), arguments: [], declinedFor: nil)
        XCTAssertEqual(Move.verdict(for: here), .stay("a developer build"))
    }

    func testTheDestinationFallsBackToTheHomeApplicationsFolder() {
        XCTAssertEqual(Move.destinationFolder(home: home, systemFolderWritable: true).path, "/Applications")
        XCTAssertEqual(Move.destinationFolder(home: home, systemFolderWritable: false).path, "/Users/someone/Applications")
    }
}
