//
//  PlayerModel.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit

/// What the notch player shows, and what it can ask for.
final class PlayerModel: ObservableObject {
    @Published var reading: NowPlaying?
    /// Artwork to show: the track's, or the player app's icon when it has none.
    @Published var artwork: NSImage?
    /// Display name of the app that owns the session, e.g. "Music".
    @Published var appName: String?
    /// Waveform colour taken from the artwork, for a dark background.
    @Published var tint: NSColor?
    /// Set when the player can be scripted (Music, Spotify): seeking, ±10 s,
    /// shuffle, repeat and, for Music, favourites.
    @Published var scriptable: ScriptablePlayer?
    /// Last read shuffle / repeat / favourite state; nil until read.
    @Published var scriptState: ScriptState?

    var onCommand: (MediaKeys.Key) -> Void = { _ in }
    var onSeek: (TimeInterval) -> Void = { _ in }
    var onSkip: (TimeInterval) -> Void = { _ in }
    var onToggleShuffle: () -> Void = {}
    var onCycleRepeat: () -> Void = {}
    var onToggleFavorite: () -> Void = {}
    var onOpenApp: () -> Void = {}
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = {}
}

enum TimeText {
    /// "3:07", or "1:02:45" past an hour.
    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
