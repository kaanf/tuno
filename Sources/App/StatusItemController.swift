//
//  StatusItemController.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit

/// The menu bar item: artwork and title of what's playing, with a menu for
/// playback controls. A stand-in until the designed capsule and popover land.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor: NowPlayingMonitor?
    private let menu = NSMenu()

    /// Widest the title may get, in points, before it is truncated.
    var maxTitleWidth: CGFloat = 180 { didSet { render(monitor?.current) } }

    init(monitor: NowPlayingMonitor?) {
        self.monitor = monitor
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeft
        render(nil)

        monitor?.onChange = { [weak self] reading in self?.render(reading) }
        if monitor == nil {
            statusItem.button?.title = "Tuno unavailable"
        }
    }

    // MARK: - Rendering

    private func render(_ reading: NowPlaying?) {
        guard let button = statusItem.button else { return }
        guard let reading else {
            button.image = Self.symbol("music.note")
            button.title = ""
            button.toolTip = nil
            return
        }

        button.image = reading.artwork.map(Self.menuBarArtwork) ?? Self.symbol(reading.isPlaying ? "play.fill" : "pause.fill")
        let font = NSFont.menuBarFont(ofSize: 0)
        button.attributedTitle = NSAttributedString(
            string: " " + Self.truncate(reading.title, toWidth: maxTitleWidth, font: font),
            attributes: [.font: font, .foregroundColor: reading.isPlaying ? NSColor.labelColor : NSColor.secondaryLabelColor]
        )
        button.toolTip = [reading.title, reading.artist, reading.album].compactMap { $0 }.joined(separator: "\n")
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Tuno")
        image?.isTemplate = true
        return image
    }

    /// 16 pt artwork with rounded corners, as in the menu bar design.
    private static func menuBarArtwork(_ source: NSImage) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    private static func truncate(_ text: String, toWidth width: CGFloat, font: NSFont) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard (text as NSString).size(withAttributes: attributes).width > width else { return text }
        var low = 0, high = text.count
        while low < high {
            let mid = (low + high + 1) / 2
            let candidate = String(text.prefix(mid)).trimmingCharacters(in: .whitespaces) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= width {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return String(text.prefix(low)).trimmingCharacters(in: .whitespaces) + "…"
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
