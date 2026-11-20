//
//  SettingsWindow.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

/// The Settings window, created on first use and reused after that.
final class SettingsWindowController: NSWindowController {
    convenience init(preferences: Preferences) {
        let hosting = NSHostingController(rootView: SettingsView(preferences: preferences))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        // Tuno has no Dock icon; it has to activate to bring a window forward.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @State private var trusted = MediaKeys.isTrusted
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    /// Re-checks permission while the window is open, so granting it in
    /// System Settings shows up here without reopening.
    private let permissionPoll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Menu bar") {
                row("Display") {
                    Picker("Display", selection: $preferences.display) {
                        ForEach(Preferences.Display.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if preferences.display != .icon {
                    divider
                    row("Maximum width") {
                        HStack(spacing: 10) {
                            Slider(value: $preferences.maxTitleWidth, in: Preferences.titleWidthRange, step: 10)
                                .frame(width: 160)
                                .accessibilityLabel("Maximum width")
                            Text("\(Int(preferences.maxTitleWidth)) pt")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    divider
                    toggleRow("Scroll long titles", detail: "Titles that don't fit scroll in a loop while playing.",
                              isOn: $preferences.scrollLongTitles)
                }
                divider
                toggleRow("Show progress line", isOn: $preferences.showProgress)
            }

            section("Behaviour") {
                toggleRow("Hide when nothing is playing",
                          detail: "Open Tuno again from Finder or Spotlight to reach Settings.",
                          isOn: $preferences.hideWhenIdle)
                divider
                toggleRow("Keep showing when paused", isOn: $preferences.showWhenPaused)
                divider
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sources").font(.system(size: 13))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(Preferences.Source.allCases) { source in
                            Toggle(source.label, isOn: sourceBinding(source))
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                        }
                    }
                    Text("Hidden sources still receive playback controls when they own the session.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            section("Shortcuts") {
                row("Open player", detail: preferences.shortcutUnavailable
                        ? "Another app uses this shortcut. Choose a different one." : nil) {
                    ShortcutRecorder(preferences: preferences)
                }
            }

            section("System") {
                row("Accessibility", detail: "Needed for play, pause and skip.") {
                    if trusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else {
                        Button("Allow…") {
                            MediaKeys.requestTrust()
                            MediaKeys.openAccessibilitySettings()
                        }
                    }
                }
                if LaunchAtLogin.isAvailable {
                    divider
                    toggleRow("Launch at login", detail: loginError, isOn: Binding(
                        get: { launchAtLogin },
                        set: { value in
                            loginError = LaunchAtLogin.set(value)
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    ))
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .onReceive(permissionPoll) { _ in
            trusted = MediaKeys.isTrusted
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11))
                .kerning(0.5)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 0, content: content)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
    }

    private func row<Trailing: View>(_ title: String, detail: String? = nil,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func toggleRow(_ title: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
        row(title, detail: detail) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private var divider: some View {
        Divider().padding(.leading, 12)
    }

    private func sourceBinding(_ source: Preferences.Source) -> Binding<Bool> {
        Binding(
            get: { preferences.sources.contains(source) },
            set: { on in
                if on { preferences.sources.insert(source) } else { preferences.sources.remove(source) }
            }
        )
    }
}

/// Click, then press the new combination. Esc cancels; Delete clears it.
private struct ShortcutRecorder: View {
    @ObservedObject var preferences: Preferences
    @State private var monitor: Any?

    private var recording: Bool { preferences.isRecordingShortcut }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? "Type shortcut…" : preferences.openPlayerShortcut?.displayString ?? "Record Shortcut")
                    .font(.system(size: 12))
                    .frame(minWidth: 100)
            }
            .accessibilityLabel(recording ? "Recording shortcut" : "Open player shortcut")
            if preferences.openPlayerShortcut != nil, !recording {
                Button(action: { preferences.openPlayerShortcut = nil }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .accessibilityLabel("Clear shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        // Releases the current hotkey (see StatusItemController), so pressing
        // the same combination again is seen here instead of opening the player.
        preferences.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let bare = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            switch Int(event.keyCode) {
            case kVK_Escape where bare:
                stop()
            case kVK_Delete where bare, kVK_ForwardDelete where bare:
                preferences.openPlayerShortcut = nil
                stop()
            default:
                if let shortcut = Shortcut(event: event) {
                    preferences.openPlayerShortcut = shortcut
                    stop()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if preferences.isRecordingShortcut { preferences.isRecordingShortcut = false }
    }
}

/// Login item registration (macOS 13+).
enum LaunchAtLogin {
    static var isAvailable: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    /// Returns an error message to show, or nil on success.
    static func set(_ enabled: Bool) -> String? {
        guard #available(macOS 13.0, *) else { return nil }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
