# cozyplay 🎉🔊

Turn every MacBook in the room into one big, **synchronized** speaker system. One
laptop hosts the party; the others become extra speakers, and whatever plays on the
host — Spotify, YouTube, anything — plays on all of them at once, in sync.

cozyplay is a native macOS app with its **own in-process sync engine** — pure Swift on
Apple frameworks (Network.framework, AVFoundation/Core Audio, Accelerate). No helper
binaries, no third-party audio driver, no GPL dependencies. It captures the host's
system audio with the Core Audio process-tap API, streams timestamped PCM over the
LAN, and every speaker (the host included) plays it against a shared clock with a
drift-correcting servo. Target skew: **under 5 ms** (humans can't detect less);
end-to-end delay is a tunable buffer, **150 ms by default** — tight enough that video
is watchable, and far below the ~400 ms floor of the Snapcast-based design this
replaced.

> **Status: native engine milestones M-0…M-4 implemented.** Clock sync, streaming,
> the drift servo, host self-playback, and the control channel are built with 31
> passing unit tests. The remaining work is two-Mac field validation (skew
> measurement, WiFi-chaos testing) and servo tuning.

## How it works

```
 HOST                                                          COMPANION(S)
 system audio ─▶ Core Audio tap ─▶ S16LE @48k ─▶ AudioServer ──▶ TCP ──▶ StreamClient
                      │              (20ms chunks stamped        │            │
                now-playing meter     "play at host-time T")     │       SyncClock (NTP-style
                                          │                      │        offset, ±1ms)
                                          ▼                      │            ▼
                                   local PlaybackEngine ◀────────┘      PlaybackEngine
                                   (host's own speakers,           (timeline ring buffer +
                                    same delayed timeline)          drift servo → speakers)
 Bonjour: the AudioServer listener advertises _cozyplay._tcp; companions browse & connect
```

- **One clock.** All chunks carry play-at timestamps in the host's uptime clock.
  Each companion measures its offset to the host with NTP-style pings (min-RTT
  filtered, median-of-best; ~0.3–1 ms accuracy on party WiFi).
- **One timeline.** Chunks land in a position-addressed ring buffer; the render
  callback compares "where the DAC is" (host time + measured output latency) with
  what it's playing and corrects drift by micro-resampling (±2000 ppm — inaudible).
  Missing data plays as silence and recovers at the right instant automatically.
- **The host is just another speaker.** The tap mutes the original output and the
  host plays the same delayed timeline through an in-process client, so every
  laptop — host included — is aligned.

## Requirements

- macOS 14.4+ (process-tap API floor), Apple Silicon
- Xcode 26+, [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Quick start (local development)

```bash
xcodegen generate
open cozyplay.xcodeproj
```

In Xcode, set your Signing Team on the `cozyplay` target (System Audio capture needs a
**stable signing identity** — an ad-hoc build never gets the permission prompt), then
Run. Pick **Host a party** on one Mac and **Join a party** on another on the same
Wi-Fi.

Run the tests with `xcodebuild -scheme cozyplay test` (or ⌘U).

### Field-measuring clock sync (no audio needed)

```bash
# On the host Mac:
COZYPLAY_CLOCKSPIKE=host ./cozyplay.app/Contents/MacOS/cozyplay
# On the other Mac:
COZYPLAY_CLOCKSPIKE=client COZYPLAY_SPIKE_HOST=<host-ip> ./cozyplay.app/Contents/MacOS/cozyplay
```

The client prints offset/RTT once a second; wander should stay within ±1 ms over
10+ minutes, even while a big file copy saturates the network.

## Building a shareable .app

```bash
xcodebuild -project cozyplay.xcodeproj -scheme cozyplay -configuration Debug build
scripts/sign-for-sharing.sh     # ad-hoc by default; pass CODESIGN_IDENTITY for Developer ID
```

The app is a single Mach-O — no nested helpers or dylibs to re-sign, and nothing to
trip notarization.

## Project layout

| Path | What |
|------|------|
| `Sources/App` | App entry, role state |
| `Sources/Views` | SwiftUI screens (role picker, host grid, join, speaker tile) |
| `Sources/Controllers` | `HostController` / `JoinController` orchestration |
| `Sources/Audio` | Core Audio tap, PCM conversion, level meter |
| `Sources/Engine` | The sync engine: clock sync, wire protocol, host server, stream client, playback + drift servo, ring buffer |
| `Sources/Discovery` | Bonjour browse (the engine's listener advertises) |
| `Tests/` | Unit tests: protocol framing, clock-offset math, chunk/ring buffers |
| `Support/` | Info.plist, entitlements |
| `scripts/sign-for-sharing.sh` | re-sign a build so it runs on other Macs |
