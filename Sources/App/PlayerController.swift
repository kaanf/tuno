//
//  PlayerController.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit
import Combine

/// Connects the Now Playing stream to the notch: applies the user's filters,
/// prepares artwork and tint, and handles the global shortcut and Settings.
final class PlayerController {
    private let monitor: NowPlayingMonitor?
    private let preferences: Preferences
    private let notch = NotchController()
    private lazy var settingsWindow = SettingsWindowController(preferences: preferences)
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.notch.toggleFromKeyboard() ?? () }
    private var preferencesObserver: AnyCancellable?

    /// The shortcut last handed to `hotKey`; `.none` until the first apply.
    private var appliedShortcut: Shortcut?? = .none

    // Tint is computed once per artwork image; the monitor hands out a new
    // NSImage only when the bytes change, so identity is a cheap check.
    private var tintSource: NSImage?
    private var tint: NSColor?

    /// A track change often arrives a moment before its artwork. Keep the
    /// previous artwork that long instead of flashing the app icon.
    private let artworkGrace: TimeInterval = 2
    private var lastArtwork: (image: NSImage, app: String?)?
    private var artworkGraceEnds: Date?

    private var nameCache: [String: String] = [:]
    private var iconCache: [String: NSImage] = [:]

    init(monitor: NowPlayingMonitor?, preferences: Preferences = .shared) {
        self.monitor = monitor
        self.preferences = preferences

        let model = notch.model
        model.onCommand = { [weak self] key in self?.press(key) }
        model.onOpenApp = { [weak self] in self?.openPlayerApp() }
        model.onSettings = { [weak self] in self?.showSettings() }
        model.onQuit = { NSApp.terminate(nil) }

        monitor?.onChange = { [weak self] reading in self?.render(reading) }
        applyPreferences()
        // objectWillChange fires before the new value is stored; read it a beat later.
        preferencesObserver = preferences.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applyPreferences() }
        }
    }

    func showSettings() {
        settingsWindow.present()
    }

    private func applyPreferences() {
        applyShortcut()
        render(monitor?.current)
    }

    private func applyShortcut() {
        let wanted = preferences.isRecordingShortcut ? nil : preferences.openPlayerShortcut
        guard appliedShortcut != .some(wanted) else { return }
        appliedShortcut = .some(wanted)
        let unavailable = !hotKey.register(wanted)
        // Only on change: every assignment republishes and would re-enter here.
        if preferences.shortcutUnavailable != unavailable { preferences.shortcutUnavailable = unavailable }
    }

    // MARK: - Rendering

    /// The session as the settings would show it: nil when its app is
    /// filtered out, or when it's paused and paused sessions are hidden.
    private func visible(_ reading: NowPlaying?) -> NowPlaying? {
        guard let reading, preferences.allows(bundleIdentifier: reading.bundleIdentifier) else { return nil }
        if !reading.isPlaying, !preferences.showWhenPaused { return nil }
        return reading
    }

    private func render(_ session: NowPlaying?) {
        guard let reading = visible(session) else { return notch.hide() }
        let model = notch.model
        let artwork = artwork(for: reading)
        model.reading = reading
        model.artwork = artwork
        model.appName = appName(for: reading.bundleIdentifier)
        model.tint = artwork.flatMap(tint(for:))
        notch.show()
    }

    /// Track artwork, the previous track's for a moment while the new one
    /// loads, or the player app's icon.
    private func artwork(for reading: NowPlaying) -> NSImage? {
        if let image = reading.artwork {
            lastArtwork = (image, reading.bundleIdentifier)
            artworkGraceEnds = nil
            return image
        }
        if let last = lastArtwork, last.app == reading.bundleIdentifier {
            let now = Date()
            if artworkGraceEnds == nil {
                artworkGraceEnds = now.addingTimeInterval(artworkGrace)
                DispatchQueue.main.asyncAfter(deadline: .now() + artworkGrace + 0.05) { [weak self] in
                    self?.render(self?.monitor?.current)
                }
            }
            if let ends = artworkGraceEnds, now < ends { return last.image }
            lastArtwork = nil
        }
        return appIcon(for: reading.bundleIdentifier)
    }

    private func tint(for image: NSImage) -> NSColor? {
        if image !== tintSource {
            tintSource = image
            tint = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                .map { Tint(dominantIn: $0).color(onDark: true) }
        }
        return tint
    }

    private func appName(for bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }
        if let cached = nameCache[bundleIdentifier] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        nameCache[bundleIdentifier] = name
        return name
    }

    private func appIcon(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier else { return nil }
        if let cached = iconCache[bundleIdentifier] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleIdentifier] = icon
        return icon
    }

    // MARK: - Actions

    private func press(_ key: MediaKeys.Key) {
        MediaKeys.press(key)
        // Most players notify right away; a slow web player gets a nudge.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.monitor?.refresh()
        }
    }

    private func openPlayerApp() {
        guard let id = monitor?.current?.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
