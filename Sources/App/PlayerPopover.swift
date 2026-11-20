//
//  PlayerPopover.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import SwiftUI

/// What the player popover shows, and what it can ask for.
final class PlayerModel: ObservableObject {
    @Published var reading: NowPlaying?
    /// Blurred artwork filling the sides of the artwork well.
    @Published var backdrop: NSImage?
    /// Display name of the app that owns the session, e.g. "Music".
    @Published var appName: String?
    @Published var canControl = MediaKeys.isTrusted

    var onCommand: (MediaKeys.Key) -> Void = { _ in }
    var onOpenApp: () -> Void = {}
    var onCopy: () -> Void = {}
    var onAllowAccessibility: () -> Void = {}
    var onQuit: () -> Void = {}
    var onSettings: () -> Void = {}
}

struct PlayerView: View {
    @ObservedObject var model: PlayerModel

    enum Metrics {
        static let width: CGFloat = 340
        static let padding: CGFloat = 12
        static let artworkHeight: CGFloat = 162
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let reading = model.reading {
                ArtworkWell(image: reading.artwork, backdrop: model.backdrop)
                titles(reading)
                if reading.duration ?? 0 > 0 {
                    PlaybackProgress(reading: reading)
                }
                controls(isPlaying: reading.isPlaying)
            } else {
                nothingPlaying
            }
            Divider()
            footer
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.reading?.isPlaying == true ? Color(red: 0.69, green: 0.32, blue: 0.87) : Color.secondary)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(model.appName ?? "Now Playing")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Menu {
                Button("Copy Title and Artist", action: model.onCopy)
                    .disabled(model.reading == nil)
                if !model.canControl {
                    Button("Allow Accessibility Access…", action: model.onAllowAccessibility)
                }
                Divider()
                Button("Quit Tuno", action: model.onQuit)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .accessibilityLabel("More options")
        }
    }

    private func titles(_ reading: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(reading.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if let subtitle = [reading.artist, reading.album].compactMap({ $0 }).filter({ !$0.isEmpty }).first {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .textSelection(.enabled)
    }

    private func controls(isPlaying: Bool) -> some View {
        HStack(spacing: 14) {
            Spacer()
            IconButton(symbol: "backward.end.fill", label: "Previous") { model.onCommand(.previous) }
            Button { model.onCommand(.playPause) } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.accentColor))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            IconButton(symbol: "forward.end.fill", label: "Next") { model.onCommand(.next) }
            Spacer()
        }
    }

    private var nothingPlaying: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: 24))
            Text("Nothing is playing")
                .font(.system(size: 12))
        }
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, minHeight: Metrics.artworkHeight)
    }

    private var footer: some View {
        HStack {
            Button(action: model.onOpenApp) {
                Text("Open in \(model.appName ?? "Player")")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(model.appName == nil)
            Spacer()
            IconButton(symbol: "gearshape", label: "Settings", size: 14, action: model.onSettings)
        }
    }
}

// MARK: - Pieces

/// The artwork in a fixed-height well: shown whole, with a blurred copy of
/// itself filling the sides, so square album art isn't cropped.
private struct ArtworkWell: View {
    let image: NSImage?
    let backdrop: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08))
            if let image {
                if let backdrop {
                    Image(nsImage: backdrop)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .opacity(0.6)
                }
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(6)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .padding(10)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: PlayerView.Metrics.artworkHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Artwork")
    }
}

/// Progress bar and times. Ticks locally from the last sample, so it moves
/// smoothly without new data from the bridge.
private struct PlaybackProgress: View {
    let reading: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            let position = reading.position(at: context.date) ?? 0
            let duration = reading.duration ?? 0
            VStack(spacing: 4) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(Color.primary)
                            .frame(width: geometry.size.width * CGFloat(duration > 0 ? position / duration : 0))
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(Self.format(position))
                    Spacer()
                    Text(Self.format(duration))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Self.format(position)) of \(Self.format(duration))")
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A 32 pt transport button with a soft hover background.
private struct IconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 16
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovered ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
    }
}
