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

    /// Space between the capsule and the edges of the status item.
    private let inset: CGFloat = 2

    // Artwork is decoded once per image; the monitor hands out a new NSImage
    // only when the bytes change, so identity is a cheap change check.
    private var preparedSource: NSImage?
    private var prepared: Artwork?

    /// Widest the title may get, in points, before it is truncated.
    var maxTitleWidth: CGFloat {
        get { capsule.maxTitleWidth }
        set { capsule.maxTitleWidth = newValue }
    }

    init(monitor: NowPlayingMonitor?) {
        self.monitor = monitor
        super.init()
        menu.delegate = self
        statusItem.menu = menu

        capsule.isHidden = true
        capsule.onResize = { [weak self] _ in self?.fitCapsule() }
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
        statusItem.length = capsule.preferredWidth + inset * 2
        let y = floor((button.bounds.height - CapsuleView.Metrics.height) / 2)
        capsule.setFrameOrigin(NSPoint(x: inset, y: y))
    }

    /// Track artwork, or the player app's icon when the track has none.
    private func artwork(for reading: NowPlaying) -> Artwork? {
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
