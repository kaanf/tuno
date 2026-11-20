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

    enum Display: String, CaseIterable, Identifiable {
        /// Artwork and waveform only.
        case icon
        case iconAndTitle
        /// Title over artist, in smaller type.
        case twoLine

        var id: String { rawValue }
        var label: String {
            switch self {
            case .icon: return "Icon"
            case .iconAndTitle: return "Icon + title"
            case .twoLine: return "Two-line"
            }
        }
    }

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

    static let titleWidthRange: ClosedRange<Double> = 100...320

    @Published var display: Display { didSet { store(display.rawValue, for: .display) } }
    /// Widest the title may get before it scrolls or truncates, in points.
    @Published var maxTitleWidth: Double { didSet { store(maxTitleWidth, for: .maxTitleWidth) } }
    @Published var scrollLongTitles: Bool { didSet { store(scrollLongTitles, for: .scrollLongTitles) } }
    @Published var showProgress: Bool { didSet { store(showProgress, for: .showProgress) } }
    @Published var hideWhenIdle: Bool { didSet { store(hideWhenIdle, for: .hideWhenIdle) } }
    @Published var showWhenPaused: Bool { didSet { store(showWhenPaused, for: .showWhenPaused) } }
    @Published var sources: Set<Source> { didSet { store(sources.map(\.rawValue).sorted(), for: .sources) } }

    private enum Key: String {
        case display, maxTitleWidth, scrollLongTitles, showProgress, hideWhenIdle, showWhenPaused, sources
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        display = defaults.string(forKey: Key.display.rawValue).flatMap(Display.init) ?? .iconAndTitle
        maxTitleWidth = (defaults.object(forKey: Key.maxTitleWidth.rawValue) as? Double)
            .map { min(max($0, Self.titleWidthRange.lowerBound), Self.titleWidthRange.upperBound) } ?? 150
        scrollLongTitles = defaults.object(forKey: Key.scrollLongTitles.rawValue) as? Bool ?? true
        showProgress = defaults.object(forKey: Key.showProgress.rawValue) as? Bool ?? false
        hideWhenIdle = defaults.object(forKey: Key.hideWhenIdle.rawValue) as? Bool ?? false
        showWhenPaused = defaults.object(forKey: Key.showWhenPaused.rawValue) as? Bool ?? true
        sources = (defaults.stringArray(forKey: Key.sources.rawValue)).map { Set($0.compactMap(Source.init)) }
            ?? Set(Source.allCases)
    }

    /// Whether a session from this app should show in the menu bar.
    func allows(bundleIdentifier: String?) -> Bool {
        sources.contains(Source(bundleIdentifier: bundleIdentifier))
    }

    private func store(_ value: Any, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}
