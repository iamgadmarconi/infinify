// Renders the DMG window's background, packaging/dmg/background.png (660 × 420) and background@2x.png: the
// hill photo packaging/dmg/hill.jpg with the install arrow between where the two icons sit.
// scripts/dmg-stage.sh joins the two into the window's HiDPI TIFF.
//   swift scripts/make-dmg-background.swift packaging/dmg
import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: swift scripts/make-dmg-background.swift <packaging/dmg>\n".data(using: .utf8)!)
    exit(1)
}
let dir = URL(fileURLWithPath: args[1])
guard let photo = NSImage(contentsOf: dir.appendingPathComponent("hill.jpg"))?
    .cgImage(forProposedRect: nil, context: nil, hints: nil)
else { FileHandle.standardError.write("No hill.jpg in \(args[1])\n".data(using: .utf8)!); exit(1) }

// The window, in points. The icons (128 px, centred at iconY, see scripts/make-dmg-layout.swift) sit in
// the sky above the crest, which the photo is cropped to put at 84 % of the height so their labels clear
// the grass; the arrow runs between them.
let W: CGFloat = 660, H: CGFloat = 420
let iconY: CGFloat = 200, arrowY = iconY + 6
let ink = CGColor(srgbRed: 46 / 255, green: 35 / 255, blue: 6 / 255, alpha: 1)

// A rounded stroke, like the icon's rays.
func stroke(_ ctx: CGContext, _ points: [CGPoint], width: CGFloat, color: CGColor) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addLines(between: points)
    ctx.strokePath()
}

func render(scale: CGFloat) -> Data {
    let w = Int(W * scale), h = Int(H * scale)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.draw(photo, in: CGRect(x: 0, y: 0, width: w, height: h))

    // Points, top-down, like the layout above.
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: scale, y: -scale)
    stroke(ctx, [CGPoint(x: 246, y: arrowY), CGPoint(x: 410, y: arrowY)], width: 6, color: ink)
    stroke(ctx, [CGPoint(x: 394, y: arrowY - 15.6), CGPoint(x: 414, y: arrowY), CGPoint(x: 394, y: arrowY + 15.6)],
           width: 6, color: ink)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: dir.appendingPathComponent("background.png"))
try render(scale: 2).write(to: dir.appendingPathComponent("background@2x.png"))
print("Rendered \(args[1])/background.png and background@2x.png")
