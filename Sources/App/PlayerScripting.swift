//
//  PlayerScripting.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit
import CoreServices

/// Players Tuno can drive beyond play, pause and skip. MediaRemote ignores
/// third-party commands, and media keys can't seek, so these go through
/// Apple events. macOS asks once for permission to control each app.
enum ScriptablePlayer: String {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    init?(bundleIdentifier: String?) {
        guard let bundleIdentifier, let player = ScriptablePlayer(rawValue: bundleIdentifier) else { return nil }
        self = player
    }


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

/// Talks to the players in raw Apple events: the same get and set a script
/// would send, from the players' scripting dictionaries, without compiling
/// AppleScript. Running a script in-process makes macOS load its script
/// scanner into Tuno, some 14 MB that never goes away.
final class PlayerScripting {
    static let shared = PlayerScripting()

    /// Keeps events off the main thread, since each waits for its reply,
    /// and in order.
    private let queue = DispatchQueue(label: "com.kaanfirat.tuno.scripting")

    /// Four-character codes from the Music and Spotify dictionaries.
    private enum Code {
        static let playerPosition = fourCharCode("pPos")
        static let currentTrack = fourCharCode("pTrk")
        // Music
        static let shuffleEnabled = fourCharCode("pShE")
        static let songRepeat = fourCharCode("pRpt")
        /// "favorited" since macOS 14, "loved" before; the code is the same.
        static let favorited = fourCharCode("pLov")
        static let repeatOff = fourCharCode("kRpO")
        static let repeatOne = fourCharCode("kRp1")
        static let repeatAll = fourCharCode("kAll")
        // Spotify
        static let shuffling = fourCharCode("pShu")
        static let repeating = fourCharCode("pRep")
    }

    // MARK: - Commands

    func seek(_ player: ScriptablePlayer, to seconds: TimeInterval) {
        queue.async {
            self.set(Self.property(Code.playerPosition), to: NSAppleEventDescriptor(double: max(0, seconds)), in: player)
        }
    }

    func skip(_ player: ScriptablePlayer, by seconds: TimeInterval) {
        queue.async {
            let position = Self.property(Code.playerPosition)
            guard let now = self.get(position, from: player)?.coerce(toDescriptorType: DescType(typeIEEE64BitFloatingPoint))?.doubleValue else { return }
            self.set(position, to: NSAppleEventDescriptor(double: now + seconds), in: player)
        }
    }

    func setShuffle(_ player: ScriptablePlayer, _ on: Bool) {
        queue.async {
            let code = player == .music ? Code.shuffleEnabled : Code.shuffling
            self.set(Self.property(code), to: NSAppleEventDescriptor(boolean: on), in: player)
        }
    }

    func setRepeat(_ player: ScriptablePlayer, _ mode: RepeatMode) {
        queue.async {
            switch player {
            case .music:
                let code = mode == .off ? Code.repeatOff : mode == .one ? Code.repeatOne : Code.repeatAll
                self.set(Self.property(Code.songRepeat), to: NSAppleEventDescriptor(enumCode: code), in: player)
            case .spotify:
                self.set(Self.property(Code.repeating), to: NSAppleEventDescriptor(boolean: mode != .off), in: player)
            }
        }
    }

    func setFavorite(_ player: ScriptablePlayer, _ on: Bool) {
        guard player == .music else { return }
        queue.async {
            let favorited = Self.property(Code.favorited, of: Self.property(Code.currentTrack))
            self.set(favorited, to: NSAppleEventDescriptor(boolean: on), in: player)
        }
    }

    /// Reads shuffle, repeat and favourite. nil when the app isn't running
    /// or Tuno isn't allowed to control it.
    func state(of player: ScriptablePlayer, completion: @escaping (ScriptState?) -> Void) {
        queue.async {
            let state = self.readState(of: player)
            DispatchQueue.main.async { completion(state) }
        }
    }

    private func readState(of player: ScriptablePlayer) -> ScriptState? {
        switch player {
        case .music:
            guard let shuffle = get(Self.property(Code.shuffleEnabled), from: player),
                  let songRepeat = get(Self.property(Code.songRepeat), from: player) else { return nil }
            let repeatMode: RepeatMode
            switch songRepeat.enumCodeValue {
            case Code.repeatOne: repeatMode = .one
            case Code.repeatAll: repeatMode = .all
            default: repeatMode = .off
            }
            // No current track, no favourite: that reads as not favourited.
            let favorited = get(Self.property(Code.favorited, of: Self.property(Code.currentTrack)), from: player)
            return ScriptState(shuffle: shuffle.booleanValue, repeatMode: repeatMode, favorited: favorited?.booleanValue ?? false)
        case .spotify:
            guard let shuffle = get(Self.property(Code.shuffling), from: player),
                  let repeating = get(Self.property(Code.repeating), from: player) else { return nil }
            return ScriptState(shuffle: shuffle.booleanValue, repeatMode: repeating.booleanValue ? .all : .off, favorited: nil)
        }
    }

    // MARK: - Apple events

    /// An object specifier for a property, of the application or of `container`.
    private static func property(_ code: FourCharCode, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: DescType(typeProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) ?? record
    }

    private func get(_ object: NSAppleEventDescriptor, from player: ScriptablePlayer) -> NSAppleEventDescriptor? {
        send(AEEventID(kAEGetData), object, value: nil, to: player)
    }

    private func set(_ object: NSAppleEventDescriptor, to value: NSAppleEventDescriptor, in player: ScriptablePlayer) {
        _ = send(AEEventID(kAESetData), object, value: value, to: player)
    }

    /// Sends a core-suite event and returns the reply's result; nil on any
    /// error. Addressed by process, so it never launches a player that
    /// isn't running.
    private func send(_ id: AEEventID, _ object: NSAppleEventDescriptor, value: NSAppleEventDescriptor?,
                      to player: ScriptablePlayer) -> NSAppleEventDescriptor? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).first else { return nil }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: id,
                                           targetDescriptor: NSAppleEventDescriptor(processIdentifier: app.processIdentifier),
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(object, forKeyword: keyDirectObject)
        if let value { event.setParam(value, forKeyword: AEKeyword(keyAEData)) }
        guard let reply = try? event.sendEvent(options: [.waitForReply, .canInteract], timeout: Self.timeout) else { return nil }
        if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 { return nil }
        return reply.paramDescriptor(forKeyword: keyDirectObject)
    }

    /// A player that doesn't answer shouldn't hold the queue for long.
    private static let timeout: TimeInterval = 3
}

private func fourCharCode(_ string: String) -> FourCharCode {
    string.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
}
