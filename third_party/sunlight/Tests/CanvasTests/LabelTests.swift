import XCTest
@testable import Canvas

final class LabelTests: XCTestCase {
    func testLabelRendersOnceAtTheBackingScale() {
        let style = WindowProxy.LabelStyle(ink: .white, shadow: true)
        let image = WindowProxy.renderLabel("Safari — Sunlight", style: style, scale: 2)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, Int(WindowProxy.labelMaxWidth * 2))
        XCTAssertEqual(image?.height, Int(WindowProxy.labelHeight * 2))
        // Something was drawn: a pixel row through the text isn't all clear.
        guard let image, let data = image.dataProvider?.data as Data? else { return XCTFail("no bitmap") }
        let row = image.bytesPerRow * (image.height / 2)
        let drawn = data[row..<(row + 40 * 4)].contains { $0 != 0 }
        XCTAssertTrue(drawn)
        XCTAssertNotNil(WindowProxy.renderLabel("", style: style, scale: 1))
    }
}
