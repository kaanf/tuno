//
//  MediaKeys.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit
import ApplicationServices

/// Playback control by posting the same events as the keyboard's media keys,
/// which macOS routes to whichever app owns the Now Playing session.
///
/// MediaRemote's own command API ignores third-party callers since macOS
/// 15.4, so this is the dependable route. It needs Accessibility permission.
enum MediaKeys {
    enum Key: Int32 {
        // NX_KEYTYPE_* in IOKit/hidsystem/ev_keymap.h
        case playPause = 16
        case next = 17
        case previous = 18
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt if permission hasn't been given.
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func press(_ key: Key) {
        guard requestTrust() else { return }
        post(key, down: true)
        post(key, down: false)
    }

    private static func post(_ key: Key, down: Bool) {
        // Aux control button events: subtype 8, key code in the high 16 bits
        // of data1, key state (0xA down, 0xB up) in the next byte.
        let state: Int32 = down ? 0xA : 0xB
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((key.rawValue << 16) | (state << 8)),
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
