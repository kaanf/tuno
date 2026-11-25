//
//  MockPlayer.swift
//  Tuno
//
//  Created by Kaan Firat.
//

#if DEBUG
import AppKit

/// A stand-in for the system Now Playing session, for looking at the notch
/// without touching a real player. Debug builds only:
///
///     Tuno --mock-player [scenario] [--mock-change-after <seconds>]
///
/// The scenario is one of `MockPlayer.Scenario`; the second argument moves
/// on to the next scenario once, after a delay, as a track change would.
/// The notch's right-click menu lists the scenarios and a peek.
final class MockPlayer {
    enum Scenario: String, CaseIterable {
        case normal
        case longTitle = "long-title"
        case noArtwork = "no-artwork"
        case paused

        var label: String {
            switch self {
            case .normal: return "Normal track"
            case .longTitle: return "Very long title"
            case .noArtwork: return "No artwork"
            case .paused: return "Paused"
            }
        }

        var reading: NowPlaying {
            var reading = NowPlaying(title: "Midnight Drive", artist: "The Placeholders", album: "Test Pressing",
                                     bundleIdentifier: MockPlayer.bundleIdentifier, isPlaying: true, duration: 215,
                                     elapsed: 72, sampledAt: Date(), rate: 1,
                                     artwork: MockPlayer.artwork(.systemOrange, .systemPink))
            switch self {
            case .normal:
                break
            case .longTitle:
                reading.title = "A Very Long Song Title That Keeps Going Well Past the Edge of the Notch (2011 Remaster, Live)"
                reading.artist = "An Artist With an Equally Unreasonable Name and Friends"
                reading.artwork = MockPlayer.artwork(.systemTeal, .systemIndigo)
            case .noArtwork:
                reading.title = "Untitled Demo"
                reading.artist = "Unknown Artist"
                reading.artwork = nil
            case .paused:
                reading.title = "Stillness"
                reading.artist = "The Placeholders"
                reading.isPlaying = false
                reading.artwork = MockPlayer.artwork(.systemGreen, .systemBlue)
            }
            return reading
        }
    }

    /// No such app, so nothing is scripted or opened on its behalf.
    static let bundleIdentifier = "com.kaanfirat.tuno.mock"

    private(set) var scenario: Scenario
    private let changeAfter: TimeInterval?
    private var reading: NowPlaying
    private var deliver: ((NowPlaying?) -> Void)?

    /// Nil unless the arguments ask for the mock.
    init?(arguments: [String] = CommandLine.arguments) {
        guard let flag = arguments.firstIndex(of: "--mock-player") else { return nil }
        let name = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
        scenario = Scenario(rawValue: name) ?? .normal
        reading = scenario.reading
        if let after = arguments.firstIndex(of: "--mock-change-after"), arguments.indices.contains(after + 1) {
            changeAfter = TimeInterval(arguments[after + 1])
        } else {
            changeAfter = nil
        }
    }

    /// Starts handing readings to `deliver`, on the main queue.
    func start(deliver: @escaping (NowPlaying?) -> Void) {
        self.deliver = deliver
        deliver(reading)
        if let changeAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + changeAfter) { [weak self] in self?.step(by: 1) }
        }
    }

    /// Switches track, as the player would on its own.
    func play(_ scenario: Scenario) {
        self.scenario = scenario
        reading = scenario.reading
        deliver?(reading)
    }

    /// What the transport buttons do to the mock instead of a real player.
    func press(_ key: MediaKeys.Key) {
        switch key {
        case .playPause:
            reading.elapsed = reading.position()
            reading.sampledAt = Date()
            reading.isPlaying.toggle()
            deliver?(reading)
        case .next: step(by: 1)
        case .previous: step(by: -1)
        }
    }

    func redeliver() {
        deliver?(reading)
    }

    private func step(by offset: Int) {
        let all = Scenario.allCases
        let index = all.firstIndex(of: scenario) ?? 0
        play(all[(index + offset + all.count) % all.count])
    }

    /// A two-colour diagonal gradient, so each scenario has its own tint.
    private static func artwork(_ first: NSColor, _ second: NSColor) -> NSImage {
        let size = NSSize(width: 300, height: 300)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: first, ending: second)?.draw(in: rect, angle: -45)
            return true
        }
    }
}
#endif
