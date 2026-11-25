//
//  NotchContent.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit
import NotchKit
import SwiftUI

/// Sizes of the open player. NotchKit is told the total, so there's no
/// slack under the controls.
enum PlayerPanelMetrics {
    static let width: CGFloat = 360
    static let spacing: CGFloat = 12
    /// The content starts a little above the notch's bottom edge plus `spacing`.
    static let topPadding: CGFloat = spacing - 4
    static let bottomPadding: CGFloat = 12
    static let headerHeight: CGFloat = 52
    static let progressHeight: CGFloat = 12
    static let controlsHeight: CGFloat = 28
    /// Line added under the closed notch for a sneak peek.
    static let peekLine: CGFloat = 22

    /// The player's size below the notch, with or without a progress row.
    static func size(showsProgress: Bool) -> CGSize {
        var height = topPadding + headerHeight + spacing + controlsHeight + bottomPadding
        if showsProgress { height += progressHeight + spacing }
        return CGSize(width: width, height: height)
    }
}

extension PlayerModel {
    var isPlaying: Bool { reading?.isPlaying ?? false }
    /// The artwork's colour while playing, grey when paused.
    var activeTint: NSColor { isPlaying ? (tint ?? .white) : .secondaryLabelColor }
}

// MARK: - Closed

/// The artwork, in the wing left of the notch.
struct CompactArtwork: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        NotchArtwork(model: model, size: 20, radius: 5)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.reading.map { "Now playing: \($0.title)" } ?? "Tuno")
    }
}

/// The waveform, in the wing right of the notch.
struct CompactWaveform: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        WaveformView(playing: model.isPlaying, color: model.activeTint)
            .frame(width: 16, height: 14)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityHidden(true)
    }
}

/// Playback progress as a thin line under the notch, for when the menu bar
/// leaves no room for the wings. Ticks locally, like `NotchProgress`.
struct ProgressLine: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            GeometryReader { geometry in
                // A live stream has no progress to show; the line is just lit.
                let fraction = CGFloat(model.reading?.progress(at: context.date) ?? 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(Color(nsColor: model.activeTint))
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The new track, under the closed notch.
struct PeekLine: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        Text([model.reading?.title, model.reading?.artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 14)
            .frame(height: PlayerPanelMetrics.peekLine - 4)
    }
}

/// There is no menu bar item; this is the way to Settings and Quit.
struct NotchMenu: View {
    let model: PlayerModel

    var body: some View {
        Button("Settings…", action: model.onSettings)
        Button("Quit Tuno", action: model.onQuit)
        #if DEBUG
        if !model.debugActions.isEmpty {
            Divider()
            ForEach(model.debugActions.indices, id: \.self) { index in
                Button(model.debugActions[index].title, action: model.debugActions[index].action)
            }
        }
        #endif
    }
}

// MARK: - Open

/// The small player the notch opens into.
struct PlayerPanel: View {
    @ObservedObject var model: PlayerModel

    private var playing: Bool { model.isPlaying }
    private var tint: NSColor { model.activeTint }

    var body: some View {
        VStack(spacing: PlayerPanelMetrics.spacing) {
            HStack(spacing: 12) {
                Button(action: model.onOpenApp) {
                    HStack(spacing: 12) {
                        NotchArtwork(model: model, size: PlayerPanelMetrics.headerHeight, radius: 10)
                            // A glow in the artwork's own colour while playing.
                            .shadow(color: Color(nsColor: tint).opacity(playing ? 0.7 : 0), radius: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            MarqueeText(text: model.reading?.title ?? "Nothing is playing",
                                        font: .systemFont(ofSize: 13, weight: .semibold), color: .white)
                            if let subtitle {
                                MarqueeText(text: subtitle, font: .systemFont(ofSize: 12), color: Color(white: 0.63))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.appName.map { "Open \($0)" } ?? "")
                if let favorited = model.scriptState?.favorited {
                    control(favorited ? "heart.fill" : "heart", size: 14, label: favorited ? "Unfavourite" : "Favourite",
                            active: favorited, action: model.onToggleFavorite)
                }
                WaveformView(playing: playing, color: tint)
                    .frame(width: 18, height: 16)
            }
            if model.showsProgress, let reading = model.reading {
                NotchProgress(reading: reading, fill: playing ? Color(nsColor: tint) : .white,
                              onSeek: model.scriptable == nil ? nil : model.onSeek)
                    .frame(height: PlayerPanelMetrics.progressHeight)
            }
            controls
        }
        .padding(.top, PlayerPanelMetrics.topPadding)
        .padding(.horizontal, 18)
        .padding(.bottom, PlayerPanelMetrics.bottomPadding)
    }

    /// Previous, play/pause, next; for scriptable players also ±10 s,
    /// shuffle and repeat around them.
    @ViewBuilder
    private var controls: some View {
        let extended = model.scriptable != nil
        HStack(spacing: extended ? 14 : 28) {
            if extended {
                let shuffle = model.scriptState?.shuffle ?? false
                control("shuffle", size: 13, label: shuffle ? "Shuffle on" : "Shuffle off", active: shuffle,
                        action: model.onToggleShuffle)
                    .disabled(model.scriptState == nil)
                control("gobackward.10", size: 15, label: "Back 10 seconds") { model.onSkip(-10) }
            }
            control("backward.end.fill", size: 16, label: "Previous") { model.onCommand(.previous) }
            control(playing ? "pause.fill" : "play.fill", size: 20, label: playing ? "Pause" : "Play") {
                model.onCommand(.playPause)
            }
            control("forward.end.fill", size: 16, label: "Next") { model.onCommand(.next) }
            if extended {
                control("goforward.10", size: 15, label: "Forward 10 seconds") { model.onSkip(10) }
                let mode = model.scriptState?.repeatMode ?? .off
                control(mode == .one ? "repeat.1" : "repeat", size: 13,
                        label: mode == .off ? "Repeat off" : mode == .one ? "Repeat one" : "Repeat all",
                        active: mode != .off, action: model.onCycleRepeat)
                    .disabled(model.scriptState == nil)
            }
        }
    }

    private var subtitle: String? {
        let parts = [model.reading?.artist, model.appName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `active` marks a toggle that is on (shuffle, repeat, favourite): it
    /// takes the artwork's colour; when off it is dimmed.
    private func control(_ symbol: String, size: CGFloat, label: String, active: Bool? = nil,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(active.map { $0 ? Color(nsColor: model.tint ?? .white) : Color(white: 0.5) } ?? .white)
                .frame(width: PlayerPanelMetrics.controlsHeight, height: PlayerPanelMetrics.controlsHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Pieces

/// Track artwork, greyed out while paused.
struct NotchArtwork: View {
    @ObservedObject var model: PlayerModel
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image = model.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(white: 0.2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .saturation(model.isPlaying ? 1 : 0)
        .opacity(model.isPlaying ? 1 : 0.55)
    }
}

/// Elapsed time, bar and duration on one line. Ticks locally from the last
/// sample, so it moves without new data from the bridge.
private struct NotchProgress: View {
    let reading: NowPlaying
    var fill: Color = .white
    /// Seeks to a position in seconds; nil when the player can't seek.
    var onSeek: ((TimeInterval) -> Void)?
    /// Where the bar is being dragged to, as a fraction.
    @State private var scrub: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            let duration = reading.duration ?? 0
            let position = scrub.map { $0 * duration } ?? reading.position(at: context.date) ?? 0
            HStack(spacing: 8) {
                Text(TimeText.format(position))
                GeometryReader { geometry in
                    let fraction = CGFloat(duration > 0 ? min(position / duration, 1) : 0)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(fill)
                            .frame(width: geometry.size.width * fraction)
                    }
                    .frame(height: onSeek != nil && (hovering || scrub != nil) ? 6 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(seekGesture(width: geometry.size.width, duration: duration))
                }
                .onHover { hovering = $0 }
                Text(TimeText.format(duration))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundColor(Color(white: 0.63))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(TimeText.format(position)) of \(TimeText.format(duration))")
        }
    }

    /// Drag or click anywhere on the bar to seek, for players that allow it.
    private func seekGesture(width: CGFloat, duration: TimeInterval) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard onSeek != nil, width > 0 else { return }
                scrub = Double(min(max(value.location.x / width, 0), 1))
            }
            .onEnded { _ in
                guard let onSeek, let fraction = scrub else { return }
                onSeek(fraction * duration)
                // Hold the scrubbed position until the player reports the new one.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { scrub = nil }
            }
    }
}
