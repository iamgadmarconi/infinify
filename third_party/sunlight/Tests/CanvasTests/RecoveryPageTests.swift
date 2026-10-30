import XCTest
@testable import Canvas

/// The Recovery card's QR code opens a page on sunlight.software with the same steps as the card.
@MainActor
final class RecoveryPageTests: XCTestCase {
    private let variants: [RecoveryCard.Variant] = [.liveWindows, .protectionBackOn]

    func testTheShareTextWorksOfflineAndLinksThePage() {
        for variant in variants {
            XCTAssertTrue(variant.shareText.contains(variant.commands))
            XCTAssertTrue(variant.shareText.hasSuffix(variant.page.absoluteString))
        }
    }

    /// A short address keeps the code coarse enough to scan off a screen at arm's length.
    func testTheQRCodeIsCoarse() throws {
        let image = try XCTUnwrap(RecoveryCard.qrCode(RecoveryCard.Variant.liveWindows.page.absoluteString, side: 132))
        XCTAssertLessThanOrEqual(image.size.width, 132)
        XCTAssertGreaterThanOrEqual(image.size.width, 100)
    }
}
