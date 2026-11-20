//
//  StatusItemController.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit

/// The menu bar item: the artwork capsule while something is playing, a
/// plain note symbol otherwise, and a menu for playback controls until the
/// player popover lands.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor: NowPlayingMonitor?
    private let menu = NSMenu()
    private let capsule = CapsuleView(frame: NSRect(x: 0, y: 0, width: 0, height: CapsuleView.Metrics.height))


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
    /// A press that should open the menu once the button is released.
    private var menuOnRelease = false

    /// Widest the title may get, in points, before it is truncated.
    var maxTitleWidth: CGFloat {
        get { capsule.maxTitleWidth }
        set { capsule.maxTitleWidth = newValue }
    }

    init(monitor: NowPlayingMonitor?) {
        self.monitor = monitor
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
        render(nil)

        monitor?.onChange = { [weak self] reading in self?.render(reading) }
        if monitor == nil {
            statusItem.button?.title = "Tuno unavailable"
        }
    }

    // MARK: - Rendering

    private func render(_ reading: NowPlaying?) {
        guard let button = statusItem.button else { return }
        guard let reading, let artwork = artwork(for: reading) else {
            capsule.isHidden = true
            statusItem.length = NSStatusItem.variableLength
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Tuno")
            button.image?.isTemplate = true
            button.setAccessibilityLabel("Tuno, nothing playing")
            return
        }

        button.image = nil
        button.title = ""
        capsule.show(.init(title: reading.title, isPlaying: reading.isPlaying,
                           artwork: artwork.image, pausedArtwork: artwork.paused, tint: artwork.tint))
        capsule.isHidden = false
        button.setAccessibilityLabel([reading.title, reading.artist].compactMap { $0 }.joined(separator: ", "))
        fitCapsule()
    }

    private func fitCapsule() {
        guard !capsule.isHidden, let button = statusItem.button else { return }
        let length = capsule.reservedWidth
        if statusItem.length != length { statusItem.length = length }
        // Pinned to the right edge, so hovering grows it toward the left
        // inside the room the item already has.
        let y = floor((button.bounds.height - CapsuleView.Metrics.height) / 2)
        capsule.setFrameOrigin(NSPoint(x: length - capsule.frame.width, y: y))
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
                break
            case .control(let key):
                press(key)
                return true
            case .none:
                return true
            }
        }
        // macOS highlights a menu bar item when a menu starts tracking while
        // the button is down, so wait for the release.
        menuOnRelease = true
        return true
    }

    private func handleMouseUp() -> Bool {
        guard menuOnRelease else { return false }
        menuOnRelease = false
        // Open after the event is consumed: popUp runs its own tracking loop.
        DispatchQueue.main.async { [weak self] in self?.showMenu() }
        return true
    }

    /// Opens the menu under the item at a screen position. Not anchored to
    /// the status bar button, which would highlight while the menu is open.
    private func showMenu() {
        guard let button = statusItem.button, let window = button.window else { return }
        let left = capsule.screenFrame?.minX ?? window.frame.minX
        menu.popUp(positioning: nil, at: NSPoint(x: left, y: window.frame.minY - 4), in: nil)
    }

    @objc private func playPause() { press(.playPause) }
    @objc private func nextTrack() { press(.next) }
    @objc private func previousTrack() { press(.previous) }
    @objc private func openAccessibility() { MediaKeys.openAccessibilitySettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func press(_ key: MediaKeys.Key) {
        MediaKeys.press(key)
        // Most players notify right away; a slow web player gets a nudge.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.monitor?.refresh()
        }
    }
}
