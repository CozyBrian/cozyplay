# cozyplay 🎉🔊

Turn every MacBook in the room into one big, **synchronized** speaker system. One
laptop hosts the party; the others become extra speakers, and whatever plays on the
host — Spotify, YouTube, anything — plays on all of them at once, in sync.

cozyplay is a native macOS app. It captures the host's system audio with the Core
Audio process-tap API (no BlackHole / kernel driver needed) and uses
[Snapcast](https://github.com/snapcast/snapcast) as the proven, sample-accurate sync
engine underneath (Snapcast holds sync to under 0.2 ms; humans can't detect skew
under ~5 ms).

> **Status: M0 skeleton.** The app, role flow, discovery, JSON-RPC control and the
> Core Audio capture pipeline are scaffolded and compile. The Snapcast helper
> binaries are not bundled yet — see Quick start.

## How it works

```
 MASTER                                                    COMPANION(S)
 system audio ─▶ Core Audio tap ─▶ FIFO ─▶ snapserver ─────▶ snapclient ─▶ speakers
                       │                    │ 1704 stream        (drift-corrected,
                 now-playing meter          │ 1705 JSON-RPC       played on schedule)
                                     local snapclient
                                   (host's own speakers)
 Bonjour: advertise _cozyplay._tcp  ◀── companions browse & connect
```

The master runs a **local snapclient** too, so its own speakers sit in the same synced
group as everyone else (at the cost of a uniform playback delay — the Snapcast buffer,
~400–600 ms on good Wi-Fi). See `../.claude/plans/` for the full design + rationale.

## Requirements

- macOS 14.4+ (built/tested on macOS 26, Apple Silicon)
- Xcode 26+, [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Quick start (local development)

```bash
# 1. Get the Snapcast engine for local testing (the app falls back to Homebrew).
brew install snapcast

# 2. Generate the Xcode project from project.yml and open it.
xcodegen generate
open cozyplay.xcodeproj
```

In Xcode, set your Signing Team on the `cozyplay` target (System Audio capture needs a
**stable signing identity** — an ad-hoc build never gets the permission prompt), then
Run. Pick **Host a party** on one Mac and **Join a party** on another on the same
Wi-Fi.

## Building a distributable .app

Bundle self-contained Snapcast helpers (build from source, relocate dylibs, re-sign):

```bash
xcodebuild -project cozyplay.xcodeproj -scheme cozyplay -configuration Release
scripts/build-snapcast.sh /path/to/built/cozyplay.app
# then re-sign + notarize the whole .app with your Developer ID
```

## Project layout

| Path | What |
|------|------|
| `Sources/App` | App entry, role state |
| `Sources/Views` | SwiftUI screens (role picker, host grid, join, speaker tile) |
| `Sources/Controllers` | `HostController` / `JoinController` orchestration |
| `Sources/Audio` | Core Audio tap, PCM conversion, FIFO writer, level meter |
| `Sources/Engine` | snapserver/snapclient process management + JSON-RPC |
| `Sources/Discovery` | Bonjour advertise/browse |
| `Support/` | Info.plist, entitlements |
| `scripts/build-snapcast.sh` | build + bundle the Snapcast helpers |

## Licensing note

Snapcast is **GPL-3.0**. cozyplay keeps it at arm's length (separate processes, IPC
over a FIFO + TCP), so the app's own code isn't a derivative work — but distributing
the bundled binaries carries GPL obligations (provide source / preserve notices). Do
not statically link or embed Snapcast code in-process. *Not legal advice.*
