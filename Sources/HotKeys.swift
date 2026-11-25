import Carbon

/// Global hotkeys via Carbon's RegisterEventHotKey (needs no Accessibility permission).
/// The app registers them only while Mail is the frontmost app, so other apps keep their shortcuts.
final class HotKeys {
    struct Key {
        let keyCode: Int      // e.g. kVK_ANSI_S
        let modifiers: Int    // e.g. controlKey | shiftKey
        let action: () -> Void
    }

    private static var shared: HotKeys?
    private var keys: [Key] = []
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private(set) var isActive = false

    init() {
        HotKeys.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            HotKeys.shared?.fire(Int(id.id))
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Replace the set of hotkeys, keeping the current registered/unregistered state.
    func update(_ newKeys: [Key]) {
        let wasActive = isActive
        unregister()
        keys = newKeys
        if wasActive { register() }
    }

    private func fire(_ index: Int) {
        guard keys.indices.contains(index) else { return }
        let action = keys[index].action
        DispatchQueue.main.async { action() }
    }

    func register() {
        guard !isActive else { return }
        isActive = true
        for (i, k) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4E34_4D4C), id: UInt32(i)) // 'N4ML'
            if RegisterEventHotKey(UInt32(k.keyCode), UInt32(k.modifiers), id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                refs.append(ref)
            }
        }
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        isActive = false
    }
}
