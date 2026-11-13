import AppKit
import Carbon
import WorkbenchCore

enum ShortcutAction: UInt32, CaseIterable, Identifiable {
    case switcher = 1, nextTab, previousTab, undo
    var id: UInt32 { rawValue }
    var name: String {
        switch self {
        case .switcher: "Quick Switcher"
        case .nextTab: "Next tab"
        case .previousTab: "Previous tab"
        case .undo: "Undo workspace change"
        }
    }
    var defaults: KeyChord {
        switch self {
        case .switcher: KeyChord(key: 49, modifiers: 6144)
        case .nextTab: KeyChord(key: 30, modifiers: 6144)
        case .previousTab: KeyChord(key: 33, modifiers: 6144)
        case .undo: KeyChord(key: 6, modifiers: 6400)
        }
    }
    func binding(_ prefs: Preferences) -> KeyChord? {
        if self == .switcher { return KeyChord(key: prefs.shortcutKey, modifiers: prefs.shortcutModifiers) }
        return prefs.additionalShortcuts?[String(rawValue)]
    }
}

@MainActor
final class GlobalShortcut {
    private let action: @MainActor (ShortcutAction) -> Void
    private var handler: EventHandlerRef?
    private var registrations: [ShortcutAction: EventHotKeyRef] = [:]
    init(action: @escaping @MainActor (ShortcutAction) -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var key = EventHotKeyID()
                guard
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                        nil, MemoryLayout.size(ofValue: key), nil, &key) == noErr,
                    key.signature == 0x5757424b, let action = ShortcutAction(rawValue: key.id)
                else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated { Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().action(action) }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func configure(_ prefs: Preferences) -> Bool {
        for item in registrations.values { UnregisterEventHotKey(item) }
        registrations.removeAll()
        guard prefs.shortcutsEnabled else { return true }
        var success = true
        for action in ShortcutAction.allCases {
            guard let chord = action.binding(prefs) else { continue }
            guard chord.isValid else { success = false; continue }
            var item: EventHotKeyRef?
            let status = RegisterEventHotKey(
                chord.key, chord.modifiers, EventHotKeyID(signature: 0x5757424b, id: action.rawValue),
                GetApplicationEventTarget(), 0, &item)
            if status == noErr, let item { registrations[action] = item } else { success = false }
        }
        return success
    }
    func stop() {
        for item in registrations.values { UnregisterEventHotKey(item) }
        registrations.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
