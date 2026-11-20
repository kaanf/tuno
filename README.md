# tuno

a little now playing player for macs with a notch.

it sits on both sides of the notch with the album art and a small waveform. hover over it and it opens into a player with the title, artist, progress and controls. move away and it tucks back in.

works with apple music, spotify, and anything playing in your browser (youtube, soundcloud and so on).

## what it does

- artwork on the left of the notch, a waveform in the artwork's colour on the right
- hover, click, or swipe down with two fingers to open the player
- swipe left or right on the notch to skip tracks
- when the song changes, the new title shows up under the notch for a few seconds
- for apple music and spotify you also get seeking (click or drag the progress bar), 10 second skips, shuffle and repeat, plus favourites in music
- ⌥⌘P opens and closes it from anywhere. you can change the shortcut in settings
- no notch? it draws one at the top of your screen

## building

there's no release yet, so for now you build it yourself:

```sh
./build.sh
open build/Tuno.app
```

you need macos 12 or later and the xcode command line tools. the liquid glass icon needs xcode 26, without it you get the regular icon.

the build signs with my developer certificate when it's on the machine, and falls back to ad-hoc signing otherwise. to use your own, run `IDENTITY="your cert name" ./build.sh`. with ad-hoc signing macos forgets the accessibility permission every time you rebuild, which gets old fast.

## permissions

- **accessibility**: play, pause and skip are sent as media key presses, which needs this
- **automation**: only for the apple music and spotify extras. macos asks the first time you open the player while one of them is playing

you can check both under settings › system.

## settings

right click the notch and choose settings, or open tuno again from finder or spotlight. there's no menu bar icon, so that's how you get in.

in there you can pick which apps tuno shows (safari, chrome, music, spotify, podcasts, everything else), whether it stays up when you pause, the shortcut, and launch at login.

## how it works

since macos 15.4 apple only lets its own apps read the now playing info. tuno gets around that by building a tiny library (`Sources/Bridge/TunoBridge.m`) and loading it into the system's `/usr/bin/perl`, which macos still trusts. the bridge stays running, listens for changes, and writes one line of json each time something changes, so nothing is polling.

play, pause and skip are sent the same way your keyboard's media keys are. seeking and the rest go through applescript, which is why they only work with music and spotify.

## project layout

```text
Sources/Bridge/TunoBridge.m            reads now playing through mediaremote
Resources/tuno-bridge.pl               loads the bridge into /usr/bin/perl
Sources/App/NowPlayingMonitor.swift    runs the bridge and parses what it sends
Sources/App/PlayerController.swift     filters, artwork, shortcut, settings
Sources/App/NotchCompanion.swift       the notch itself
Sources/App/PlayerScripting.swift      applescript for music and spotify
Sources/App/MediaKeys.swift            play, pause, next, previous
Resources/Icon/                        icon sources (svg + icon composer)
```

## privacy

everything stays on your mac. no accounts, no analytics, no network requests.

---

made by kaan firat
