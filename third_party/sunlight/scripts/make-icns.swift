// Turns Icon Composer's full-bleed 1024 px render of the icon into an .icns with every size up to
// 512@2x, the tile set in Apple's macOS margin (824 of 1024) with the drop shadow macOS icons carry:
//   swift scripts/make-icns.swift <render.png> <out.icns>
// actool's own .icns stops at 256 px, which looks soft wherever the checked-in copy is drawn large.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let render = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write("usage: swift scripts/make-icns.swift <render.png> <out.icns>\n".data(using: .utf8)!)
    exit(1)
}

func png(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let k = CGFloat(size) / 1024
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * k), blur: 34 * k, color: CGColor(gray: 0, alpha: 0.25))
    ctx.draw(render, in: CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: args[2])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Sunlight-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
