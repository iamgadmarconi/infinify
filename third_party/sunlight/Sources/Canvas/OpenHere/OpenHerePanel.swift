import AppKit

/// Right-click › Open Here…: a Spotlight-style bar over the canvas to pick an app whose new window
/// opens at the clicked spot. Type to filter, ↑↓ to pick, ⏎ to open, ⌘⏎ to open and go into it, esc
/// (or a click elsewhere) to dismiss. The controller does the opening (`CanvasController.openHere`).
@MainActor
final class OpenHerePanel: NSPanel, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    /// The app picked; true to go into its window once it's on the canvas (⌘⏎).
    var onOpen: ((AppEntry, Bool) -> Void)?
    /// Gone, whether something was picked or not.
    var onDismiss: (() -> Void)?

    private static let width: CGFloat = 560
    private static let fieldHeight: CGFloat = 64
    private static let rowHeight: CGFloat = 44
    private static let maxRows = 8

    private let catalog: AppCatalog
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var results: [AppEntry] = []
    /// The bundle IDs of the apps running as the bar showed: their rows say so.
    private var running: Set<String> = []
    private weak var canvasWindow: NSWindow?
    private var dismissing = false

    override var canBecomeKey: Bool { true }

    init(catalog: AppCatalog) {
        self.catalog = catalog
        let size = NSSize(width: OpenHerePanel.width, height: OpenHerePanel.fieldHeight + OpenHerePanel.rowHeight + 16)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Over the live canvas, which the Dock add-on lifts above AppKit's levels (a child window of the
        // canvas, at its AppKit level, was drawn behind it): the tiling popover's level.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        appearance = NSAppearance(named: .darkAqua)
        delegate = self
        contentView = buildContent(size: size)
    }

    // MARK: Showing

    func show(over canvas: NSWindow) {
        canvasWindow = canvas
        // A walk of the app folders landed while the bar was up: show it, keeping the pick.
        catalog.onUpdate = { [weak self] in
            guard let self, self.isVisible else { return }
            self.refresh(keepingSelection: true)
        }
        catalog.refresh()   // in the background; the list already loaded shows meanwhile
        running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        field.stringValue = ""
        refresh()
        let p = canvas.frame
        setFrameTopLeftPoint(NSPoint(x: p.midX - frame.width / 2, y: p.maxY - p.height * 0.2))
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(field)
    }

    func dismiss() {
        guard isVisible, !dismissing else { return }
        dismissing = true
        orderOut(nil)
        canvasWindow?.makeKey()
        dismissing = false
        onDismiss?()
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    // MARK: Results

    private func refresh(keepingSelection: Bool = false) {
        let picked = keepingSelection && results.indices.contains(table.selectedRow) ? results[table.selectedRow] : nil
        results = catalog.search(field.stringValue)
        table.reloadData()
        resize()
        select(picked.flatMap { results.firstIndex(of: $0) } ?? 0)
    }

    private func resize() {
        let rows = CGFloat(max(1, min(results.count, OpenHerePanel.maxRows)))
        let height = OpenHerePanel.fieldHeight + rows * OpenHerePanel.rowHeight + 16
        var f = frame
        f.origin.y = f.maxY - height
        f.size.height = height
        setFrame(f, display: true)
    }

    private func select(_ row: Int) {
        guard results.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        select((max(0, table.selectedRow) + delta + results.count) % results.count)
    }

    private func openSelected(enter: Bool) {
        let row = table.selectedRow
        guard results.indices.contains(row) else { return NSSound.beep() }
        let app = results[row]
        dismiss()
        onOpen?(app, enter)
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0 else { return }
        select(table.clickedRow)
        openSelected(enter: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    /// ⌘⏎ comes as a key equivalent, before the field sees it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let returnKeys: Set<UInt16> = [36, 76]   // return, keypad enter
        if returnKeys.contains(event.keyCode),
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]) == .command {
            openSelected(enter: true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Text field

    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): openSelected(enter: false)
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { OpenHereRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("app")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id)
        let app = results[row]
        let text = NSMutableAttributedString(string: app.name, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
        ])
        if let id = Bundle(path: app.path)?.bundleIdentifier, running.contains(id) {
            text.append(NSAttributedString(string: "  Running", attributes: [
                .foregroundColor: NSColor(white: 1, alpha: 0.45),
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            ]))
        }
        cell.textField?.attributedStringValue = text
        cell.imageView?.image = catalog.icon(for: app)
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: OpenHerePanel.width, height: OpenHerePanel.rowHeight))
        cell.identifier = id
        let image = NSImageView(frame: NSRect(x: 16, y: 8, width: 28, height: 28))
        image.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 56, y: 11, width: OpenHerePanel.width - 80, height: 22)
        label.autoresizingMask = [.width]
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        cell.addSubview(image)
        cell.addSubview(label)
        cell.imageView = image
        cell.textField = label
        return cell
    }

    // MARK: Building

    private func buildContent(size: NSSize) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.98).cgColor
        root.layer?.cornerRadius = 14
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        root.autoresizesSubviews = true

        field.frame = NSRect(x: 20, y: size.height - 48, width: size.width - 40, height: 32)
        field.autoresizingMask = [.width, .minYMargin]
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(string: "Open an app here…", attributes: [
            .foregroundColor: NSColor(white: 1, alpha: 0.35),
            .font: NSFont.systemFont(ofSize: 22, weight: .regular),
        ])
        field.delegate = self
        root.addSubview(field)

        let rule = NSView(frame: NSRect(x: 0, y: size.height - OpenHerePanel.fieldHeight, width: size.width, height: 1))
        rule.autoresizingMask = [.width, .minYMargin]
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        root.addSubview(rule)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.width = size.width - 16
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = OpenHerePanel.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.refusesFirstResponder = true   // typing stays in the field
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        scroll.frame = NSRect(x: 8, y: 8, width: size.width - 16, height: size.height - OpenHerePanel.fieldHeight - 8)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = table
        root.addSubview(scroll)
        return root
    }
}

/// A soft rounded highlight instead of the stock accent bar.
final class OpenHereRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor(white: 1, alpha: 0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
}
