//
//  HotKey.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit
import Carbon.HIToolbox

/// A key plus modifiers, in Carbon terms so it can be registered directly.
struct Shortcut: Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var modifiers: UInt32

    /// ⌥⌘P, as in the design.
    static let openPlayerDefault = Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// From a key press, or nil if it can't stand alone as a global shortcut:
    /// it needs ⌘, ⌥ or ⌃, unless it is a function key.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        let code = UInt32(event.keyCode)
        let anchored = carbon & UInt32(cmdKey | optionKey | controlKey) != 0
        guard anchored || Self.functionKeys[code] != nil else { return nil }
        self.init(keyCode: code, modifiers: carbon)
    }

    /// As macOS menus show it, e.g. "⌥⌘P".
    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    private static let functionKeys: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
    ]

    private static let namedKeys: [UInt32: String] = [
        UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Escape): "⎋",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘", UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
    ]

    /// The key's label on the current keyboard layout, so a shortcut recorded
    /// on a Turkish or German layout reads the way the key is printed.
    private static func keyName(_ code: UInt32) -> String {
        if let name = functionKeys[code] ?? namedKeys[code] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// One system-wide hotkey, registered through Carbon. Unlike a key event
/// monitor this needs no Accessibility permission and works whichever app
/// is frontmost.
final class GlobalHotKey {
    private let action: () -> Void
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var registered: Shortcut?

    /// Carbon calls back through a C function, so the live instance is kept
    /// here for it to find. Tuno has a single hotkey.
    private static weak var current: GlobalHotKey?
    private static let signature: OSType = 0x54_55_4E_4F // "TUNO"

    init(action: @escaping () -> Void) {
        self.action = action
        Self.current = self
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.current?.action() }
            return noErr
        }, 1, &pressed, nil, &handler)
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }

    /// Registers `shortcut` in place of any previous one; nil just clears it.
    /// Returns false when macOS refuses, usually because another app owns
    /// the same combination.
    @discardableResult
    func register(_ shortcut: Shortcut?) -> Bool {
        unregister()
        guard let shortcut else { return true }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else {
            reference = nil
            return false
        }
        registered = shortcut
        return true
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        registered = nil
    }
}
