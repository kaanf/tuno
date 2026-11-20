//
//  StatusItemController.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit
import Combine
import SwiftUI

/// The menu bar item: the artwork capsule while something is playing, a
/// plain note symbol otherwise. A left click on the artwork or title opens
/// the player popover; a right click opens the menu.
final class StatusItemController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor: NowPlayingMonitor?
    private let preferences: Preferences
    private var preferencesObserver: AnyCancellable?
    private lazy var settingsWindow = SettingsWindowController(preferences: preferences)
    private let menu = NSMenu()
    private let capsule = CapsuleView(frame: NSRect(x: 0, y: 0, width: 0, height: CapsuleView.Metrics.height))
    private let player = PlayerModel()
    private let popover = NSPopover()
    /// When the popover last closed. A click on the capsule that closes a
    /// transient popover must not reopen it on release.
    private var popoverClosedAt = Date.distantPast

    // Artwork is decoded once per image; the monitor hands out a new NSImage
    // only when the bytes change, so identity is a cheap change check.
    private var preparedSource: NSImage?
    private var prepared: Artwork?

    /// A track change often arrives a moment before its artwork. Keep the
    /// previous artwork that long instead of flashing the app icon.
    private let artworkGrace: TimeInterval = 2
    private var trackArtworkApp: String?
    private var artworkGraceEnds: Date?

    private var mouseMonitor: Any?
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.togglePopoverFromKeyboard() }
    /// The shortcut last handed to `hotKey`; `.none` until the first apply.
    private var appliedShortcut: Shortcut?? = .none

    /// What a press on the item opens once the button is released.
    private enum Release { case menu, popover }
    private var pendingRelease: Release?

    init(monitor: NowPlayingMonitor?, preferences: Preferences = .shared) {
        self.monitor = monitor
        self.preferences = preferences
        super.init()
        menu.delegate = self
        // Clicks are taken before the status bar button sees them: no
        // `statusItem.menu` (it would open on any click, controls included),
        // and no button highlight on press.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp]) { [weak self] event in
            guard let self else { return event }
            let handled = event.type == .leftMouseDown || event.type == .rightMouseDown
                ? self.handleMouseDown(event)
                : self.handleMouseUp()
            return handled ? nil : event
        }

        capsule.isHidden = true
        capsule.onResize = { [weak self] in self?.fitCapsule() }
        capsule.onControl = { [weak self] key in self?.press(key) }
        statusItem.button?.addSubview(capsule)
        setUpPopover()
        applyPreferences()
        // objectWillChange fires before the new value is stored; read it a beat later.
        preferencesObserver = preferences.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applyPreferences() }
        }

        monitor?.onChange = { [weak self] reading in self?.render(reading) }
        if monitor == nil {
            statusItem.button?.title = "Tuno unavailable"
        }
    }

    func showSettings() {
        if popover.isShown { popover.performClose(nil) }
        settingsWindow.present()
    }

    private func applyPreferences() {
        capsule.display = preferences.display
        capsule.maxTitleWidth = CGFloat(preferences.maxTitleWidth)
        capsule.scrollsLongTitles = preferences.scrollLongTitles
        capsule.showsProgress = preferences.showProgress
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

    /// The session as the settings would show it: nil when its app is
    /// filtered out, or when it's paused and paused sessions are hidden.
    private func visible(_ reading: NowPlaying?) -> NowPlaying? {
        guard let reading, preferences.allows(bundleIdentifier: reading.bundleIdentifier) else { return nil }
        if !reading.isPlaying, !preferences.showWhenPaused { return nil }
        return reading
    }

    // MARK: - Rendering

    private func render(_ session: NowPlaying?) {
        guard let button = statusItem.button else { return }
        defer { if popover.isShown { syncPlayer() } }
        let reading = visible(session)
        guard let reading, let artwork = artwork(for: reading) else {
            // The popover is anchored to the capsule; it can't outlive it.
            if popover.isShown { popover.performClose(nil) }
            statusItem.isVisible = !preferences.hideWhenIdle
            capsule.isHidden = true
            statusItem.length = NSStatusItem.variableLength
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Tuno")
            button.image?.isTemplate = true
            button.setAccessibilityLabel("Tuno, nothing playing")
            return
        }

        statusItem.isVisible = true
        button.image = nil
        button.title = ""
        let subtitle = [reading.artist, reading.album].compactMap { $0 }.first { !$0.isEmpty }
        capsule.show(.init(title: reading.title, subtitle: subtitle, isPlaying: reading.isPlaying,
                           artwork: artwork.image, pausedArtwork: artwork.paused, tint: artwork.tint))
        let position = reading.position()
        capsule.setProgress(reading.progress(), remaining: reading.duration.flatMap { d in position.map { d - $0 } },
                            rate: reading.rate, playing: reading.isPlaying)
        capsule.isHidden = false
        button.setAccessibilityLabel([reading.title, reading.artist].compactMap { $0 }.joined(separator: ", "))
        fitCapsule()
    }

    private func fitCapsule() {
        guard !capsule.isHidden, let button = statusItem.button else { return }
        let length = capsule.reservedWidth
        if statusItem.length != length { statusItem.length = length }
        let y = floor((button.bounds.height - CapsuleView.Metrics.height) / 2)
        capsule.setFrameOrigin(NSPoint(x: 0, y: y))
    }

    /// Track artwork, or the player app's icon when the track has none.
    private func artwork(for reading: NowPlaying) -> Artwork? {
        if reading.artwork != nil {
            trackArtworkApp = reading.bundleIdentifier
            artworkGraceEnds = nil
        } else if let prepared, trackArtworkApp != nil, trackArtworkApp == reading.bundleIdentifier {
            let now = Date()
            if artworkGraceEnds == nil {
                artworkGraceEnds = now.addingTimeInterval(artworkGrace)
                DispatchQueue.main.asyncAfter(deadline: .now() + artworkGrace + 0.05) { [weak self] in
                    self?.render(self?.monitor?.current)
                }
            }
            if let ends = artworkGraceEnds, now < ends { return prepared }
            trackArtworkApp = nil
        }

        let source = reading.artwork ?? appIcon(for: reading.bundleIdentifier)
        guard let source else { return nil }
        if source !== preparedSource {
            preparedSource = source
            prepared = Artwork(source)
        }
        return prepared
    }

    private var iconCache: [String: NSImage] = [:]

    private func appIcon(for bundleIdentifier: String?) -> NSImage? {
        let key = bundleIdentifier ?? ""
        if let cached = iconCache[key] { return cached }
        let icon: NSImage?
        if let bundleIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        }
        iconCache[key] = icon
        return icon
    }

    private var nameCache: [String: String] = [:]

    private func appName(for bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }
        if let cached = nameCache[bundleIdentifier] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        nameCache[bundleIdentifier] = name
        return name
    }

    // MARK: - Popover

    private func setUpPopover() {
        player.onCommand = { [weak self] key in self?.press(key) }
        player.onOpenApp = { [weak self] in self?.openPlayerApp() }
        player.onCopy = { [weak self] in self?.copyTrack() }
        player.onAllowAccessibility = {
            MediaKeys.requestTrust()
            MediaKeys.openAccessibilitySettings()
        }
        player.onQuit = { NSApp.terminate(nil) }
        player.onSettings = { [weak self] in self?.showSettings() }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PlayerView(model: player))
    }

    /// Brings the popover's model up to date. Done only while the popover is
    /// open (and just before it opens), so a closed popover costs nothing.
    private func syncPlayer() {
        let reading = visible(monitor?.current)
        player.reading = reading
        player.appName = appName(for: reading?.bundleIdentifier)
        player.backdrop = reading?.artwork == nil ? nil : prepared?.backdrop
        player.canControl = MediaKeys.isTrusted
        player.shortcut = preferences.openPlayerShortcut?.displayString
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    /// The global shortcut. Opens even when nothing is playing, anchored to
    /// the note icon; with the item hidden there is nothing to anchor to.
    private func togglePopoverFromKeyboard() {
        guard popover.isShown || statusItem.isVisible else { return NSSound.beep() }
        togglePopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        syncPlayer()
        if let view = popover.contentViewController?.view {
            popover.contentSize = view.fittingSize
        }
        // An accessory app has to be active for a transient popover to take
        // focus and close on outside clicks.
        NSApp.activate(ignoringOtherApps: true)
        if capsule.isHidden {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else {
            capsule.isPinned = true
            popover.show(relativeTo: capsule.capsuleBounds, of: capsule, preferredEdge: .minY)
        }
        // Key, so its keyboard shortcuts and Esc work straight away.
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = Date()
        capsule.isPinned = false
    }

    private func openPlayerApp() {
        guard let id = monitor?.current?.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        popover.performClose(nil)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func copyTrack() {
        guard let reading = monitor?.current else { return }
        let text = [reading.title, reading.artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let reading = monitor?.current

        if let reading {
            let header = NSMenuItem(title: [reading.title, reading.artist].compactMap { $0 }.joined(separator: " — "),
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }

        addItem(to: menu, reading?.isPlaying == true ? "Pause" : "Play", #selector(playPause))
        addItem(to: menu, "Next Track", #selector(nextTrack))
        addItem(to: menu, "Previous Track", #selector(previousTrack))

        if !MediaKeys.isTrusted {
            menu.addItem(.separator())
            addItem(to: menu, "Allow Accessibility Access…", #selector(openAccessibility))
        }

        menu.addItem(.separator())
        addItem(to: menu, "Settings…", #selector(openSettings), key: ",")
        addItem(to: menu, "Quit Tuno", #selector(quit), key: "q")
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    /// Routes a click on the status item. Returns false for clicks elsewhere,
    /// which go on as usual.
    private func handleMouseDown(_ event: NSEvent) -> Bool {
        let location = NSEvent.mouseLocation
        guard let button = statusItem.button, let window = button.window,
              window.convertToScreen(button.convert(button.bounds, to: nil)).contains(location) else { return false }

        if !capsule.isHidden {
            // The room left of a resting capsule is reserved for hover, not a target.
            guard let frame = capsule.screenFrame, frame.contains(location) else { return true }
        }
        if event.type == .leftMouseDown, !capsule.isHidden {
            switch capsule.zone(atScreen: location) {
            case .title:
                // A transient popover closes itself on this very press; don't
                // let the release open it again.
                let justClosed = Date().timeIntervalSince(popoverClosedAt) < 0.3
                if popover.isShown {
                    popover.performClose(nil)
                } else if !justClosed {
                    pendingRelease = .popover
                }
                return true
            case .control(let key):
                press(key)
                return true
            case .none:
                return true
            }
        }
        // macOS highlights a menu bar item when a menu starts tracking while
        // the button is down, so wait for the release.
        if popover.isShown { popover.performClose(nil) }
        pendingRelease = .menu
        return true
    }

    private func handleMouseUp() -> Bool {
        guard let release = pendingRelease else { return false }
        pendingRelease = nil
        // After the event is consumed: popUp runs its own tracking loop.
        DispatchQueue.main.async { [weak self] in
            switch release {
            case .menu: self?.showMenu()
            case .popover: self?.togglePopover()
            }
        }
        return true
    }

    /// Opens the menu under the item at a screen position. Not anchored to
    /// the status bar button, which would highlight while the menu is open.
    private func showMenu() {
        guard let button = statusItem.button, let window = button.window else { return }
        let left = capsule.screenFrame?.minX ?? window.frame.minX
        capsule.isPinned = true
        // Blocks until the menu closes.
        menu.popUp(positioning: nil, at: NSPoint(x: left, y: window.frame.minY - 4), in: nil)
        capsule.isPinned = false
    }

    @objc private func playPause() { press(.playPause) }
    @objc private func nextTrack() { press(.next) }
    @objc private func previousTrack() { press(.previous) }
    @objc private func openAccessibility() { MediaKeys.openAccessibilitySettings() }
    @objc private func openSettings() { showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func press(_ key: MediaKeys.Key) {
        MediaKeys.press(key)
        // Most players notify right away; a slow web player gets a nudge.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.monitor?.refresh()
        }
    }
}
