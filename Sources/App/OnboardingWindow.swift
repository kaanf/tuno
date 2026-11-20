//
//  OnboardingWindow.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit
import Combine
import SwiftUI

/// Asks for Accessibility permission on first launch, and again whenever a
/// control is used without it, in place of the system's bare prompt.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private static let dismissedKey = "onboardingDismissed"

    var onOpenSettings: (() -> Void)?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: OnboardingView.size),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(onboardingHex: 0x0B0C12)
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        self.init(window: window)
        window.delegate = self
        let hosting = NSHostingView(rootView: OnboardingView(
            onDone: { [weak self] in self?.close() },
            onNotNow: { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.dismissedKey)
                self?.close()
            },
            onOpenSettings: { [weak self] in
                self?.close()
                self?.onOpenSettings?()
            }
        ))
        // Left to itself the hosting view grows the window by the title bar's
        // height; the view already draws under it.
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
        window.contentView = hosting
        window.setContentSize(OnboardingView.size)
    }

    /// On launch: only when permission is missing and the user hasn't said
    /// "Not now" before.
    func presentIfNeeded() {
        guard !MediaKeys.isTrusted, !UserDefaults.standard.bool(forKey: Self.dismissedKey) else { return }
        present()
    }

    func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        // Tuno has no Dock icon; it has to activate to bring a window forward.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct OnboardingView: View {
    static let size = NSSize(width: 440, height: 440)

    let onDone: () -> Void
    let onNotNow: () -> Void
    let onOpenSettings: () -> Void

    @State private var trusted = MediaKeys.isTrusted

    /// Picks up the grant from System Settings without any action here.
    private let permissionPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let tint = Color(onboardingHex: 0x2F7FD0)
    private let glow = Color(onboardingHex: 0x3896E1)
    private let green = Color(onboardingHex: 0x34C759)

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .shadow(color: glow.opacity(0.45), radius: 11, y: 8)
                .padding(.top, 34)

            Text(trusted ? "You're all set" : "Let tuno control playback")
                .font(.system(size: 17, weight: .bold))
                .padding(.top, 12)
            Text(trusted
                 ? "tuno can now play, pause and skip for you. Hover over the notch to open the player."
                 : "tuno presses play, pause and skip the same way your keyboard's media keys do. macOS needs you to allow that once, under Accessibility.")
                .font(.system(size: 12))
                .lineSpacing(2.5)
                .foregroundColor(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            settingsPreview.padding(.top, 16)

            HStack(spacing: 6) {
                Circle().frame(width: 7, height: 7)
                Text(trusted ? "Accessibility is on" : "Waiting for permission…")
            }
            .font(.system(size: 11))
            .foregroundColor(trusted ? green : .white.opacity(0.55))
            .padding(.top, 10)

            Spacer(minLength: 0)

            VStack(spacing: 4) {
                Button(action: trusted ? onDone : allow) {
                    Text(trusted ? "Start listening" : "Open System Settings")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(tint))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                Button(trusted ? "Open Settings" : "Not now", action: trusted ? onOpenSettings : onNotNow)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(height: 26)

                Text("tuno never reads your screen or what you type.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(width: Self.size.width, height: Self.size.height)
        .foregroundColor(.white)
        .background(background)
        // The content runs under the transparent title bar, as in the design.
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.3), value: trusted)
        .onReceive(permissionPoll) { _ in trusted = MediaKeys.isTrusted }
    }

    /// A small stand-in for the row the user has to switch on.
    private var settingsPreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(tint)
                    .frame(width: 20, height: 20)
                    .overlay(Image(systemName: "accessibility").font(.system(size: 11, weight: .medium)))
                Text("Privacy & Security › Accessibility")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.86))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5).padding(.horizontal, 12)

            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 20, height: 20)
                Text("Tuno").font(.system(size: 12, weight: .semibold))
                Spacer()
                Capsule()
                    .fill(trusted ? green : Color(onboardingHex: 0x3A3A3F))
                    .frame(width: 32, height: 18)
                    .overlay(
                        Circle()
                            .fill(Color.white)
                            .frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                            .offset(x: trusted ? 7 : -7)
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        )
        .accessibilityElement(children: .combine)
    }

    private var background: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color(onboardingHex: 0x0B0C12)
                EllipticalGradient(colors: [glow.opacity(0.42), .clear], center: .top,
                                   startRadiusFraction: 0, endRadiusFraction: 0.7)
                    .frame(width: size.width * 1.2, height: size.height * 0.9)
                    .position(x: size.width / 2, y: 0)
                EllipticalGradient(colors: [Color(onboardingHex: 0x1850AA).opacity(0.30), .clear], center: .top,
                                   startRadiusFraction: 0, endRadiusFraction: 0.7)
                    .frame(width: size.width * 0.8, height: size.height * 0.7)
                    .position(x: size.width * 0.1, y: 0)
            }
        }
    }

    private func allow() {
        // The prompting check is what puts Tuno in the Accessibility list, so
        // there's a switch waiting when System Settings opens.
        MediaKeys.requestTrust()
        MediaKeys.openAccessibilitySettings()
    }
}

private extension Color {
    init(onboardingHex hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

private extension NSColor {
    convenience init(onboardingHex hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
