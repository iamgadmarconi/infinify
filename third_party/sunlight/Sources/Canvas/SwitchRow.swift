import AppKit

extension NSSwitch {
    /// An on/off option in an AppKit sheet or alert, as System Settings lays one out: its name at the
    /// left, the switch at the right, `width` wide when given. In place of a checkbox, so every on/off
    /// choice in the app is the same switch.
    static func row(_ title: String, _ toggle: NSSwitch, width: CGFloat? = nil) -> NSStackView {
        let label = NSTextField(wrappingLabelWithString: title)
        label.setAccessibilityElement(false)
        toggle.setAccessibilityLabel(title)
        let row = NSStackView(views: [label, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.distribution = .fill
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        if let width { row.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return row
    }
}
