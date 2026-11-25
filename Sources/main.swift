import Cocoa

private struct RecentMailboxes {
    private static let key = "recentMailboxes"
    private(set) var items: [Mailbox] =
        (UserDefaults.standard.stringArray(forKey: RecentMailboxes.key) ?? []).compactMap(Mailbox.init(encoded:))

    mutating func use(_ m: Mailbox) {
        items.removeAll { $0 == m }
        items.insert(m, at: 0)
        items = Array(items.prefix(20))
        UserDefaults.standard.set(items.map(\.encoded), forKey: RecentMailboxes.key)
    }
}

/// The last folder list read from Mail, kept so the picker is ready right after launch.
private enum MailboxCache {
    private static let key = "mailboxCache"

    static func load() -> [Mailbox] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(Mailbox.init(encoded:))
    }

    static func save(_ list: [Mailbox]) {
        UserDefaults.standard.set(list.map(\.encoded), forKey: key)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mailID = "com.apple.mail"
    private var statusItem: NSStatusItem!
    private let hotKeys = HotKeys()
    private let picker = Picker()
    private let settingsWindow = SettingsWindow()
    private var mailboxes: [Mailbox] = MailboxCache.load()
    private var lastRefresh = Date.distantPast // the cache may be stale, so refresh soon after launch
    private var isRefreshing = false
    private var reportRefreshError = false
    private var recent = RecentMailboxes()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Nostalgy-4-Mail")

        applySettings()
        NotificationCenter.default.addObserver(self, selector: #selector(applySettings),
                                               name: Settings.didChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        updateHotKeys(for: NSWorkspace.shared.frontmostApplication)
        // Refresh in the background if Mail is already open (never launch Mail just for this).
        if !NSRunningApplication.runningApplications(withBundleIdentifier: mailID).isEmpty { refresh() }
    }

    // MARK: - Settings → hotkeys and menu

    @objc private func applySettings() {
        let settings = Settings.shared
        hotKeys.update(Action.allCases.compactMap { action in
            guard let s = settings.shortcut(for: action) else { return nil }
            return HotKeys.Key(keyCode: s.keyCode, modifiers: s.modifiers) { [weak self] in self?.perform(action) }
        })
        buildMenu()
        if picker.isOpen { picker.update(items: visibleMailboxes(), loading: isRefreshing) }
    }

    private func buildMenu() {
        let settings = Settings.shared
        let menu = NSMenu()
        for action in Action.allCases {
            let keys = settings.shortcut(for: action).map { "   " + $0.display } ?? ""
            let item = NSMenuItem(title: action.title + keys, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let count = mailboxes.isEmpty ? "" : " (\(mailboxes.count))"
        let refreshItem = isRefreshing
            ? NSMenuItem(title: "Refreshing Folders…", action: nil, keyEquivalent: "")
            : NSMenuItem(title: "Refresh Folders" + count, action: #selector(refreshFromMenu), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Nostalgy-4-Mail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openSettings() { settingsWindow.show() }

    @objc private func menuAction(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let action = Action(rawValue: raw) { perform(action) }
    }

    // MARK: - Hotkeys follow Mail

    @objc private func appActivated(_ n: Notification) {
        updateHotKeys(for: n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    private func updateHotKeys(for app: NSRunningApplication?) {
        guard app?.bundleIdentifier == mailID else { hotKeys.unregister(); return }
        hotKeys.register()
        let minutes = Settings.shared.refreshMinutes
        if minutes > 0, Date().timeIntervalSince(lastRefresh) > Double(minutes * 60) {
            refresh()
        }
    }

    /// Frame of Mail's frontmost window in screen coordinates, or nil if it has none on screen.
    /// Window positions from CGWindowList need no extra permission (only window titles would).
    private func mailWindowFrame() -> NSRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: mailID).first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        // The list runs front to back; take Mail's first normal window of a sensible size.
        for w in windows where (w[kCGWindowOwnerPID as String] as? pid_t) == pid
            && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let dict = w[kCGWindowBounds as String] as CFTypeRef?,
                  let bounds = CGRect(dictionaryRepresentation: dict as! CFDictionary),
                  bounds.width > 200, bounds.height > 150 else { continue }
            // CoreGraphics measures from the top of the main screen; Cocoa from the bottom.
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            return NSRect(x: bounds.minX, y: mainHeight - bounds.maxY, width: bounds.width, height: bounds.height)
        }
        return nil
    }

    private func activateMail() {
        // activate(options:) rather than activate(), which needs macOS 14.
        NSRunningApplication.runningApplications(withBundleIdentifier: mailID).first?.activate(options: [])
    }

    // MARK: - Actions

    @objc private func refreshFromMenu() { refresh(reportErrors: true) }

    /// Re-reads the folder list from Mail in the background. Only one refresh runs at a time.
    /// Errors are shown only if asked for, or if there is nothing to show in an open picker.
    private func refresh(reportErrors: Bool = false) {
        if reportErrors { reportRefreshError = true }
        guard !isRefreshing else { return }
        isRefreshing = true
        buildMenu()
        if picker.isOpen { picker.update(items: visibleMailboxes(), loading: true) }

        MailBridge.listMailboxes { [weak self] result in
            guard let self else { return }
            self.isRefreshing = false
            let wantsError = self.reportRefreshError || (self.picker.isOpen && self.mailboxes.isEmpty)
            self.reportRefreshError = false
            switch result {
            case .success(let list):
                self.mailboxes = list
                self.lastRefresh = Date()
                MailboxCache.save(list)
            case .failure(let error):
                NSLog("Nostalgy-4-Mail: could not read folders: \(error)")
                if wantsError { self.report(error) }
            }
            self.buildMenu() // updates the folder count
            if self.picker.isOpen { self.picker.update(items: self.visibleMailboxes(), loading: false) }
        }
    }

    private func visibleMailboxes() -> [Mailbox] {
        let settings = Settings.shared
        return mailboxes.filter { !settings.isHidden($0) }
    }

    private func perform(_ action: Action) {
        switch action {
        case .move: pick("Move to folder", then: MailBridge.move(to:))
        case .copy: pick("Copy to folder", then: MailBridge.copy(to:))
        case .go: pick("Go to folder", then: MailBridge.go(to:))
        case .moveToLast:
            guard let last = recent.items.first else { perform(.move); return }
            do { try MailBridge.move(to: last) } catch { report(error) }
        }
    }

    private func pick(_ title: String, then action: @escaping (Mailbox) throws -> Void) {
        if mailboxes.isEmpty { refresh() } // the picker shows a loading indicator until it finishes
        let visible = visibleMailboxes()
        guard !visible.isEmpty || isRefreshing else { NSSound.beep(); return }
        let recentFirst = Array(recent.items.prefix(Settings.shared.recentCount))

        picker.show(title: title, items: visible, recent: recentFirst, loading: isRefreshing,
                    around: mailWindowFrame()) { [weak self] choice in
            guard let self else { return }
            self.activateMail()
            guard let choice else { return }
            DispatchQueue.main.async {
                do {
                    try action(choice)
                    self.recent.use(choice)
                } catch {
                    self.report(error)
                }
            }
        }
    }

    private func report(_ error: Error) {
        if let e = error as? MailError, e.number == MailError.noSelection {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Nostalgy-4-Mail couldn't do that"
        if let e = error as? MailError, e.number == MailError.notAuthorized {
            alert.informativeText = "Allow Nostalgy-4-Mail to control Mail in System Settings › Privacy & Security › Automation."
        } else {
            alert.informativeText = "\(error)"
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        activateMail()
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
