//
//  Preferences.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import Foundation

/// User settings, stored in UserDefaults. Observers hear about every change
/// through `objectWillChange`.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    /// Players the settings name individually; anything else is `other`.
    enum Source: String, CaseIterable, Identifiable {
        case safari, chrome, music, spotify, podcasts, other

        var id: String { rawValue }
        var label: String {
            switch self {
            case .safari: return "Safari"
            case .chrome: return "Chrome"
            case .music: return "Music"
            case .spotify: return "Spotify"
            case .podcasts: return "Podcasts"
            case .other: return "Other apps"
            }
        }

        init(bundleIdentifier: String?) {
            switch bundleIdentifier {
            case "com.apple.Safari", "com.apple.SafariTechnologyPreview": self = .safari
            case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary": self = .chrome
            case "com.apple.Music": self = .music
            case "com.spotify.client": self = .spotify
            case "com.apple.podcasts": self = .podcasts
            default: self = .other
            }
        }
    }

    @Published var showWhenPaused: Bool { didSet { store(showWhenPaused, for: .showWhenPaused) } }
    @Published var sources: Set<Source> { didSet { store(sources.map(\.rawValue).sorted(), for: .sources) } }
    /// Global shortcut that opens the player; nil when the user cleared it.
    @Published var openPlayerShortcut: Shortcut? {
        didSet {
            // An empty array records "cleared", as opposed to "never set".
            store(openPlayerShortcut.map { [Int($0.keyCode), Int($0.modifiers)] } ?? [Int](), for: .openPlayerShortcut)
        }
    }

    // Not stored: state shared between the settings window and the hotkey.

    /// True while the settings window records a new shortcut, so the current
    /// one is released and its keys can be typed.
    @Published var isRecordingShortcut = false
    /// True when macOS refused the shortcut, usually because another app owns it.
    @Published var shortcutUnavailable = false

    private enum Key: String {
        case showWhenPaused, sources, openPlayerShortcut
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showWhenPaused = defaults.object(forKey: Key.showWhenPaused.rawValue) as? Bool ?? true
        sources = (defaults.stringArray(forKey: Key.sources.rawValue)).map { Set($0.compactMap(Source.init)) }
            ?? Set(Source.allCases)
        if let stored = defaults.array(forKey: Key.openPlayerShortcut.rawValue) as? [Int] {
            openPlayerShortcut = stored.count == 2 ? Shortcut(keyCode: UInt32(stored[0]), modifiers: UInt32(stored[1])) : nil
        } else {
            openPlayerShortcut = .openPlayerDefault
        }
    }

    /// Whether a session from this app should show in the notch.
    func allows(bundleIdentifier: String?) -> Bool {
        sources.contains(Source(bundleIdentifier: bundleIdentifier))
    }

    private func store(_ value: Any, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}
