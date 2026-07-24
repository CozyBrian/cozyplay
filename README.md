# Cozyplay

Cozyplay turns Macs on the same local network into one synchronized speaker
system. One Mac hosts the party and captures whatever it is playing. Every other
Mac joins as a speaker, while the host also plays on the same delayed timeline.

The app is native SwiftUI and uses only Apple frameworks. There are no helper
binaries, third-party audio drivers, accounts, cloud services, or runtime
dependencies.

## Current status

The native playback engine, local discovery, host playback, companion playback,
speaker controls, diagnostics, and modern macOS interface are implemented. The
automated engine suite currently contains 39 passing tests.

Two-Mac field validation and further drift-servo tuning are still ongoing. Treat
this as working development software rather than a finished audio product.

## Features

- Captures system audio from the host using the Core Audio process-tap API.
- Streams timestamped 48 kHz S16LE PCM over the local network.
- Discovers nearby parties automatically with Bonjour.
- Synchronizes companions to the host with NTP-style clock measurements.
- Plays the host and companions against one shared, buffered timeline.
- Corrects long-running clock drift with subtle real-time resampling.
- Controls each speaker's name, volume, mute state, and sync trim.
- Exposes optional clock, buffer, and stream diagnostics.
- Follows the Mac's light or dark appearance.
- Uses native Liquid Glass on macOS 26 and a system-material fallback on older
  supported releases.

## How it works

```text
 HOST                                                          COMPANION(S)
 system audio -> Core Audio tap -> S16LE @ 48k -> AudioServer -- TCP -> StreamClient
                       |               20 ms timestamped chunks             |
                  level meter                    |                       SyncClock
                                                 v                          v
                                      local PlaybackEngine           PlaybackEngine
                                      same delayed timeline      timeline buffer + servo

 Bonjour: AudioServer advertises _cozyplay._tcp; companions browse and connect.
```

Every audio chunk carries a target time in the host's uptime clock. Companions
estimate their offset from that clock using minimum-RTT-filtered pings, then place
the chunks in a position-addressed ring buffer. The render engine compares its
playback position with the shared timeline and corrects small drift through
micro-resampling.

The original host output is normally muted. The host then renders the captured
stream through its own `PlaybackEngine`, making it another synchronized speaker
instead of playing ahead of the room.

The default end-to-end buffer is 150 ms and can be adjusted while hosting. The
design target is less than 5 ms of speaker-to-speaker skew, but real-world results
depend on hardware, output latency, and network conditions.

## Requirements

- macOS 14.4 or later
- Apple Silicon Mac
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

Install XcodeGen with Homebrew:

```bash
brew install xcodegen
```

## Build and run

Generate the Xcode project from `project.yml`:

```bash
xcodegen generate
open cozyplay.xcodeproj
```

In Xcode, select your development team for the `cozyplay` target and run the app.
A stable signing identity is required for macOS to retain the system-audio capture
permission correctly.

Choose **Host a party** on one Mac and **Find Nearby** on another Mac connected to
the same Wi-Fi network. Approve the system-audio and local-network permission
prompts when macOS presents them.

## Tests

```bash
xcodebuild \
  -project cozyplay.xcodeproj \
  -scheme cozyplay \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The tests cover protocol framing, clock synchronization, timestamp placement,
chunk assembly, and the timeline ring buffer without launching the app or
requesting system permissions.

## Clock-sync field measurement

The debug build includes a clock measurement mode that does not require audio:

```bash
# Host Mac
COZYPLAY_CLOCKSPIKE=host ./cozyplay.app/Contents/MacOS/cozyplay

# Companion Mac
COZYPLAY_CLOCKSPIKE=client \
COZYPLAY_SPIKE_HOST=<host-ip> \
./cozyplay.app/Contents/MacOS/cozyplay
```

The client logs its measured offset and round-trip time once per second.

## Shareable builds

Build the app, then create a separately signed copy:

```bash
xcodebuild \
  -project cozyplay.xcodeproj \
  -scheme cozyplay \
  -configuration Debug \
  build

scripts/sign-for-sharing.sh
```

The script uses ad-hoc signing by default. Pass a Developer ID identity through
`CODESIGN_IDENTITY` when preparing a stable host build:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
scripts/sign-for-sharing.sh
```

## Privacy and networking

Cozyplay communicates directly between Macs on the local network. It has no user
accounts, analytics, advertising, remote API, or cloud backend. Audio is streamed
to peers that explicitly join the advertised local party and is not written to
disk by the app.

The app is currently not sandboxed while the native audio engine is under active
development. Its entitlements and permission descriptions are available in
`Support/`.

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/App` | App entry point, settings, and top-level role state |
| `Sources/Views` | Native SwiftUI role, host, join, speaker, and settings views |
| `Sources/Controllers` | Host and companion orchestration |
| `Sources/Audio` | System capture, PCM conversion, and level metering |
| `Sources/Engine` | Protocol, clocks, buffering, server, client, and playback |
| `Sources/Discovery` | Bonjour party discovery |
| `Tests` | Headless engine and protocol tests |
| `Resources` | Application icon |
| `Support` | Info.plist and entitlements |
| `scripts` | Build and signing utilities |

`project.yml` is the source of truth for the generated Xcode project.
