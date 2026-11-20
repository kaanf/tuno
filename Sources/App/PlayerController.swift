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
    private lazy var onboardingWindow: OnboardingWindowController = {
        let controller = OnboardingWindowController()
        controller.onOpenSettings = { [weak self] in self?.showSettings() }
        return controller
    }()
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

    /// Identifies the current track, to notice changes worth a sneak peek.
    private var trackKey: String?
    private let scripting = PlayerScripting.shared
    /// A shuffle, repeat or favourite change just sent. Players report the
    /// old value for a moment after applying a change, so reads don't
    /// overwrite this until they agree with it or it expires.
    private var pendingState: (state: ScriptState, until: Date)?

    init(monitor: NowPlayingMonitor?, preferences: Preferences = .shared) {
        self.monitor = monitor
        self.preferences = preferences

        let model = notch.model
        model.onCommand = { [weak self] key in self?.press(key) }
        model.onOpenApp = { [weak self] in self?.openPlayerApp() }
        model.onSettings = { [weak self] in self?.showSettings() }
        model.onQuit = { NSApp.terminate(nil) }
        model.onSeek = { [weak self] seconds in self?.seek(to: seconds) }
        model.onSkip = { [weak self] seconds in self?.skip(by: seconds) }
        model.onToggleShuffle = { [weak self] in self?.toggleShuffle() }
        model.onCycleRepeat = { [weak self] in self?.cycleRepeat() }
        model.onToggleFavorite = { [weak self] in self?.toggleFavorite() }
        notch.onExpand = { [weak self] in self?.refreshScriptState() }

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

    func showOnboardingIfNeeded() {
        onboardingWindow.presentIfNeeded()
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
        guard let reading = visible(session) else {
            trackKey = nil
            return notch.hide()
        }
        let model = notch.model
        let artwork = artwork(for: reading)
        model.reading = reading
        model.artwork = artwork
        model.appName = appName(for: reading.bundleIdentifier)
        model.tint = artwork.flatMap(tint(for:))

        let player = ScriptablePlayer(bundleIdentifier: reading.bundleIdentifier)
        if model.scriptable != player {
            model.scriptable = player
            model.scriptState = nil
        }
        notch.show()

        let key = [reading.bundleIdentifier, reading.title, reading.artist].map { $0 ?? "" }.joined(separator: "\u{1F}")
        if key != trackKey {
            // Not on the first track seen: that's launch, not a change.
            let changed = trackKey != nil
            trackKey = key
            // Favourite belongs to the track; a pending change was for the old one.
            pendingState = nil
            if changed, reading.isPlaying { notch.peek() }
            // Favourite is per track.
            if notch.isExpanded { refreshScriptState() }
        }
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

    // MARK: - Scripting

    private func refreshScriptState() {
        guard let player = notch.model.scriptable else { return }
        scripting.state(of: player) { [weak self] state in
            guard let self, self.notch.model.scriptable == player else { return }
            if let pending = self.pendingState, Date() < pending.until {
                // The player hasn't caught up yet; keep showing the change.
                guard state == pending.state else { return }
            }
            self.pendingState = nil
            self.notch.model.scriptState = state
        }
    }

    /// Shows a change straight away and holds it while the player applies it.
    private func applyLocally(_ state: ScriptState) {
        notch.model.scriptState = state
        pendingState = (state, Date().addingTimeInterval(3))
    }

    /// Re-reads state after a change, twice, since players apply them at
    /// their own pace.
    private func refreshSoon() {
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshScriptState()
                self?.monitor?.refresh()
            }
        }
    }

    private func seek(to seconds: TimeInterval) {
        guard let player = notch.model.scriptable else { return }
        scripting.seek(player, to: seconds)
        refreshSoon()
    }

    private func skip(by seconds: TimeInterval) {
        guard let player = notch.model.scriptable else { return }
        scripting.skip(player, by: seconds)
        refreshSoon()
    }

    private func toggleShuffle() {
        guard let player = notch.model.scriptable, var state = notch.model.scriptState else { return }
        state.shuffle.toggle()
        applyLocally(state)
        scripting.setShuffle(player, state.shuffle)
        refreshSoon()
    }

    private func cycleRepeat() {
        guard let player = notch.model.scriptable, var state = notch.model.scriptState else { return }
        let cycle = player.repeatCycle
        let index = cycle.firstIndex(of: state.repeatMode) ?? 0
        state.repeatMode = cycle[(index + 1) % cycle.count]
        applyLocally(state)
        scripting.setRepeat(player, state.repeatMode)
        refreshSoon()
    }

    private func toggleFavorite() {
        guard let player = notch.model.scriptable, var state = notch.model.scriptState,
              let favorited = state.favorited else { return }
        state.favorited = !favorited
        applyLocally(state)
        scripting.setFavorite(player, !favorited)
        refreshSoon()
    }

    // MARK: - Actions

    private func press(_ key: MediaKeys.Key) {
        guard MediaKeys.isTrusted else {
            onboardingWindow.present()
            return
        }
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
