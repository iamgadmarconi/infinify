import AppKit
import XCTest
@testable import Canvas

final class AppIconTests: XCTestCase {
    func testAppIconRendersAtTheAskedPixelSize() throws {
        // App icons report 32 pt; the bitmap must still come out at full size, not 32 × scale.
        let icon = NSWorkspace.shared.icon(for: .application)
        XCTAssertEqual(icon.size, NSSize(width: 32, height: 32))
        let cg = try XCTUnwrap(icon.bitmap(pixels: 216))
        XCTAssertEqual(cg.width, 216)
        XCTAssertEqual(cg.height, 216)
    }

    func testBitmapUsesTheLargeArtwork() throws {
        // A small image with a big, detailed rep: drawn at 128 px, a checkerboard survives only if the big rep is used.
        let big = Self.rep(pixels: 128) { x, y in (x + y) % 2 == 0 ? 0 : 255 }
        let small = Self.rep(pixels: 32) { _, _ in 128 }
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.addRepresentation(small)
        image.addRepresentation(big)

        let out = NSBitmapImageRep(cgImage: try XCTUnwrap(image.bitmap(pixels: 128)))
        let a = try XCTUnwrap(out.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        let b = try XCTUnwrap(out.colorAt(x: 11, y: 10)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(abs(a.brightnessComponent - b.brightnessComponent), 0.8)
    }

    /// A grey bitmap rep, 32 pt square, filled byte by byte (`setColor` silently writes nothing into a fresh rep).
    private static func rep(pixels: Int, shade: (Int, Int) -> UInt8) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let data = rep.bitmapData!
        for x in 0..<pixels { for y in 0..<pixels {
            let offset = y * rep.bytesPerRow + x * 4, value = shade(x, y)
            data[offset] = value; data[offset + 1] = value; data[offset + 2] = value; data[offset + 3] = 255
        } }
        rep.size = NSSize(width: 32, height: 32)
        return rep
    }
}
