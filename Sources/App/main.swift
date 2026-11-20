//
//  main.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: NowPlayingMonitor?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = NowPlayingMonitor()
        statusItem = StatusItemController(monitor: monitor)
        monitor?.start()
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
