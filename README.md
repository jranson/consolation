# <img src="assets/app-icon.png" alt="Consolation" height="48" /> Consolation™ [<img align="right" src="assets/download-app-store.svg" />](https://apps.apple.com/us/app/consolation/id1563856788)

A no-frills video capture viewer for macOS and iPadOS.

Consolation is [available in the App Store](https://apps.apple.com/us/app/consolation/id1563856788) or can be downloaded directly from [this project's releases](https://github.com/centennial-oss/consolation-apple/releases).

Consolation is also available for Android tablets ([GitHub](https://github.com/centennial-oss/consolation-android) | [Play Store](https://play.google.com/store/apps/details?id=org.centennialoss.consolation)), Windows ([GitHub](https://github.com/centennial-oss/consolation-windows) | [Microsoft Store](https://apps.microsoft.com/detail/9N96T6XGBFTF?hl=en-us&gl=US)) and Linux ([GitHub](https://github.com/centennial-oss/consolation-linux)).

## About

Consolation is a free app that enables your Mac or iPad to be used as a screen for devices like gaming consoles, Raspberry Pis, and even a Mac mini, via a standard USB Video Class (UVC) video capture card.

The app is intentionally simple: watch the live video in a window or full screen. No recording or saving, no streaming to the internet. Just plug and play, privately with no ads or tracking.

## Screenshots

<img src="assets/screenshots/01-ipad-start-screen.png" alt="iPad start screen" width="270" /> <img src="assets/screenshots/02-ipad-botw-1.png" alt="iPad Breath of the Wild gameplay" width="270" /> <img src="assets/screenshots/03-ipad-botw-lowfps-warning.png" alt="iPad low frame rate warning" width="270" />

<img src="assets/screenshots/04-ipad-ltz-zoom-4-3.png" alt="iPad zoomed gameplay" width="270" /> <img src="assets/screenshots/05-macos-switch.png" alt="macOS Nintendo Switch capture" width="270" /> <img src="assets/screenshots/06-macos-botw-stats.png" alt="macOS capture stats" width="270" />

<img src="assets/screenshots/07-macos-menubar.png" alt="macOS menu bar" width="270" /> <img src="assets/screenshots/08-macos-rpi.png" alt="macOS Raspberry Pi capture" width="270" /> <img src="assets/screenshots/09-macos-smash.png" alt="macOS Smash Bros capture" width="270" />

## Privacy

Consolation does not collect, send, or share your data. Audio and video from a capture card stay local and transient, and the app never records, streams, saves, or analyzes them. The app is open source and contains no trackers or analytics. It makes no network connections until you add a source (such as a TV tuner) or play a stream URL, and then connects only to the tuners, servers and URLs you choose; with only a capture card, it makes no network connections at all.

Read the full privacy policy at [PRIVACY.md](PRIVACY.md) or <https://centennialoss.org/privacy/>.

## Supported Capture Devices

Any capture device that appears to the system through AVFoundation as a USB Video Class (UVC) capture devices should work with Consolation.

Consolation has been tested by the developers on Intel and Apple Silicon Macs and iPad Pro with these capture devices:

- Elgato HD60 X - 👌 🚀
- Acer USB 3.0 Video Capture Card (model OCB5B0) - 👌 🚀
- WANKEDA 4K Capture Card 1080p 60FPS for Streaming (1da603d4) - 👌 🚀
- blueAVS 4K Capture Card (A3-B) - 👌 🚀
- Guermok Video Capture Card (GM-29A) - 👌 🚀
- PERESAL USB 3.0 Video Capture Card with PD 100W - 👌 🚀
- UGREEN Full HD 1080p Capture Card (model 40189) -  ⚠️ max 30p @ 1920x1080

## Requirements

### Running

- A Mac running macOS 26 or later (Apple silicon, or an Intel Mac that runs macOS 26)
- An iPhone or iPad running iOS or iPadOS 26 or later
- An Apple TV 4K (2nd generation or later) running tvOS 27 or later
- For the Capture Card viewer: a UVC-compliant video capture card, on a Mac or an iPad with a USB-C port

### Developer

- Xcode 27.0 or later, including Command Line Tools and the iOS and tvOS platforms
- SwiftLint (`brew install swiftlint`)
- nasm (`brew install nasm`), for the FFmpeg build's x86_64 slices

## Building

```bash
make build
```

The first build runs `make ffmpeg`, which downloads the pinned FFmpeg source release, checks its SHA-256 and builds a minimal LGPL-2.1 `libavcodec` and `libavutil` as xcframeworks into `Packages/PlaybackKit/Frameworks/` (a few minutes; later builds skip it until the script, the FFmpeg version or Xcode changes). Run `make ffmpeg` once before opening the project in Xcode on a fresh checkout.

`make build` lints, runs the package and app unit tests, and builds the macOS app (`build/Consolation.app`) plus iOS and tvOS simulator apps (`build/Consolation-iOS.app` and `build/Consolation-tvOS.app`). You can also open `Consolation.xcodeproj` in Xcode, choose the Consolation scheme and a destination, and run it (⌘R).

### Running and testing on each platform

| Platform | Command |
|---|---|
| Mac | `make run-macos` opens the app built by `make build` (`make build-run-macos` builds first) |
| iPhone or iPad simulator | `make run-sim-iphone` or `make run-sim-ipad` builds, boots the simulator and launches. Simulators have no capture devices, so the Capture Card pane only checks layout |
| Apple TV simulator | `make run-sim-tv` |
| A real iPhone, iPad or Apple TV | `make run-device DEVICE="<name>"` builds for the device, installs, launches and shows its console in your terminal. It needs your team in `Local.xcconfig` (below), and the device paired with Xcode and in Developer Mode; `xcrun devicectl list devices` lists names. `make run-release DEVICE="<name>"` does the same with an optimized Release build |

Every run target takes the same launch options:
- `CHANNEL=9.1` starts playing a channel.
- `PANE=liveTV` opens a pane: `home`, `liveTV`, `quickPlay`, `library`, `nowPlaying`, `captureCard` or `settings`.
- `TRACE=health`, `focus` or `all` turns on diagnostics: `health` logs playback health each second, `focus` logs every Apple TV focus move.
- `ARGS="..."` adds any other launch arguments from `Consolation/Debug/DebugLaunchActions.swift`.

`CHANNEL`, `PANE` and `ARGS` are debug launch actions, so `make run-release` takes only `TRACE`.

In Xcode, set `CONSOLATION_HEALTH_TRACE=1` or `CONSOLATION_FOCUS_TRACE=1` under the scheme's environment variables instead.

`make test-ui-tvos` runs the Apple TV UI tests in the tvOS simulator. They press Siri Remote buttons to move through the sidebar and into each pane and back (a few minutes; not part of `make build`). The UI tests live in `ConsolationUITests/` and use XCTest, because Swift Testing can't drive `XCUIApplication`.

The project doesn't set a development team, so Xcode signs local builds with "Sign to Run Locally" and you don't need an Apple developer account to contribute. If you'd rather sign with your own team (for example, so macOS remembers Consolation's camera and microphone permissions between builds), create an untracked `Local.xcconfig` in the repository root:

```
DEVELOPMENT_TEAM = YOURTEAMID
```

With that file in place, `make build` signs the macOS app with your team too (Xcode must be signed in to that team's account so it can create a development certificate).

Please don't set a team in Xcode's Signing & Capabilities tab, because that writes it into the project file. `make lint` fails if the project file or a checked-in `.xcconfig` names a team.

## Tech Stack

- SwiftUI
- Swift 6 concurrency
- AVFoundation and AVKit
- AppKit and UIKit
- Local Swift packages under `Packages/` (tuners, playback, sources, the player) and [EtagereKit](https://github.com/centennial-oss/EtagereKit)
- FFmpeg's `libavcodec` and `libavutil` (LGPL-2.1, dynamically linked) for MPEG-2 video

## Contributor Disclosure

Humans write this software with AI assistance. All contributions are well-tested and merged only after being reviewed and approved by humans who fully understand and take responsibility for the contribution.

While we welcome pull requests and other contributions from other humans, including AI-generated code, we do not accept contributions from AI bots. A human must review, understand, and sign off on all commits. All contributors must be able to defend their contributions under reasonable technical scrutiny. Please file an issue to discuss any proposed feature before working on it.

## Trademark Notice

Consolation and its logo are trademarks of Centennial OSS Inc.
Use of the name and branding is not permitted for modified versions or forks without permission.
See [TRADEMARKS.md](TRADEMARKS.md) for details.
