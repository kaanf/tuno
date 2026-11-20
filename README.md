# Tuno

A macOS menu bar companion for whatever is playing: Apple Music, Spotify, or
a video in your browser.

> Early development. The bridge and playback controls work; the menu bar
> capsule, player popover, settings and notch companion from the design are
> next.

## How it works

macOS keeps one system-wide Now Playing session. Tuno reads it through the
private MediaRemote framework, which since macOS 15.4 only answers Apple's own
entitled processes. Tuno therefore builds a small bridge library
(`Sources/Bridge/TunoBridge.m`) and runs it inside the system's signed
`/usr/bin/perl` via `Resources/tuno-bridge.pl`.

The bridge runs as one long-lived child process. It listens for MediaRemote
change notifications and writes a JSON line for each change: title, artist,
album, player app, play state, duration, elapsed time and artwork. Tuno
calculates playback progress locally between updates, so nothing polls.

Playback control posts the same events as the keyboard's media keys. These go
to the app that owns the session and need Accessibility permission.

## Build

Requires macOS 12+ and the Xcode command line tools.

```sh
./build.sh
open build/Tuno.app
```

The build signs with the Apple Development certificate by default. Set
`IDENTITY="…"` to use another certificate, or `IDENTITY=-` for ad-hoc signing.
Ad-hoc builds lose the Accessibility permission each time you rebuild.

## Layout

```text
Sources/Bridge/TunoBridge.m          MediaRemote bridge (dylib)
Sources/App/NowPlaying.swift         one reading of the session
Sources/App/NowPlayingMonitor.swift  runs the bridge, parses its stream
Sources/App/MediaKeys.swift          play/pause, next, previous
Sources/App/StatusItemController.swift  menu bar item
Resources/tuno-bridge.pl             loads the bridge into /usr/bin/perl
```

## Privacy

Everything stays on your Mac. No accounts, analytics or network access.

---

© 2026 Kaan Firat
