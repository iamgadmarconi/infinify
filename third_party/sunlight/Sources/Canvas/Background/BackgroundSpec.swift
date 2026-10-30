import AppKit

/// What's behind the windows: where the picture comes from and how it's treated. One value, saved as a
/// property list under `CanvasBackgroundSpec` so `defaults read` shows it, and embedded in a layout that
/// remembers its background. The two canvas colours stay in their own keys (`Settings.lightBackground`,
/// `Settings.darkBackground`); `.color` points at them.
struct BackgroundSpec: Codable, Equatable {
    enum Source: Codable, Equatable {
        /// The light or dark canvas colour, as before there were pictures.
        case color
        /// Whatever System Settings › Wallpaper shows on the main display, Dynamic Desktops included.
        case macWallpaper
        /// A picture copied into Application Support: its file name, and the file for the dark appearance
        /// if a second one was chosen.
        case image(light: String, dark: String?)
        /// One of the built-in gradients (`Gradients.all`), by id.
        case gradient(String)

        var isImage: Bool {
            if case .image = self { return true }
            return false
        }
        var isGradient: Bool {
            if case .gradient = self { return true }
            return false
        }
        /// Whether there's a picture to blur: a colour has nothing to blur, a gradient is smooth already.
        var isPicture: Bool { self == .macWallpaper || isImage }
    }

    /// iOS's four photo styles, in its order.
    enum Style: String, Codable, CaseIterable {
        case natural, blackAndWhite, duotone, colorWash

        var title: String {
            switch self {
            case .natural: return "Natural"
            case .blackAndWhite: return "Black & White"
            case .duotone: return "Duotone"
            case .colorWash: return "Colour Wash"
            }
        }
        var usesTint: Bool { self == .duotone || self == .colorWash }
    }

    /// How far the picture blurs, at most: at the zoomed-out end when the blur follows the zoom, always
    /// when it doesn't. The radii are in display pixels (see `BackgroundPipeline.levelRadii`).
    enum Blur: String, Codable, CaseIterable {
        case off, soft, deep

        var title: String {
            switch self {
            case .off: return "Off"
            case .soft: return "Soft"
            case .deep: return "Deep"
            }
        }
        /// The blur level the ceiling reaches (an index into `BackgroundPipeline.levelRadii`).
        var level: Int {
            switch self {
            case .off: return 0
            case .soft: return 3
            case .deep: return 4
            }
        }
    }

    enum Grain: String, Codable, CaseIterable {
        case off, fine, film

        var title: String {
            switch self {
            case .off: return "Off"
            case .fine: return "Fine"
            case .film: return "Film"
            }
        }
        var opacity: Float {
            switch self {
            case .off: return 0
            case .fine: return 0.035
            case .film: return 0.07
            }
        }
    }

    /// A colour as sRGB components, so the plist stays legible.
    struct Tint: Codable, Equatable {
        var red: Double
        var green: Double
        var blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(_ color: NSColor) {
            let c = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            red = Double(c.redComponent)
            green = Double(c.greenComponent)
            blue = Double(c.blueComponent)
        }

        var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    }

    var source: Source = .color
    var style: Style = .natural
    /// The colour Duotone and Colour Wash use; nil takes the picture's own dominant colour.
    var tint: Tint?
    var blur: Blur = .soft
    /// Sharp at 1:1, blurred when zoomed out (and dimmed, see `dim`); off, the blur and the dim are constant.
    var focusFollowsZoom = true
    /// How dark the picture gets at the zoomed-out end, 0–0.4.
    var dim: Double = 0.2
    /// The picture drifts a little as you pan, as though it sat a way behind the windows.
    var depth = false
    var grain: Grain = .off
    var vignette = false
    /// A gradient that drifts slowly; nothing for other sources.
    var living = false

    static let `default` = BackgroundSpec()

    /// The zoom where the focus curve starts to blur (at or above: sharp) and where it reaches the ceiling.
    static let focusSharpZoom: CGFloat = 0.9
    static let focusFullZoom: CGFloat = 0.5

    /// 0 at 1:1, 1 fully zoomed out; a smoothstep between, so nothing kinks mid-pinch.
    static func focus(forZoom zoom: CGFloat) -> CGFloat {
        let t = (focusSharpZoom - zoom) / (focusSharpZoom - focusFullZoom)
        let c = min(1, max(0, t))
        return c * c * (3 - 2 * c)
    }

    /// Where along the blur levels the picture sits at this zoom: a fractional index into
    /// `BackgroundPipeline.levelRadii`, between 0 (sharp) and the ceiling's level.
    func blurPosition(forZoom zoom: CGFloat) -> CGFloat {
        let ceiling = CGFloat(blur.level)
        guard ceiling > 0 else { return 0 }
        return focusFollowsZoom ? BackgroundSpec.focus(forZoom: zoom) * ceiling : ceiling
    }

    /// How dark the picture is at this zoom, 0–1.
    func dimAmount(forZoom zoom: CGFloat) -> CGFloat {
        let d = CGFloat(min(0.4, max(0, dim)))
        return focusFollowsZoom ? BackgroundSpec.focus(forZoom: zoom) * d : d
    }
}

extension BackgroundSpec {
    /// Whether anything but a plain colour is behind the windows.
    var isPlainColor: Bool { source == .color }
}

// MARK: Persistence

@MainActor
extension Settings {
    private static let backgroundSpecKey = "CanvasBackgroundSpec"

    /// Whether the dark canvas colour (and the dark picture) is the one for this appearance, under the
    /// Appearance setting: the Mac's, or one of the two regardless.
    static func usesDark(for appearance: NSAppearance) -> Bool {
        switch self.appearance {
        case .light: return false
        case .dark: return true
        case .system: return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    /// The canvas colour for an appearance.
    static func canvasColor(dark: Bool) -> NSColor { dark ? darkBackground : lightBackground }

    /// How the "Remember the background" box in Save Layout was last left.
    static var rememberBackgroundInLayouts: Bool {
        get { UserDefaults.standard.bool(forKey: "CanvasLayoutsRememberBackground") }
        set { UserDefaults.standard.set(newValue, forKey: "CanvasLayoutsRememberBackground") }
    }

    /// The background, or the default for this Mac: a fresh install gets the Mac's wallpaper, a canvas that
    /// was already in use keeps its colour (the wallpaper is one click away).
    static var backgroundSpec: BackgroundSpec {
        get {
            if let plist = UserDefaults.standard.object(forKey: backgroundSpecKey),
               let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0),
               let spec = try? PropertyListDecoder().decode(BackgroundSpec.self, from: data) {
                return spec
            }
            var spec = BackgroundSpec.default
            spec.source = LayoutStore.remembered == nil ? .macWallpaper : .color
            return spec
        }
        set {
            guard let data = try? PropertyListEncoder().encode(newValue),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return }
            UserDefaults.standard.set(plist, forKey: backgroundSpecKey)
        }
    }
}
