//
//  main.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: NowPlayingMonitor?
    private var player: PlayerController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = NowPlayingMonitor()
        player = PlayerController(monitor: monitor)
        monitor?.start()
    }

    /// Opening Tuno again while it runs shows Settings. With no menu bar
    /// item, that and the notch's right-click menu are the ways in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        player?.showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }
}

// The bridge's stdin may close under us if perl exits; a write to it must
// fail with an error instead of killing Tuno.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
