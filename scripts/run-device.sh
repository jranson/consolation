#!/usr/bin/env bash
#
# Builds Consolation for a connected iPhone, iPad or Apple TV, installs it and launches it with the device's console
# in this terminal (Ctrl-C to detach). Called by `make run-device` (Debug) and `make run-release` (Release); needs
# your team in the untracked Local.xcconfig.
#
#   DEVICE         a name or identifier from `xcrun devicectl list devices` (required)
#   CONFIGURATION  Debug (the default) or Release
#   CHANNEL        a guide number to start playing, e.g. 9.1 (Debug only)
#   PANE           a pane to open: home, liveTV, quickPlay, library, nowPlaying, captureCard, settings (Debug only)
#   TRACE          health, focus or all: per-second playback health and/or Apple TV focus moves in the console
#   ARGS           any other launch arguments, e.g. "-ConsolationPlayURL https://example.com/stream.m3u8" (Debug only)
set -euo pipefail

: "${DEVICE:?Set DEVICE to a name or identifier from: xcrun devicectl list devices}"
configuration=${CONFIGURATION:-Debug}
case "$configuration" in
    Debug) ;;
    Release)
        if [ -n "${CHANNEL:-}${PANE:-}${ARGS:-}" ]; then
            echo "note: CHANNEL, PANE and ARGS are debug launch actions; a Release build ignores them" >&2
        fi
        ;;
    *) echo "error: CONFIGURATION must be Debug or Release" >&2; exit 1 ;;
esac
if [ ! -f Local.xcconfig ] || ! grep -q '^DEVELOPMENT_TEAM' Local.xcconfig; then
    echo "error: device builds need your team in Local.xcconfig (DEVELOPMENT_TEAM = <team ID>). See README.md." >&2
    exit 1
fi

json=$(mktemp)
trap 'rm -f "$json"' EXIT
xcrun devicectl list devices --json-output "$json" >/dev/null
match=$(python3 -I scripts/find-device.py "$json" "$DEVICE")
udid=${match%% *}
platform=${match#* }
if [ -z "${udid:-}" ]; then
    echo "error: no connected physical device named '$DEVICE'. See: xcrun devicectl list devices" >&2
    exit 1
fi
case "$platform" in
    iOS) products=$configuration-iphoneos ;;
    tvOS) products=$configuration-appletvos ;;
    *) echo "error: '$DEVICE' is a $platform device; Consolation runs on iOS, iPadOS and tvOS devices" >&2; exit 1 ;;
esac

echo "Building $configuration for $DEVICE ($platform, $udid)"
xcodebuild -project Consolation.xcodeproj -scheme Consolation -configuration "$configuration" \
    -derivedDataPath build/DerivedData -destination "id=$udid" -allowProvisioningUpdates build -quiet
xcrun devicectl device install app --device "$udid" "build/DerivedData/Build/Products/$products/Consolation.app" \
    >/dev/null

environment=""
case "${TRACE:-}" in
    "") ;;
    health) environment='{"CONSOLATION_HEALTH_TRACE":"1"}' ;;
    focus) environment='{"CONSOLATION_FOCUS_TRACE":"1"}' ;;
    all) environment='{"CONSOLATION_HEALTH_TRACE":"1","CONSOLATION_FOCUS_TRACE":"1"}' ;;
    *) echo "error: TRACE must be health, focus or all" >&2; exit 1 ;;
esac
arguments=()
[ -n "${CHANNEL:-}" ] && arguments+=(-ConsolationPlayChannel "$CHANNEL")
[ -n "${PANE:-}" ] && arguments+=(-ConsolationPane "$PANE")
# shellcheck disable=SC2206 # ARGS is split on spaces on purpose.
[ -n "${ARGS:-}" ] && arguments+=(${ARGS})

echo "Launching on $DEVICE; the console follows (Ctrl-C detaches and leaves Consolation running)"
# devicectl rejects an empty "{}", so the variables go only when there are some.
options=(--device "$udid" --console --terminate-existing)
[ -n "$environment" ] && options+=(--environment-variables "$environment")
xcrun devicectl device process launch "${options[@]}" org.centennialoss.consolation -- \
    "${arguments[@]+"${arguments[@]}"}"
