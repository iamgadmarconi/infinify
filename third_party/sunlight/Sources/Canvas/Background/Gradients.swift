import AppKit
import CoreGraphics

/// A built-in gradient: a ground colour and three soft blobs over it, in a light and a dark palette.
/// Drawn as radial gradients (`render`), or drifted by the living shader (`LivingGradientLayer`).
struct CanvasGradient: Identifiable, Equatable {
    struct Palette: Equatable {
        /// sRGB components, 0–1.
        var ground: SIMD3<Float>
        var blobs: [SIMD3<Float>]   // three
    }
    let id: String
    let name: String
    let light: Palette
    let dark: Palette

    func palette(dark: Bool) -> Palette { dark ? self.dark : light }
}

enum Gradients {
    nonisolated static let all: [CanvasGradient] = [
        CanvasGradient(id: "graphite", name: "Graphite",
                 light: CanvasGradient.Palette(ground: [0.90, 0.90, 0.91], blobs: [[0.97, 0.95, 0.90], [0.82, 0.84, 0.88], [0.93, 0.91, 0.93]]),
                 dark: CanvasGradient.Palette(ground: [0.09, 0.09, 0.10], blobs: [[0.19, 0.17, 0.14], [0.11, 0.13, 0.17], [0.15, 0.13, 0.16]])),
        CanvasGradient(id: "dawn", name: "Dawn",
                 light: CanvasGradient.Palette(ground: [0.99, 0.93, 0.80], blobs: [[1.00, 0.80, 0.45], [0.98, 0.70, 0.62], [0.90, 0.86, 0.95]]),
                 dark: CanvasGradient.Palette(ground: [0.16, 0.10, 0.12], blobs: [[0.55, 0.30, 0.14], [0.45, 0.20, 0.30], [0.22, 0.16, 0.36]])),
        CanvasGradient(id: "dusk", name: "Dusk",
                 light: CanvasGradient.Palette(ground: [0.90, 0.88, 0.96], blobs: [[0.75, 0.70, 0.95], [0.96, 0.78, 0.84], [0.70, 0.82, 0.96]]),
                 dark: CanvasGradient.Palette(ground: [0.08, 0.08, 0.17], blobs: [[0.25, 0.18, 0.50], [0.42, 0.16, 0.32], [0.12, 0.22, 0.44]])),
        CanvasGradient(id: "slate", name: "Slate",
                 light: CanvasGradient.Palette(ground: [0.88, 0.91, 0.94], blobs: [[0.75, 0.83, 0.92], [0.92, 0.92, 0.88], [0.80, 0.86, 0.86]]),
                 dark: CanvasGradient.Palette(ground: [0.08, 0.10, 0.13], blobs: [[0.14, 0.20, 0.30], [0.18, 0.18, 0.16], [0.10, 0.17, 0.19]])),
        CanvasGradient(id: "moss", name: "Moss",
                 light: CanvasGradient.Palette(ground: [0.90, 0.93, 0.88], blobs: [[0.76, 0.86, 0.72], [0.93, 0.92, 0.80], [0.70, 0.84, 0.80]]),
                 dark: CanvasGradient.Palette(ground: [0.07, 0.10, 0.08], blobs: [[0.14, 0.26, 0.16], [0.22, 0.22, 0.12], [0.08, 0.20, 0.20]])),
        CanvasGradient(id: "sunlight", name: "Sunlight",
                 light: CanvasGradient.Palette(ground: [1.00, 0.96, 0.84], blobs: [[1.00, 0.85, 0.35], [1.00, 0.74, 0.30], [0.99, 0.92, 0.60]]),
                 dark: CanvasGradient.Palette(ground: [0.12, 0.09, 0.04], blobs: [[0.55, 0.40, 0.08], [0.45, 0.25, 0.06], [0.30, 0.24, 0.08]])),
    ]

    nonisolated static func gradient(id: String) -> CanvasGradient? { all.first { $0.id == id } }

    /// Where the three blobs sit and how far they reach, as fractions of the width and height. The
    /// living shader starts from the same places.
    nonisolated static let blobCenters: [SIMD2<Float>] = [[0.18, 0.22], [0.82, 0.30], [0.55, 0.88]]
    nonisolated static let blobRadius: Float = 0.75

    /// The gradient as a bitmap: the ground, then each blob as a radial fade to clear.
    nonisolated static func render(id: String, dark: Bool, pixelSize: CGSize) -> CGImage? {
        guard let g = gradient(id: id) else { return nil }
        let p = g.palette(dark: dark)
        let w = Int(pixelSize.width), h = Int(pixelSize.height)
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func color(_ c: SIMD3<Float>, alpha: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: space, components: [CGFloat(c.x), CGFloat(c.y), CGFloat(c.z), alpha])!
        }
        ctx.setFillColor(color(p.ground))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let reach = CGFloat(blobRadius) * max(pixelSize.width, pixelSize.height)
        for (i, blob) in p.blobs.prefix(3).enumerated() {
            let c = blobCenters[i]
            let centre = CGPoint(x: CGFloat(c.x) * pixelSize.width, y: (1 - CGFloat(c.y)) * pixelSize.height)
            guard let gradient = CGGradient(colorsSpace: space,
                                            colors: [color(blob), color(blob, alpha: 0.55), color(blob, alpha: 0)] as CFArray,
                                            locations: [0, 0.35, 1]) else { continue }
            ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: reach,
                                   options: [])
        }
        return ctx.makeImage()
    }
}
