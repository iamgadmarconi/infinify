import XCTest
@testable import Canvas

/// The uniforms struct must lay out exactly as the shader's `U` does: float4s at 16, the float2 at 8,
/// floats at 4, padded to 16 at the end.
final class SetupBackdropUniformsTests: XCTestCase {
    func testUniformsMatchTheShaderLayout() {
        typealias U = SetupBackdropLayer.Uniforms
        XCTAssertEqual(MemoryLayout<U>.offset(of: \U.ground), 0)
        XCTAssertEqual(MemoryLayout<U>.offset(of: \U.lights), 16)
        XCTAssertEqual(MemoryLayout<U>.offset(of: \U.centers), 80)
        XCTAssertEqual(MemoryLayout<U>.offset(of: \U.horizon), 144)
        XCTAssertEqual(MemoryLayout<U>.offset(of: \U.aspect), 160)
        XCTAssertEqual(MemoryLayout<U>.offset(of: \U.time), 168)
        XCTAssertEqual(MemoryLayout<U>.offset(of: \U.pulse), 172)
        XCTAssertEqual(MemoryLayout<U>.offset(of: \U.darkness), 176)
        XCTAssertEqual(MemoryLayout<U>.offset(of: \U.contrast), 180)
        XCTAssertEqual(MemoryLayout<U>.offset(of: \U.horizonY), 184)
        XCTAssertEqual(MemoryLayout<U>.size, 188)
        XCTAssertEqual(MemoryLayout<U>.stride, 192)
    }

    func testPalettesHaveFourLightsAndWeights() {
        for palette in [SetupBackdropLayer.Palette.dark, .light] {
            XCTAssertEqual(palette.lights.count, 4)
            XCTAssertEqual(palette.cool.count, 4)
            XCTAssertEqual(palette.warm.count, 4)
        }
        XCTAssertEqual(SetupBackdropLayer.centers.count, 4)
        XCTAssertEqual(SetupBackdropLayer.reach.count, 4)
    }
}
