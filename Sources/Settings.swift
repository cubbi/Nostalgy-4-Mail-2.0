import Carbon
import Cocoa
import ServiceManagement

// MARK: - Model

enum Action: String, CaseIterable {
    case move, copy, go, moveToLast

    var title: String {
        switch self {
        case .move: return "Move to Folder…"
        case .copy: return "Copy to Folder…"
        case .go: return "Go to Folder…"
        case .moveToLast: return "Move to Last Folder"
        }
    }
}

struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int   // Carbon modifier mask (controlKey, optionKey, shiftKey, cmdKey)
    var key: String      // printable key name, e.g. "S"

    var display: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + key
    }
}

final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("Nostalgy4MailSettingsDidChange")
    private let defaults = UserDefaults.standard

    static let defaultShortcuts: [Action: Shortcut] = [
        .move: Shortcut(keyCode: kVK_ANSI_S, modifiers: controlKey, key: "S"),
        .copy: Shortcut(keyCode: kVK_ANSI_C, modifiers: controlKey, key: "C"),
        .go: Shortcut(keyCode: kVK_ANSI_G, modifiers: controlKey, key: "G"),
        .moveToLast: Shortcut(keyCode: kVK_ANSI_S, modifiers: controlKey | shiftKey, key: "S"),
    ]

    // Shortcuts. A stored empty value means "no shortcut".
    func shortcut(for action: Action) -> Shortcut? {
        guard let data = defaults.data(forKey: "shortcut." + action.rawValue) else {
            return Settings.defaultShortcuts[action]
        }
        return data.isEmpty ? nil : try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    func setShortcut(_ s: Shortcut?, for action: Action) {
        let data = s.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: "shortcut." + action.rawValue)
        changed()
    }

    /// Comma-separated; a folder whose path contains any entry is left out of the picker.
    var hiddenFolders: String {
        get { defaults.string(forKey: "hiddenFolders") ?? "" }
        set { defaults.set(newValue, forKey: "hiddenFolders"); changed() }
    }

    /// Minutes between automatic folder refreshes while Mail is in front; 0 = manual only.
    var refreshMinutes: Int {
        get { defaults.object(forKey: "refreshMinutes") as? Int ?? 10 }
        set { defaults.set(newValue, forKey: "refreshMinutes"); changed() }
    }

    /// How many recently used folders float to the top of the picker.
    var recentCount: Int {
        get { defaults.object(forKey: "recentCount") as? Int ?? 10 }
        set { defaults.set(newValue, forKey: "recentCount"); changed() }
    }

    func isHidden(_ m: Mailbox) -> Bool {
        let path = m.display.lowercased()
        return hiddenFolders
            .split(separator: ",")
            .map {
                $0.split(separator: "/")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .joined(separator: " / ")
            }
            .contains { !$0.isEmpty && path.contains($0) }
    }

    func reset() {
        for a in Action.allCases { defaults.removeObject(forKey: "shortcut." + a.rawValue) }
        for k in ["hiddenFolders", "refreshMinutes", "recentCount"] { defaults.removeObject(forKey: k) }
        changed()
    }

    private func changed() { NotificationCenter.default.post(name: Settings.didChange, object: nil) }
}

// MARK: - Shortcut recorder control

final class ShortcutRecorder: NSButton {
    var onChange: ((Shortcut?) -> Void)?
    private(set) var shortcut: Shortcut?
    private var monitor: Any?

    init(shortcut: Shortcut?) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func updateTitle() {
        title = monitor != nil ? "Press keys…" : (shortcut?.display ?? "None")
    }

    @objc private func toggleRecording() {
        if monitor != nil { cancel(); return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
        updateTitle()
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        updateTitle()
    }

    private func handle(_ e: NSEvent) {
        let code = Int(e.keyCode)
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = flags.subtracting([.capsLock, .function, .numericPad]).isEmpty

        if code == kVK_Escape && plain { cancel(); return }
        if (code == kVK_Delete || code == kVK_ForwardDelete) && plain {
            set(nil)
            return
        }

        var mods = 0
        if flags.contains(.control) { mods |= controlKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.shift) { mods |= shiftKey }
        if flags.contains(.command) { mods |= cmdKey }
        guard mods & (controlKey | optionKey | cmdKey) != 0 else {
            NSSound.beep() // require ⌃, ⌥ or ⌘ so plain typing in Mail isn't hijacked
            return
        }
        set(Shortcut(keyCode: code, modifiers: mods, key: ShortcutRecorder.keyName(code, e)))
    }

    private func set(_ s: Shortcut?) {
        shortcut = s
        cancel()
        onChange?(s)
    }

    private static func keyName(_ code: Int, _ e: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[code] { return name }
        let chars = e.charactersIgnoringModifiers?.uppercased() ?? ""
        return chars.isEmpty ? "Key \(code)" : chars
    }
}

// MARK: - Settings window

final class SettingsWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private var window: NSWindow?
    private var recorders: [ShortcutRecorder] = []
    private var hiddenField: NSTextField?
    private let refreshOptions: [(Int, String)] = [
        (5, "Every 5 minutes"), (10, "Every 10 minutes"), (30, "Every 30 minutes"),
        (60, "Every hour"), (0, "Only when I choose Refresh"),
    ]
    private let recentOptions = [0, 5, 10, 20]

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let s = Settings.shared
        let empty = NSGridCell.emptyContentView
        var rows: [[NSView]] = []

        for a in Action.allCases {
            let r = ShortcutRecorder(shortcut: s.shortcut(for: a))
            r.onChange = { Settings.shared.setShortcut($0, for: a) }
            recorders.append(r)
            rows.append([label(a.title), r])
        }
        rows.append([empty, note("Shortcuts work only while Mail is in front. Click one, then press the new keys. Delete clears it, Esc cancels.")])

        let hidden = NSTextField(string: s.hiddenFolders)
        hidden.placeholderString = "e.g. Trash, Junk, Archive/2019"
        hidden.delegate = self
        hidden.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        hiddenField = hidden
        rows.append([label("Hide folders:"), hidden])
        rows.append([empty, note("Separate with commas. Any folder whose path contains one of these is left out of the picker.")])

        let refresh = NSPopUpButton()
        refresh.addItems(withTitles: refreshOptions.map(\.1))
        refresh.selectItem(at: refreshOptions.firstIndex { $0.0 == s.refreshMinutes } ?? 1)
        refresh.target = self
        refresh.action = #selector(refreshChanged(_:))
        rows.append([label("Refresh folders:"), refresh])

        let recent = NSPopUpButton()
        recent.addItems(withTitles: recentOptions.map { $0 == 0 ? "Off" : "\($0) folders" })
        recent.selectItem(at: recentOptions.firstIndex(of: s.recentCount) ?? 2)
        recent.target = self
        recent.action = #selector(recentChanged(_:))
        rows.append([label("Recent folders first:"), recent])

        if #available(macOS 13, *) {
            let login = NSButton(checkboxWithTitle: "Open Nostalgy-4-Mail at login", target: self, action: #selector(loginChanged(_:)))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            rows.append([empty, login])
        }

        rows.append([empty, NSButton(title: "Reset to Defaults", target: self, action: #selector(resetDefaults))])

        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Nostalgy-4-Mail Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = content
        window = w
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func note(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 300
        return l
    }

    // MARK: Actions

    func controlTextDidChange(_ obj: Notification) {
        if let f = hiddenField { Settings.shared.hiddenFolders = f.stringValue }
    }

    @objc private func refreshChanged(_ sender: NSPopUpButton) {
        Settings.shared.refreshMinutes = refreshOptions[sender.indexOfSelectedItem].0
    }

    @objc private func recentChanged(_ sender: NSPopUpButton) {
        Settings.shared.recentCount = recentOptions[sender.indexOfSelectedItem]
    }

    @objc private func loginChanged(_ sender: NSButton) {
        guard #available(macOS 13, *) else { return }
        do {
            if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            let alert = NSAlert(error: error)
            alert.informativeText = "Move Nostalgy-4-Mail to /Applications and try again, or add it in System Settings › General › Login Items."
            alert.runModal()
        }
    }

    @objc private func resetDefaults() {
        Settings.shared.reset()
        window?.orderOut(nil)
        recorders.forEach { $0.cancel() }
        recorders.removeAll()
        window = nil
        show()
    }

    func windowWillClose(_ notification: Notification) {
        recorders.forEach { $0.cancel() }
    }
}
