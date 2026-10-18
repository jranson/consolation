#!/usr/bin/env bash
#
# Builds Consolation for a connected iPad, installs it and launches it with the device's console in this terminal
# (Ctrl-C to detach). Called by `make run-device`; needs your team in the untracked Local.xcconfig. Apple TV support
# arrives with the tvOS destination in Consolation 2.0.
#
#   DEVICE   a name or identifier from `xcrun devicectl list devices` (required)
#   TRACE    health, focus or all: sets CONSOLATION_HEALTH_TRACE and/or CONSOLATION_FOCUS_TRACE (for the playback
#            and focus traces planned for Consolation 2.0)
#   ARGS     any other launch arguments
set -euo pipefail

: "${DEVICE:?Set DEVICE to a name or identifier from: xcrun devicectl list devices}"
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
    iOS) products=Debug-iphoneos ;;
    *) echo "error: '$DEVICE' is a $platform device; Consolation runs on iPadOS devices (and macOS)" >&2; exit 1 ;;
esac

echo "Building for $DEVICE ($platform, $udid)"
xcodebuild -project Consolation.xcodeproj -scheme Consolation -configuration Debug -derivedDataPath build/DerivedData \
    -destination "id=$udid" -allowProvisioningUpdates build -quiet
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
# shellcheck disable=SC2206 # ARGS is split on spaces on purpose.
[ -n "${ARGS:-}" ] && arguments+=(${ARGS})

echo "Launching on $DEVICE; the console follows (Ctrl-C detaches and leaves Consolation running)"
# devicectl rejects an empty "{}", so the variables go only when there are some.
options=(--device "$udid" --console --terminate-existing)
[ -n "$environment" ] && options+=(--environment-variables "$environment")
xcrun devicectl device process launch "${options[@]}" org.centennialoss.consolation -- \
    "${arguments[@]+"${arguments[@]}"}"
