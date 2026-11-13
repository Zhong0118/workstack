import AppKit
import Carbon
import SwiftUI
import WorkbenchCore

/// Receives keyDown only while explicitly recording in the settings window.
struct ShortcutRecorder: NSViewRepresentable {
    let chord: KeyChord?
    let save: (KeyChord) -> Void
    func makeNSView(context: Context) -> RecordingButton { RecordingButton() }
    func updateNSView(_ b: RecordingButton, context: Context) {
        b.chord = chord
        b.save = save
        if !b.recording { b.refreshTitle() }
    }
}

final class RecordingButton: NSButton {
    var chord: KeyChord?
    var save: ((KeyChord) -> Void)?
    var recording = false
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero)
        target = self
        action = #selector(begin)
        bezelStyle = .rounded
        setAccessibilityLabel(tr("Record shortcut"))
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func begin() {
        recording = window?.makeFirstResponder(self) == true
        title = tr("Press shortcut")
    }
    override func resignFirstResponder() -> Bool { recording = false; refreshTitle(); return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording && event.type == .keyDown { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode != 53 {
            let flags = event.modifierFlags
            var mods: UInt32 = 0
            if flags.contains(.control) { mods |= UInt32(controlKey) }
            if flags.contains(.option) { mods |= UInt32(optionKey) }
            if flags.contains(.command) { mods |= UInt32(cmdKey) }
            if flags.contains(.shift) { mods |= UInt32(shiftKey) }
            save?(KeyChord(key: UInt32(event.keyCode), modifiers: mods))
        }
        recording = false
        refreshTitle()
    }
    func refreshTitle() {
        guard let chord else { title = tr("Record shortcut"); return }
        let names = [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
        let mods = names.filter { chord.modifiers & $0.0 != 0 }.map(\.1).joined()
        title = mods + " " + keyName(chord.key)
    }
    private func keyName(_ key: UInt32) -> String {
        switch key {
        case 49: return tr("Space")
        case 48: return "⇥"
        case 36: return "↩"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: break
        }
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        if let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)!).assumingMemoryBound(to: UCKeyboardLayout.self)
            var dead: UInt32 = 0, length = 0, chars = [UniChar](repeating: 0, count: 8)
            if UCKeyTranslate(
                layout, UInt16(key), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &dead, 8, &length, &chars) == noErr, length > 0
            {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
        }
        return "#\(key)"
    }
}
