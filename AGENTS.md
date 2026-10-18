- always run `make build` after every code change that would result in a new binary output. Do not worry about `make build` for documentation-only changes, github workflow updates, etc. You must ensure that the `make build` exit code is 0 before considering the work to be completed. The `build` target runs the linter (with `check-no-team` and the SwiftLint self-test), the unit tests, and the macOS and iPad simulator builds, so you don't need to run any other make commands to ensure the changes are not breaking.

- here are the general linter rules to know before you write/change code. try to adhere to these when making changes, and especially before running `make build` so you don't have to do rework because the linter reported violations that could have been avoided by following the basic rules from the start.
  - max 400 lines per file. check file line lengths and use multiple files to avoid linter violations.
  - max 120 characters per line. break up long lines
  - var/let names and struct field members should be at least 3 characters long (`id` and `url` are allowed)
  - function bodies should be < 150 lines, not counting comment lines
  - type bodies should be < 400 lines
  - cyclomatic complexity of 15 or less per function (`make lint` uses `--strict`, so the warning level fails)

- do not use the plus (+) character in filenames.

- Consolation 2.0 adds HDHomeRun live TV, playback of streams and video files, and a sidebar shell, with today's capture viewer as one sidebar item. The roadmap isn't kept in this repository; when a local `TODO.md` (gitignored) is in the repository root, it is the plan to follow.

- Consolation is multiplatform from one `Consolation` target: macOS 15.0 and iPadOS 18.0 today, for the final 1.x release. Consolation 2.0 raises these to macOS 26.0, iOS/iPadOS 26.0 and tvOS 27.0 and adds iPhone and Apple TV; until then there is no tvOS destination. Every change must compile for macOS and iPadOS (`make build` builds both SDKs). Prefer APIs that exist everywhere and use `#if os(...)` sparingly, keeping platform-specific code small and isolated (e.g. a per-platform file or view modifier) rather than scattered through shared code.

- the target uses Swift 6 with `MainActor` default isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency). Keep views and UI state on the main actor, in `@Observable` models (no `ObservableObject` or Combine). `AVCaptureSession` configuration, `startRunning()` and `stopRunning()` happen only on the `CaptureSessionBackend` actor, and sample buffers are handled on their delegate queues, so the UI never blocks. Other heavy work must be `nonisolated` and run in `@concurrent` functions (or their own actors).

- capture is the app's core, and some of its ordering is load-bearing:
  - Keep `CaptureVideoPreview` mounted even while idle. The preview layer must hold the session before `startRunning()`, or UVC devices fall back to about 25 fps.
  - Mute is enforced by not scheduling audio buffers, not by mixer volume, and persisted mute is applied before capture starts so the first samples stay silent.
  - On iPadOS, `AVAudioEngine` start, stop and attach run on the main thread.
  - Before a release, and after any change to capture, audio or the viewer, run the capture regression checklist on a Mac and an iPad: the capture cards listed as tested in `README.md`, the delivered frame rate (Video Stats overlay), audio latency and mute, hot-plugging the card, and rotate/mirror.

- never set a development team in `Consolation.xcodeproj/project.pbxproj` or a checked-in `.xcconfig`. Local builds use "Sign to Run Locally" and maintainers put their team in the untracked root `Local.xcconfig` (included by `Consolation/Version.xcconfig`). `make lint` (and so `make build` and every CI workflow) fails if a team is set. The release workflows (`.github/workflows/release-build.yml`) pass the team from the `APPLE_TEAM_ID` secret. Don't set MARKETING_VERSION or CURRENT_PROJECT_VERSION in the project file either; they live in `Consolation/Version.xcconfig`, which the release workflow rewrites.

- the macOS app is sandboxed. Its entitlements come from the target's `ENABLE_APP_SANDBOX`, `ENABLE_RESOURCE_ACCESS_CAMERA`, `ENABLE_RESOURCE_ACCESS_AUDIO_INPUT`, `ENABLE_USER_SELECTED_FILES` and `ENABLE_*_NETWORK_CONNECTIONS` build settings (there is no entitlements file yet). Add a capability only when a feature truly needs it. Prefer `INFOPLIST_KEY_*` build settings for Info.plist keys, and keep `Version.xcconfig` in the synchronized group's membership exceptions so it's never copied into the app bundle.

- privacy is a feature. Never add analytics, tracking, advertising, crash reporting or telemetry SDKs. Consolation 1.x makes no network connections at all (both network entitlements are off) and uses the camera and microphone only to show and play the capture card. Consolation 2.0 changes the promise to "connects only to the sources you add, and nothing until you add one"; any network feature must keep to that and update `PRIVACY.md` in the same change.

- UI tests live in `ConsolationUITests/` and use XCTest (Swift Testing can't drive `XCUIApplication`). They are not part of `make build`, because they launch and control the app on the active macOS desktop.

- running: `make run-macos` (or `make build-run-macos`), `make run-sim-ipad`, and `make run-device DEVICE="<name>"` for a paired iPad (it builds, installs and launches with the device console attached; `xcrun devicectl list devices` lists names; it needs your team in `Local.xcconfig`). Simulators have no capture devices, so they only check layout; capture needs a Mac or a real iPad with a card. All run targets take `ARGS=` and `TRACE=health|focus|all`, which sets `CONSOLATION_HEALTH_TRACE` / `CONSOLATION_FOCUS_TRACE` for the playback and focus traces planned for Consolation 2.0. Read the console to diagnose; don't guess.

- unit tests use Swift Testing (`import Testing`) in `ConsolationTests/`. They run on macOS inside the app (`make test`) and must not need the network, real capture devices or the user's media. Keep testable capture logic in pure helpers (for example `CaptureSessionManager.nextLowFrameRateSampleStreak`) rather than behind `AVCaptureDevice`.

- licensing: no GPL code. LGPL only as dynamically linked frameworks with full compliance (FFmpeg arrives with the playback packages in Consolation 2.0). Clean-room only where GPL or LGPL code shows the way; copy nothing.
