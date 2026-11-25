//
//  NowPlayingMonitor.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit

/// Runs the MediaRemote bridge in stream mode and publishes each change.
///
/// The bridge is a long-lived `perl tuno-bridge.pl … tuno_stream` child that
/// prints a JSON line whenever the session changes; see TunoBridge.m for the
/// format. If it dies it is relaunched with backoff.
final class NowPlayingMonitor {
    /// Delivered on the main queue. `nil` means nothing is playing.
    var onChange: ((NowPlaying?) -> Void)?

    private(set) var current: NowPlaying?

    #if DEBUG
    /// Set before `start()` to read from the mock instead of the bridge.
    var mock: MockPlayer?
    #endif

    private let loaderURL: URL
    private let bridgeURL: URL

    // Main queue only.
    private var process: Process?
    private var requests: FileHandle?
    private var running = false
    private var retryDelay: TimeInterval = 1

    // `parseQueue` only.
    private let parseQueue = DispatchQueue(label: "com.kaanfirat.tuno.monitor")
    private var pending = Data()
    private var artwork: NSImage?

    init?(bundle: Bundle = .main) {
        guard let loader = bundle.url(forResource: "tuno-bridge", withExtension: "pl"),
              let bridge = bundle.url(forResource: "TunoBridge", withExtension: "dylib") else { return nil }
        loaderURL = loader
        bridgeURL = bridge
    }

    func start() {
        guard !running else { return }
        running = true
        #if DEBUG
        if let mock {
            return mock.start { [weak self] reading in
                self?.current = reading
                self?.onChange?(reading)
            }
        }
        #endif
        launch()
    }

    func stop() {
        running = false
        process?.terminate()
        process = nil
        requests = nil
    }

    /// Ask for a fresh reading now instead of waiting for the next change.
    func refresh() {
        #if DEBUG
        if let mock { return mock.redeliver() }
        #endif
        // Throws rather than crashing if the bridge has just exited, because
        // SIGPIPE is ignored (see main.swift).
        try? requests?.write(contentsOf: Data("refresh\n".utf8))
    }

    // MARK: - Process

    private func launch() {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = [loaderURL.path, bridgeURL.path, "tuno_stream"]

        let output = Pipe()
        let input = Pipe()
        child.standardOutput = output
        child.standardInput = input
        child.standardError = FileHandle.nullDevice

        parseQueue.async {
            self.pending.removeAll()
            self.artwork = nil
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.parseQueue.async { self.receive(data) }
        }
        child.terminationHandler = { [weak self] ended in
            output.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.bridgeExited(ended) }
        }

        do {
            try child.run()
        } catch {
            bridgeExited(child)
            return
        }
        process = child
        requests = input.fileHandleForWriting
    }

    private func bridgeExited(_ ended: Process) {
        guard process == nil || process === ended else { return }
        process = nil
        requests = nil
        guard running else { return }

        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.process == nil else { return }
            self.launch()
        }
    }

    // MARK: - Parsing

    private func receive(_ data: Data) {
        pending.append(data)
        while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<end]
            pending.removeSubrange(pending.startIndex...end)
            guard let object = try? JSONSerialization.jsonObject(with: line),
                  let fields = object as? [String: Any] else { continue }
            let reading = decode(fields)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.retryDelay = 1
                self.current = reading
                self.onChange?(reading)
            }
        }
    }

    private func decode(_ fields: [String: Any]) -> NowPlaying? {
        // Artwork bytes only come when the image changes; keep the last one
        // for as long as the bridge says there still is one.
        if fields["hasArtwork"] as? Bool != true {
            artwork = nil
        } else if let encoded = fields["artwork"] as? String, let bytes = Data(base64Encoded: encoded) {
            artwork = NSImage(data: bytes)
        }

        guard let title = fields["title"] as? String, !title.isEmpty else { return nil }
        let isPlaying = fields["playing"] as? Bool ?? false
        return NowPlaying(
            title: title,
            artist: fields["artist"] as? String,
            album: fields["album"] as? String,
            bundleIdentifier: fields["bundleIdentifier"] as? String,
            isPlaying: isPlaying,
            duration: fields["duration"] as? Double,
            elapsed: fields["elapsedTime"] as? Double,
            sampledAt: (fields["timestamp"] as? Double).map(Date.init(timeIntervalSince1970:)),
            rate: fields["playbackRate"] as? Double ?? (isPlaying ? 1 : 0),
            artwork: artwork
        )
    }
}
