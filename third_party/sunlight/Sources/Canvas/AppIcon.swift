import AppKit

extension NSImage {
    /// The image drawn into a square bitmap `pixels` wide, from whichever of its representations suits that size best.
    ///
    /// App icons (`NSRunningApplication.icon`, `NSWorkspace.icon(for:)`) say they're 32 pt. Asking them for layer
    /// contents by scale alone renders 32 pt × scale, which a 96 pt icon then stretches into a blur. Naming the
    /// pixel size picks the 256 or 512 px artwork instead.
    func bitmap(pixels: Int) -> CGImage? {
        guard pixels > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
