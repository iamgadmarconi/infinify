import AppKit

/// The background's menu (right-click on empty canvas › Background): the quick way to the few things
/// people change often; everything else is in Settings › Background, which Customise… opens.
@MainActor
final class BackgroundMenu: NSObject {
    private unowned let model: BackgroundModel

    init(model: BackgroundModel) {
        self.model = model
    }

    func build() -> NSMenu {
        let menu = NSMenu(title: "Background")
        let spec = model.spec
        add(menu, "Choose Picture…", #selector(choosePicture))
        add(menu, "Use the Mac's Wallpaper", #selector(useWallpaper), on: spec.source == .macWallpaper)
        add(menu, "Colour", #selector(useColor), on: spec.isPlainColor)
        let gradients = NSMenu(title: "Gradient")
        for g in Gradients.all {
            let item = add(gradients, g.name, #selector(useGradient(_:)), on: spec.source == .gradient(g.id))
            item.representedObject = g.id
        }
        let gradientItem = NSMenuItem(title: "Gradient", action: nil, keyEquivalent: "")
        gradientItem.submenu = gradients
        menu.addItem(gradientItem)
        menu.addItem(.separator())
        for style in BackgroundSpec.Style.allCases {
            let item = add(menu, style.title, #selector(setStyle(_:)), on: spec.style == style)
            item.representedObject = style.rawValue
            item.isEnabled = !spec.isPlainColor
        }
        menu.addItem(.separator())
        let blur = NSMenu(title: "Blur")
        for level in BackgroundSpec.Blur.allCases {
            let item = add(blur, level.title, #selector(setBlur(_:)), on: spec.blur == level)
            item.representedObject = level.rawValue
        }
        let blurItem = NSMenuItem(title: "Blur", action: nil, keyEquivalent: "")
        blurItem.submenu = blur
        blurItem.isEnabled = spec.source.isPicture
        menu.addItem(blurItem)
        menu.addItem(.separator())
        add(menu, "Customise…", #selector(customise))
        menu.autoenablesItems = false
        return menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, on: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        menu.addItem(item)
        return item
    }

    @objc private func choosePicture() { model.chooseFile(from: nil) }
    @objc private func useWallpaper() { model.useMacWallpaper() }
    @objc private func useColor() { model.useColor() }
    @objc private func customise() { model.onCustomise?() }

    @objc private func useGradient(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.useGradient(id)
    }

    @objc private func setStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = BackgroundSpec.Style(rawValue: raw) else { return }
        model.setStyle(style)
    }

    @objc private func setBlur(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let blur = BackgroundSpec.Blur(rawValue: raw) else { return }
        model.setBlur(blur)
    }
}

extension BackgroundModel {
    /// Right-click on empty canvas › Background.
    func menu() -> NSMenu { menuBuilder.build() }
}
