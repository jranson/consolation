.PHONY: build build-ios build-macos build-release-unsigned build-run-macos build-tvos check-no-team \
	check-private-names clean clean-build clean-caches clean-ffmpeg clean-release ffmpeg generate-appicons \
	generate-build-info generate-test-fixtures lint lint-fix-safe lint-selftest reset-all reset-defaults reset-perms \
	run-device run-macos run-release run-sim-ipad run-sim-iphone run-sim-tv test test-packages test-ui-tvos

# SwiftLint: https://github.com/realm/SwiftLint - `brew install swiftlint`
SWIFTLINT ?= $(shell command -v swiftlint 2>/dev/null)

PROJECT := Consolation.xcodeproj
SCHEME := Consolation
APP_NAME := Consolation
APP_DIR := Consolation
BUNDLE_ID ?= org.centennialoss.consolation
DERIVED_DATA := build/DerivedData
DIST_DERIVED_DATA := dist/DerivedData
# Naming the architecture avoids xcodebuild's "multiple matching destinations" warning on Apple silicon.
MACOS_DESTINATION := platform=macOS,arch=$(shell uname -m)

# Builds that never sign: the unsigned release builds (CI signs releases itself).
NO_SIGNING := CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# The iOS and tvOS simulator apps sign to run locally (ad hoc, no team or certificate needed), so Xcode gives them
# their simulated entitlements. Without an application-identifier the simulator's Keychain refuses every item
# (-34018), and sources that keep a token there (Plex) can't be added.
SIM_SIGNING := CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO

# With an untracked Local.xcconfig that sets DEVELOPMENT_TEAM, build-macos signs the Debug app with that team, so
# macOS keeps Consolation's camera, microphone and local network permissions and its sandbox container between
# builds. Without one (contributors, CI), it builds unsigned.
LOCAL_XCCONFIG := Local.xcconfig
ifneq ($(wildcard $(LOCAL_XCCONFIG)),)
DEBUG_SIGNING := -allowProvisioningUpdates
else
DEBUG_SIGNING := $(NO_SIGNING)
endif

# Simulators for the run-sim targets. Override with any name from `xcrun simctl list devices available`,
# e.g. `make run-sim-ipad SIM_IPAD="iPad Air 13-inch (M4)"`. When several runtimes have a device with the same
# name, the newest runtime's device is used. Simulators have no capture devices, so Capture Card checks layout only.
SIM_IPHONE ?= iPhone 17
SIM_IPAD ?= iPad Pro 11-inch (M5)
SIM_TV ?= Apple TV 4K (3rd generation) (at 1080p)
IOS_SIM_APP := build/$(APP_NAME)-iOS.app
TVOS_SIM_APP := build/$(APP_NAME)-tvOS.app

APPICON_DIR := $(APP_DIR)/Assets.xcassets/AppIcon.appiconset
APPICON_SRC := $(APPICON_DIR)/AppIcon_1024.png
APPICON_SIZES := 16 32 64 128 256 512
APPICON_BG := assets/app-icon-background-large.png
APPICON_TRANSPARENT_SRC := assets/app-icon-large-transparent.png
APPICON_LARGE := assets/app-icon-large.png
APPICON_PREVIEW := assets/app-icon.png

# Build info: BuildInfo.generated.swift feeds the About screen. The checked-in copy says "localdev"; CI rewrites it.
# Override any value with environment variables, e.g.:
#   COMMIT=... DATE=... CONFIG=Release ARCH=universal make generate-build-info
BUILD_INFO := $(APP_DIR)/AppData/BuildInfo.generated.swift
COMMIT ?= $(shell git rev-parse HEAD 2>/dev/null || echo local)
DATE ?= $(shell date -u +"%Y-%m-%dT%H:%M:%S.000Z")
CONFIG ?= Debug
ARCH ?= arm64

# Override the version at build time (e.g. TAGVER=1.0.0 BUILDNUM=42 make build-release-unsigned). Writes
# Consolation/Version.xcconfig so the app shows this version in About and Info.plist.
TAGVER ?=
BUILDNUM ?= 1
VERSION_XCCONFIG := $(APP_DIR)/Version.xcconfig
COPYRIGHT := Copyright © 2026 Centennial OSS Inc.

# The project must not name a development team: contributors build with "Sign to Run Locally".
# Maintainers set their team in the untracked Local.xcconfig instead.
# Fails if the project file or a checked-in xcconfig sets one (Xcode's Signing & Capabilities tab adds both
# DEVELOPMENT_TEAM and DevelopmentTeam).
check-no-team:
	@found=0; \
	if grep -n -i -E 'development_?team' $(PROJECT)/project.pbxproj; then found=1; fi; \
	for f in $$(find . -name '*.xcconfig' -not -name Local.xcconfig -not -path './build/*' -not -path './dist/*' \
		-not -path './Packages/*/.build/*'); do \
		if grep -n -H -E '^[[:space:]]*DEVELOPMENT_TEAM' "$$f"; then found=1; fi; \
	done; \
	if [ $$found -ne 0 ]; then \
		echo "error: a development team is set above. Remove it, and put your team in Local.xcconfig instead" \
			"(see README.md)." >&2; \
		exit 1; \
	fi

# Names that must never appear in this public repository (private projects, internal hosts), one per line, in the
# untracked Local.private-names. Fails if a tracked file, or a new file not yet added, contains one (case-insensitive).
# Without the file (contributors, CI) there is nothing to check.
PRIVATE_NAMES := Local.private-names
check-private-names:
	@if [ -s $(PRIVATE_NAMES) ]; then \
		if git grep --untracked -I -n -i -F -f $(PRIVATE_NAMES) -- . ':!$(PRIVATE_NAMES)'; then \
			echo "error: the files above name something listed in $(PRIVATE_NAMES); remove it before committing." >&2; \
			exit 1; \
		fi; \
	fi

lint: check-no-team check-private-names lint-selftest
	@if [ -z "$(SWIFTLINT)" ]; then \
		echo "SwiftLint not found. Install with: brew install swiftlint" >&2; \
		exit 1; \
	fi
	@"$(SWIFTLINT)" lint --strict
	@cmp -s LICENSES/LGPL-2.1.txt Packages/PlaybackKit/Sources/PlaybackKit/Resources/LGPL-2.1.txt || \
		(echo "error: Packages/PlaybackKit/Sources/PlaybackKit/Resources/LGPL-2.1.txt must match LICENSES/LGPL-2.1.txt" >&2; \
		exit 1)

# The rules that keep every shelf to VideoCard still fire.
# SwiftLint runs with the project config on fixtures outside the paths `lint` reads: on GameBoxShelf.swift each rule
# must flag exactly the lines marked "expect: <rule>" (etagere_video_cards_only for explicit specializations,
# etagere_card_conformance for any other card type, which also covers inferred generics), and
# VideoShelfAllowed.swift must pass.
LINT_SELFTEST_DIR := scripts/lint-selftest
LINT_SELFTEST_RULES := etagere_video_cards_only etagere_card_conformance
lint-selftest:
	@if [ -z "$(SWIFTLINT)" ]; then \
		echo "SwiftLint not found. Install with: brew install swiftlint" >&2; \
		exit 1; \
	fi
	@fixture=$(LINT_SELFTEST_DIR)/GameBoxShelf.swift; \
	report=$$("$(SWIFTLINT)" lint --quiet --config .swiftlint.yml --reporter csv $$fixture); \
	for rule in $(LINT_SELFTEST_RULES); do \
		expected=$$(grep -n "// expect: $$rule"'$$' $$fixture | cut -d: -f1 | sort -n | tr '\n' ' '); \
		flagged=$$(printf '%s\n' "$$report" | grep ",$$rule"'$$' | cut -d, -f2 | sort -n | tr '\n' ' '); \
		if [ -z "$$expected" ] || [ "$$expected" != "$$flagged" ]; then \
			echo "error: lint self-test: $$rule should flag lines [ $$expected] of $$fixture," \
				"but flagged [ $$flagged]" >&2; \
			exit 1; \
		fi; \
	done
	@"$(SWIFTLINT)" lint --quiet --strict --config .swiftlint.yml $(LINT_SELFTEST_DIR)/VideoShelfAllowed.swift || \
		(echo "error: lint self-test: $(LINT_SELFTEST_DIR)/VideoShelfAllowed.swift must pass" >&2; exit 1)

# Autocorrect only low-risk rules (whitespace / file hygiene). Still review `git diff` and run tests.
# Optional: pass paths, e.g. `make lint-fix-safe FIX_PATHS="Consolation/ConsolationApp.swift"`
FIX_PATHS ?= Consolation ConsolationTests ConsolationUITests Packages
lint-fix-safe:
	@if [ -z "$(SWIFTLINT)" ]; then \
		echo "SwiftLint not found. Install with: brew install swiftlint" >&2; \
		exit 1; \
	fi
	@"$(SWIFTLINT)" lint --fix \
		--only-rule trailing_whitespace \
		--only-rule trailing_newline \
		--only-rule leading_whitespace \
		--only-rule trailing_semicolon \
		$(FIX_PATHS)

# Keeps build/ffmpeg-cache (the downloaded FFmpeg source tarball) and Packages/PlaybackKit/Frameworks (the built
# xcframeworks, rebuilt only when scripts/build-ffmpeg.sh, the FFmpeg version or Xcode changes).
clean: clean-build clean-caches clean-release

# Debug builds (build/) and the packages' .build folders.
clean-build:
	rm -rf Packages/*/.build
	@if [ -d build ]; then find build -mindepth 1 -maxdepth 1 ! -name ffmpeg-cache -exec rm -rf {} +; fi

# Xcode's own DerivedData folders for this checkout. Matched by the project path recorded in each folder, so other
# checkouts' caches are left alone.
XCODE_DERIVED_DATA := $(HOME)/Library/Developer/Xcode/DerivedData
XCODE_DERIVED_DATA_PREFIX := $(basename $(PROJECT))-
clean-caches:
	@for dir in "$(XCODE_DERIVED_DATA)"/$(XCODE_DERIVED_DATA_PREFIX)*; do \
		[ -f "$$dir/info.plist" ] || continue; \
		path=$$(/usr/libexec/PlistBuddy -c "Print :WorkspacePath" "$$dir/info.plist" 2>/dev/null); \
		if [ "$$path" = "$(CURDIR)/$(PROJECT)" ]; then echo "rm -rf $$dir"; rm -rf "$$dir"; fi; \
	done

# Release builds from build-release-unsigned (dist/).
clean-release:
	rm -rf dist

# Also forgets the FFmpeg build and its cached source; the next build downloads and rebuilds it.
clean-ffmpeg:
	rm -rf build/ffmpeg-cache build/ffmpeg-work Packages/PlaybackKit/Frameworks

# Minimal LGPL-2.1 FFmpeg (libavcodec + libavutil) as xcframeworks for PlaybackKit. A no-op when up to date.
# Needs nasm for the x86_64 slices (`brew install nasm`).
ffmpeg:
	@scripts/build-ffmpeg.sh

# Regenerates the synthetic decoder fixtures (needs the ffmpeg command-line tool; never broadcast content).
generate-test-fixtures:
	@scripts/make-test-fixtures.sh

# Lint, run unit tests, then build the Debug app for macOS, and for the iOS and tvOS simulators, into build/.
build: test build-macos build-ios build-tvos

build-macos: ffmpeg
	mkdir -p build
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED_DATA) \
		-destination '$(MACOS_DESTINATION)' build $(DEBUG_SIGNING)
	rm -rf "build/$(APP_NAME).app"
	cp -R "$(DERIVED_DATA)/Build/Products/Debug/$(APP_NAME).app" build/

# iPhone and iPad simulator app (signed to run locally: SIM_SIGNING).
build-ios: ffmpeg
	mkdir -p build
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED_DATA) \
		-destination 'generic/platform=iOS Simulator' build $(SIM_SIGNING)
	rm -rf "$(IOS_SIM_APP)"
	cp -R "$(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/$(APP_NAME).app" "$(IOS_SIM_APP)"

# Apple TV simulator app (signed to run locally, like the iPhone and iPad one).
build-tvos: ffmpeg
	mkdir -p build
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED_DATA) \
		-destination 'generic/platform=tvOS Simulator' build $(SIM_SIGNING)
	rm -rf "$(TVOS_SIM_APP)"
	cp -R "$(DERIVED_DATA)/Build/Products/Debug-appletvsimulator/$(APP_NAME).app" "$(TVOS_SIM_APP)"

# Launch options for the run targets: CHANNEL=9.1 starts playing a channel, PANE=liveTV opens a pane,
# TRACE=health|focus|all logs per-second playback health and/or Apple TV focus moves, ARGS="..." adds any other
# launch arguments (see Consolation/Debug/DebugLaunchActions.swift).
LAUNCH_ARGS := $(if $(CHANNEL),-ConsolationPlayChannel $(CHANNEL)) $(if $(PANE),-ConsolationPane $(PANE)) $(ARGS)
TRACE_VARS := $(if $(filter health all,$(TRACE)),CONSOLATION_HEALTH_TRACE=1) \
	$(if $(filter focus all,$(TRACE)),CONSOLATION_FOCUS_TRACE=1)

# Open the Debug app built by build-macos.
run-macos:
	open $(foreach var,$(TRACE_VARS),--env $(var)) "build/$(APP_NAME).app" $(if $(strip $(LAUNCH_ARGS)),--args $(LAUNCH_ARGS))

# Build the Debug app, then open it if the build succeeded.
build-run-macos: build-macos run-macos

# Build for a connected iPhone, iPad or Apple TV, install it and launch it with the device's console in this
# terminal. DEVICE=<name or identifier from `xcrun devicectl list devices`>, plus the launch options above. Needs
# your team in Local.xcconfig. run-release does the same with a Release build, where only TRACE applies (CHANNEL,
# PANE and ARGS are debug launch actions).
RUN_DEVICE := DEVICE="$(DEVICE)" CHANNEL="$(CHANNEL)" PANE="$(PANE)" TRACE="$(TRACE)" ARGS="$(ARGS)" \
	scripts/run-device.sh

run-device: ffmpeg
	@CONFIGURATION=Debug $(RUN_DEVICE)

run-release: ffmpeg
	@CONFIGURATION=Release $(RUN_DEVICE)

# Build the iOS simulator app, then boot the simulator, install the app and launch it.
run-sim-iphone: build-ios
	@$(call run_in_simulator,$(SIM_IPHONE))

run-sim-ipad: build-ios
	@$(call run_in_simulator,$(SIM_IPAD))

run-sim-tv: build-tvos
	@$(call run_in_simulator,$(SIM_TV),$(TVOS_SIM_APP))

# $(call run_in_simulator,<device name>[,<app>]): boot the newest-runtime simulator with that name (if it isn't
# already running), show it in Simulator.app when that's installed, then install and launch the app
# (build/Consolation-iOS.app unless another is given).
define run_in_simulator
	name='$(1)'; \
	udid=$$(xcrun simctl list devices available | grep -F "    $$name (" | tail -n 1 | \
		grep -o -E '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}'); \
	if [ -z "$$udid" ]; then \
		echo "error: no available simulator named '$$name'. See: xcrun simctl list devices available" >&2; \
		exit 1; \
	fi; \
	echo "Using $$name ($$udid)"; \
	xcrun simctl boot "$$udid" 2>/dev/null || true; \
	open -a Simulator --args -CurrentDeviceUDID "$$udid" 2>/dev/null || \
		echo "note: Simulator.app wasn't found, so the simulator runs without a window."; \
	xcrun simctl bootstatus "$$udid" -b >/dev/null && \
	xcrun simctl install "$$udid" "$(or $(2),$(IOS_SIM_APP))" && \
	$(foreach var,$(TRACE_VARS),SIMCTL_CHILD_$(var)) xcrun simctl launch "$$udid" $(BUNDLE_ID) $(LAUNCH_ARGS)
endef

# Unsigned Release builds into dist/: the universal macOS app plus iOS and tvOS device builds, to check that the
# Release configuration compiles. The signed App Store and Developer ID builds come from
# .github/workflows/release-build.yml.
build-release-unsigned: ffmpeg
	mkdir -p dist
	@if [ -n "$(TAGVER)" ]; then \
		printf 'MARKETING_VERSION = %s\nCURRENT_PROJECT_VERSION = %s\nINFOPLIST_KEY_NSHumanReadableCopyright = %s\n' \
			"$(TAGVER)" "$(BUILDNUM)" "$(COPYRIGHT)" > $(VERSION_XCCONFIG); \
		printf '\n// Optional, untracked per-developer settings, e.g. DEVELOPMENT_TEAM = <your team ID>. See README.md.\n#include? "../Local.xcconfig"\n' \
			>> $(VERSION_XCCONFIG); \
	fi
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DIST_DERIVED_DATA) \
		-destination 'generic/platform=macOS' build $(NO_SIGNING)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DIST_DERIVED_DATA) \
		-destination 'generic/platform=iOS' build $(NO_SIGNING)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DIST_DERIVED_DATA) \
		-destination 'generic/platform=tvOS' build $(NO_SIGNING)
	rm -rf "dist/$(APP_NAME).app" "dist/$(APP_NAME)-iOS.app" "dist/$(APP_NAME)-tvOS.app"
	cp -R "$(DIST_DERIVED_DATA)/Build/Products/Release/$(APP_NAME).app" dist/
	cp -R "$(DIST_DERIVED_DATA)/Build/Products/Release-iphoneos/$(APP_NAME).app" "dist/$(APP_NAME)-iOS.app"
	cp -R "$(DIST_DERIVED_DATA)/Build/Products/Release-appletvos/$(APP_NAME).app" "dist/$(APP_NAME)-tvOS.app"

generate-build-info:
	@printf '%s\n' \
		'// Generated by make generate-build-info.' \
		'// Do not edit this file by hand.' \
		'' \
		'enum BuildInfoGenerated {' \
		'    static let buildCommit = "$(COMMIT)"' \
		'    static let buildDate = "$(DATE)"' \
		'    static let buildConfiguration = "$(CONFIG)"' \
		'    static let buildArch = "$(ARCH)"' \
		'}' > $(BUILD_INFO)
	@echo "Wrote $(BUILD_INFO)"

# Local Swift packages under Packages/. Each runs its own `swift test`; they never touch the network or real devices.
PACKAGES := Packages/HTTPMPEG2Kit Packages/PlaybackKit Packages/MediaSourceKit Packages/PlayerKit

# Run unit tests on macOS (lint first). The test bundle runs inside the ad-hoc signed, sandboxed Debug app. UI tests
# are not part of this: the Apple TV suite runs with `make test-ui-tvos`.
test: lint ffmpeg test-packages
	mkdir -p build
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED_DATA) \
		-destination '$(MACOS_DESTINATION)' test -only-testing:ConsolationTests \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES

test-packages: ffmpeg
	@for pkg in $(PACKAGES); do \
		echo "swift test --package-path $$pkg"; \
		swift test --package-path $$pkg || exit 1; \
	done

# Apple TV focus and navigation, driven with the Siri Remote in the tvOS simulator (about 2 minutes; not part of
# `build`). Override the simulator with SIM_TV="<name>".
# Several simulators can share SIM_TV's name (one added in Xcode's Device Hub, another created earlier), and
# xcodebuild refuses an ambiguous name, so the device is picked by identifier: SIM_TV_ID if given, else the first
# booted simulator with that name, else the first available one.
test-ui-tvos: ffmpeg
	@id="$(SIM_TV_ID)"; \
	if [ -z "$$id" ]; then \
		matches=$$(xcrun simctl list devices available | grep -F "    $(SIM_TV) ("); \
		id=$$( (echo "$$matches" | grep "(Booted)"; echo "$$matches") | head -n 1 | \
			grep -o -E '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}'); \
	fi; \
	if [ -z "$$id" ]; then echo "error: no available simulator named '$(SIM_TV)'" >&2; exit 1; fi; \
	echo "Testing on $(SIM_TV) ($$id)"; \
	xcodebuild -project $(PROJECT) -scheme ConsolationUITests -configuration Debug -derivedDataPath $(DERIVED_DATA) \
		-destination "id=$$id" test $(NO_SIGNING)

# Generate app icon assets:
#   1. Composite assets/app-icon-large-transparent.png over assets/app-icon-background-large.png
#      -> assets/app-icon-large.png
#   2. Resize the composite into the AppIcon asset catalog for macOS and iOS.
#   3. Copy the generated 128x128 icon to assets/app-icon.png for docs/branding use.
generate-appicons:
	@test -f $(APPICON_BG) || (echo "Missing: $(APPICON_BG)" && exit 1)
	@test -f $(APPICON_TRANSPARENT_SRC) || (echo "Missing: $(APPICON_TRANSPARENT_SRC)" && exit 1)
	@echo "Compositing app-icon-large-transparent.png onto app-icon-background-large.png -> app-icon-large.png"
	@swift scripts/composite-app-icon.swift $(APPICON_BG) $(APPICON_TRANSPARENT_SRC) $(APPICON_LARGE)
	@cp $(APPICON_LARGE) $(APPICON_SRC)
	@for size in $(APPICON_SIZES); do \
		echo "Creating AppIcon_$$size.png from AppIcon_1024.png"; \
		if [ "$$size" = "16" ]; then \
			sips --cropToHeightWidth 780 780 $(APPICON_SRC) --out /tmp/AppIcon_crop.png && \
			sips -z 16 16 /tmp/AppIcon_crop.png --out $(APPICON_DIR)/AppIcon_16.png; \
		elif [ "$$size" = "32" ]; then \
			sips --cropToHeightWidth 880 880 $(APPICON_SRC) --out /tmp/AppIcon_crop.png && \
			sips -z 32 32 /tmp/AppIcon_crop.png --out $(APPICON_DIR)/AppIcon_32.png; \
		else \
			sips -z $$size $$size --out $(APPICON_DIR)/AppIcon_$$size.png $(APPICON_SRC); \
		fi; \
	done
	@cp $(APPICON_DIR)/AppIcon_128.png $(APPICON_PREVIEW)
	@rm -f /tmp/AppIcon_crop.png
	@echo "Done writing AppIcons and $(APPICON_PREVIEW)"

reset-perms:
	@tccutil reset Camera $(BUNDLE_ID)
	@tccutil reset Microphone $(BUNDLE_ID)

# Consolation is sandboxed on macOS, so its preferences and saved documents live in its container.
reset-defaults:
	@defaults delete $(BUNDLE_ID) 2>/dev/null || true
	@rm -f "$(HOME)/Library/Containers/$(BUNDLE_ID)/Data/Library/Preferences/$(BUNDLE_ID).plist"
	@rm -rf "$(HOME)/Library/Containers/$(BUNDLE_ID)/Data/Library/Application Support/$(BUNDLE_ID)"
	@echo "Reset UserDefaults and saved documents (sources, favorites, history) for $(BUNDLE_ID)"

reset-all: reset-perms reset-defaults
