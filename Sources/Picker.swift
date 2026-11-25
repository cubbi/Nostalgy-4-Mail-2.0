import Cocoa

private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Always draws the selection in the accent colour, like Mail's selected message.
/// The text field keeps keyboard focus, so a plain row would draw the grey, unfocused selection.
private final class PickerRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

/// The Nostalgy-style "type part of a folder name" popup.
final class Picker: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let panel: PickerPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let field = NSSearchField() // looks like Mail's search box
    private let table = NSTableView()

    private var all: [Mailbox] = []
    private var recent: [Mailbox] = []
    private var shown: [Mailbox] = []
    private var completion: ((Mailbox?) -> Void)?
    private var escMonitor: Any?
    private var loading = false

    private let refreshSpinner = NSProgressIndicator()
    private let refreshLabel = NSTextField(labelWithString: "Updating folders…")
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "Loading folders from Mail…")

    var isOpen: Bool { completion != nil }

    private static let listInset: CGFloat = 6  // scroll view margin, plus the inset style's own
    private static let textInset: CGFloat = 0  // text inside a row

    override init() {
        panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 380),
                            styleMask: [.titled, .fullSizeContentView],
                            backing: .buffered, defer: true)
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(b)?.isHidden = true
        }

        titleLabel.font = .boldSystemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor

        field.placeholderString = "Search folders"
        field.controlSize = .large
        field.font = .systemFont(ofSize: 15)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = self
        field.target = self
        field.action = #selector(searchChanged) // also fires when the clear (x) button is clicked

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.style = .inset // rounded selection with side margins, like Mail's lists
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(chooseSelected)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)

        // Small spinner in the title row while folders refresh in the background.
        refreshSpinner.style = .spinning
        refreshSpinner.controlSize = .small
        refreshSpinner.isDisplayedWhenStopped = false
        refreshLabel.font = .systemFont(ofSize: 11)
        refreshLabel.textColor = .tertiaryLabelColor
        refreshLabel.isHidden = true

        // Large spinner and message over the list while it is empty and loading.
        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.isDisplayedWhenStopped = false
        loadingLabel.font = .systemFont(ofSize: 13)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.alignment = .center
        loadingLabel.isHidden = true

        let content = NSView()
        panel.contentView = content
        for v in [titleLabel, refreshLabel, refreshSpinner, field, scroll, loadingSpinner, loadingLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: refreshLabel.leadingAnchor, constant: -8),
            refreshSpinner.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            refreshSpinner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            refreshLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            refreshLabel.trailingAnchor.constraint(equalTo: refreshSpinner.leadingAnchor, constant: -6),
            loadingSpinner.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -14),
            loadingLabel.topAnchor.constraint(equalTo: loadingSpinner.bottomAnchor, constant: 10),
            loadingLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            field.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            // The inset table style adds its own side margin; together they line rows up with the field.
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Picker.listInset),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Picker.listInset),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    /// `loading`: folders are being read from Mail; `update(items:loading:)` delivers them.
    /// `around`: centre the picker on this rectangle (Mail's window); nil centres it on the screen.
    func show(title: String, items: [Mailbox], recent: [Mailbox], loading: Bool, around: NSRect? = nil,
              completion: @escaping (Mailbox?) -> Void) {
        finish(nil) // close any picker that is already open
        self.all = items
        self.recent = recent
        self.completion = completion
        titleLabel.stringValue = title
        field.stringValue = ""
        setLoading(loading)
        filter()

        // Esc closes the picker whatever has focus (the text field or the list).
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.window === self.panel else { return event } // 53 = Esc
            self.finish(nil)
            return nil
        }

        NSApp.activate(ignoringOtherApps: true)
        position(around: around)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func position(around rect: NSRect?) {
        guard let rect,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main
        else { panel.center(); return }
        let size = panel.frame.size
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        // Keep the whole picker on the screen, even if Mail's window is partly off it.
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(origin)
    }

    private func finish(_ choice: Mailbox?) {
        guard let done = completion else { return }
        completion = nil
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        panel.orderOut(nil)
        done(choice)
    }

    /// Replaces the folder list of an open picker, keeping what was typed and the highlighted folder.
    func update(items: [Mailbox], loading: Bool) {
        guard isOpen else { return }
        all = items
        setLoading(loading)
        filter(keepSelection: true)
    }

    private func setLoading(_ on: Bool) {
        loading = on
        updateLoadingViews()
    }

    private func updateLoadingViews() {
        let empty = loading && all.isEmpty
        if empty { loadingSpinner.startAnimation(nil) } else { loadingSpinner.stopAnimation(nil) }
        loadingLabel.isHidden = !empty
        let background = loading && !all.isEmpty
        if background { refreshSpinner.startAnimation(nil) } else { refreshSpinner.stopAnimation(nil) }
        refreshLabel.isHidden = !background
    }

    // MARK: - Filtering

    private func filter(keepSelection: Bool = false) {
        let previous = keepSelection && shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : nil
        let tokens = field.stringValue.lowercased().split(separator: " ").map(String.init)
        var rank: [Mailbox: Int] = [:]
        for (i, m) in recent.enumerated() where rank[m] == nil { rank[m] = i }

        var scored: [(Mailbox, Int)] = []
        for m in all {
            let full = m.display.lowercased()
            let leaf = m.leaf.lowercased()
            var score = 0
            var matches = true
            for t in tokens {
                if leaf.hasPrefix(t) { score += 30 }
                else if leaf.contains(t) { score += 20 }
                else if full.contains(t) { score += 5 }
                else { matches = false; break }
            }
            guard matches else { continue }
            if let r = rank[m] { score += max(0, 50 - r * 5) }
            score -= full.count / 10
            scored.append((m, score))
        }
        scored.sort {
            $0.1 != $1.1 ? $0.1 > $1.1
                : $0.0.display.localizedStandardCompare($1.0.display) == .orderedAscending
        }
        shown = scored.map(\.0)
        table.reloadData()
        if !shown.isEmpty {
            let row = previous.flatMap { shown.firstIndex(of: $0) } ?? 0
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), shown.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func chooseSelected() {
        let row = table.selectedRow
        guard shown.indices.contains(row) else { NSSound.beep(); return }
        finish(shown[row])
    }

    // MARK: - Delegates

    func controlTextDidChange(_ obj: Notification) { filter() }

    @objc private func searchChanged() { filter(keepSelection: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)): moveSelection(1)
        case #selector(NSResponder.insertBacktab(_:)): moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)): chooseSelected()
        case #selector(NSResponder.cancelOperation(_:)): finish(nil)
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) { finish(nil) }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        if let view = tableView.makeView(withIdentifier: id, owner: nil) as? PickerRowView { return view }
        let view = PickerRowView()
        view.identifier = id
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let l = NSTextField(labelWithString: "")
            l.font = .systemFont(ofSize: 13)
            l.lineBreakMode = .byTruncatingHead
            l.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(l)
            c.textField = l
            NSLayoutConstraint.activate([
                l.centerYAnchor.constraint(equalTo: c.centerYAnchor), // text in the middle of the row
                l.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: Picker.textInset),
                l.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -Picker.textInset),
            ])
            return c
        }()
        cell.textField?.stringValue = shown[row].display
        return cell
    }
}
