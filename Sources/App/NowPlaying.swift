//
//  NowPlaying.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit

/// One reading of the system Now Playing session.
struct NowPlaying {
    var title: String
    var artist: String?
    var album: String?
    /// The player app; for web players this is the browser.
    var bundleIdentifier: String?
    var isPlaying: Bool
    var duration: TimeInterval?
    /// Position at `sampledAt`. Use `position(at:)` for the live value.
    var elapsed: TimeInterval?
    var sampledAt: Date?
    var rate: Double
    var artwork: NSImage?

    /// Current playback position, extrapolated from the last sample so
    /// progress can advance smoothly between updates.
    func position(at now: Date = Date()) -> TimeInterval? {
        guard var position = elapsed else { return nil }
        if isPlaying, let sampledAt {
            position += now.timeIntervalSince(sampledAt) * rate
        }
        if let duration, duration > 0 {
            position = min(position, duration)
        }
        return max(0, position)
    }

    /// Fraction played, 0...1, when the duration is known.
    func progress(at now: Date = Date()) -> Double? {
        guard let duration, duration > 0, let position = position(at: now) else { return nil }
        return position / duration
    }
}
