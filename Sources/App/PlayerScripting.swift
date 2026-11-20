//
//  PlayerScripting.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import Foundation

/// Players Tuno can drive beyond play, pause and skip. MediaRemote ignores
/// third-party commands, and media keys can't seek, so these go through
/// AppleScript. macOS asks once for permission to control each app.
enum ScriptablePlayer: String {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    init?(bundleIdentifier: String?) {
        guard let bundleIdentifier, let player = ScriptablePlayer(rawValue: bundleIdentifier) else { return nil }
        self = player
    }

    fileprivate var scriptName: String { self == .music ? "Music" : "Spotify" }

    var supportsFavorite: Bool { self == .music }

    /// The order a repeat button cycles through. Spotify's is on or off.
    var repeatCycle: [RepeatMode] { self == .music ? [.off, .all, .one] : [.off, .all] }
}

enum RepeatMode: String {
    case off, all, one
}

struct ScriptState: Equatable {
    var shuffle: Bool
    var repeatMode: RepeatMode
    /// nil where the player has no favourites (Spotify).
    var favorited: Bool?
}

final class PlayerScripting {
    static let shared = PlayerScripting()

    /// NSAppleScript isn't safe to run concurrently; one serial queue keeps
    /// scripts off the main thread and in order.
    private let queue = DispatchQueue(label: "com.kaanfirat.tuno.scripting")

    // MARK: - Commands

    func seek(_ player: ScriptablePlayer, to seconds: TimeInterval) {
        tell(player, "set player position to \(Self.number(max(0, seconds)))")
    }

    func skip(_ player: ScriptablePlayer, by seconds: TimeInterval) {
        tell(player, "set player position to (player position + \(Self.number(seconds)))")
    }

    func setShuffle(_ player: ScriptablePlayer, _ on: Bool) {
        tell(player, player == .music ? "set shuffle enabled to \(on)" : "set shuffling to \(on)")
    }

    func setRepeat(_ player: ScriptablePlayer, _ mode: RepeatMode) {
        switch player {
        case .music: tell(player, "set song repeat to \(mode.rawValue)")
        case .spotify: tell(player, "set repeating to \(mode != .off)")
        }
    }

    func setFavorite(_ player: ScriptablePlayer, _ on: Bool) {
        guard player == .music else { return }
        // "favorited" since macOS 14; earlier releases call it "loved".
        tell(player, """
            try
                set favorited of current track to \(on)
            on error
                set loved of current track to \(on)
            end try
            """)
    }

    /// Reads shuffle, repeat and favourite. nil when the app isn't running
    /// or Tuno isn't allowed to control it.
    func state(of player: ScriptablePlayer, completion: @escaping (ScriptState?) -> Void) {
        let body: String
        switch player {
        case .music:
            body = """
                set f to false
                try
                    set f to favorited of current track
                on error
                    try
                        set f to loved of current track
                    end try
                end try
                return {shuffle enabled, song repeat as string, f}
                """
        case .spotify:
            body = "return {shuffling, repeating}"
        }
        run(script(player, body)) { result in
            guard let result, result.numberOfItems >= 2 else { return completion(nil) }
            let shuffle = result.atIndex(1)?.booleanValue ?? false
            let repeatMode: RepeatMode
            if player == .music {
                repeatMode = RepeatMode(rawValue: result.atIndex(2)?.stringValue ?? "") ?? .off
            } else {
                repeatMode = result.atIndex(2)?.booleanValue == true ? .all : .off
            }
            let favorited = player == .music ? (result.atIndex(3)?.booleanValue ?? false) : nil
            completion(ScriptState(shuffle: shuffle, repeatMode: repeatMode, favorited: favorited))
        }
    }

    // MARK: - Running

    private func tell(_ player: ScriptablePlayer, _ body: String) {
        run(script(player, body), completion: nil)
    }

    /// Wrapped so a script never launches a player that isn't running.
    private func script(_ player: ScriptablePlayer, _ body: String) -> String {
        """
        if application "\(player.scriptName)" is running then
            tell application "\(player.scriptName)"
                \(body)
            end tell
        end if
        """
    }

    private func run(_ source: String, completion: ((NSAppleEventDescriptor?) -> Void)?) {
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let completion else { return }
            DispatchQueue.main.async { completion(error == nil ? result : nil) }
        }
    }

    /// Locale-independent, so a comma decimal separator can't break the script.
    private static func number(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
