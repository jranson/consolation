#!/usr/bin/env bash
#
# Builds the minimal LGPL-2.1 FFmpeg that PlaybackKit decodes MPEG-2 with: libavcodec and libavutil only, as
# dynamic frameworks combined into xcframeworks under Packages/PlaybackKit/Frameworks/ (gitignored).
#
#   scripts/build-ffmpeg.sh           # or `make ffmpeg`
#   FFMPEG_FORCE=1 scripts/build-ffmpeg.sh
#
# - Downloads the pinned upstream release tarball from ffmpeg.org into build/ffmpeg-cache/ (kept by `make clean`)
#   and checks it against the SHA-256 below. No patches: the source is exactly upstream.
# - Configures LGPL-2.1 only. Never add --enable-gpl, --enable-nonfree or --enable-version3; the script refuses.
# - Is a no-op when Packages/PlaybackKit/Frameworks/.ffmpeg-stamp matches this script, the FFmpeg version and the
#   Xcode version (CI caches that folder under the same key).
# - Rewrites ThirdParty/FFmpeg/CONFIGURATION.txt (committed): version, tarball SHA-256, configure lines, Xcode and
#   SDK versions, binary sizes.
#
# LGPL-2.1 compliance: NOTICE credits the libraries, and ThirdParty/FFmpeg/CONFIGURATION.txt records this build.

set -euo pipefail

FFMPEG_VERSION="9.0.2"
FFMPEG_SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"

MACOS_MIN="26.0"
IOS_MIN="26.0"
TVOS_MIN="27.0"

# The only components we build. `mp2` decodes MP2-audio channels on iOS and tvOS.
COMPONENTS=(
    --enable-decoder=mpeg2video
    --enable-decoder=mpeg1video
    --enable-decoder=mp2
    --enable-parser=mpegvideo
    --enable-parser=mpegaudio
)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/build-ffmpeg.sh"
CACHE_DIR="$ROOT/build/ffmpeg-cache"
WORK_DIR="$ROOT/build/ffmpeg-work"
OUT_DIR="$ROOT/Packages/PlaybackKit/Frameworks"
CONFIG_TXT="$ROOT/ThirdParty/FFmpeg/CONFIGURATION.txt"
STAMP="$OUT_DIR/.ffmpeg-stamp"
TARBALL="$CACHE_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz"
LIBS=(libavutil libavcodec)
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

log() { printf '[ffmpeg] %s\n' "$*"; }
die() { printf '[ffmpeg] error: %s\n' "$*" >&2; exit 1; }

# Slices: name, SDK, architectures, clang target suffix, minimum OS.
SLICES=(
    "macos|macosx|arm64 x86_64|macos|$MACOS_MIN"
    "ios|iphoneos|arm64|ios|$IOS_MIN"
    "ios-simulator|iphonesimulator|arm64 x86_64|ios-simulator|$IOS_MIN"
    "tvos|appletvos|arm64|tvos|$TVOS_MIN"
    "tvos-simulator|appletvsimulator|arm64 x86_64|tvos-simulator|$TVOS_MIN"
)

stamp_value() {
    {
        shasum -a 256 "$SCRIPT" | cut -d' ' -f1
        echo "$FFMPEG_VERSION $FFMPEG_SHA256"
        xcodebuild -version
    } | shasum -a 256 | cut -d' ' -f1
}

up_to_date() {
    [[ -z "${FFMPEG_FORCE:-}" ]] || return 1
    [[ -f "$STAMP" ]] || return 1
    for lib in "${LIBS[@]}"; do
        [[ -f "$OUT_DIR/$lib.xcframework/Info.plist" ]] || return 1
    done
    [[ "$(cat "$STAMP")" == "$(stamp_value)" ]]
}

fetch_source() {
    mkdir -p "$CACHE_DIR"
    if [[ -f "$TARBALL" ]] && [[ "$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)" == "$FFMPEG_SHA256" ]]; then
        log "using cached $(basename "$TARBALL")"
    else
        log "downloading $FFMPEG_URL"
        curl -fL --retry 3 --proto '=https' -o "$TARBALL.part" "$FFMPEG_URL"
        mv "$TARBALL.part" "$TARBALL"
    fi
    local actual
    actual="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
    if [[ "$actual" != "$FFMPEG_SHA256" ]]; then
        rm -f "$TARBALL"
        die "SHA-256 mismatch for $(basename "$TARBALL"): expected $FFMPEG_SHA256, got $actual"
    fi
    rm -rf "$WORK_DIR/src"
    mkdir -p "$WORK_DIR/src"
    tar -xJf "$TARBALL" -C "$WORK_DIR/src"
    SOURCE="$WORK_DIR/src/ffmpeg-${FFMPEG_VERSION}"
}

# configure_args <prefix> <sdk> <arch> <triple>: one slice's configure arguments, one per line.
configure_args() {
    local prefix="$1" sdk="$2" arch="$3" triple="$4"
    local asm=(--enable-asm)
    [[ "$arch" == "x86_64" ]] && asm+=(--x86asmexe=nasm)
    printf '%s\n' \
        --prefix="$prefix" --enable-cross-compile --target-os=darwin --arch="$arch" \
        --cc="xcrun -sdk $sdk clang -target $triple" \
        --sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)" \
        --extra-cflags="-target $triple -fno-common" --extra-ldflags="-target $triple -Wl,-dead_strip_dylibs" \
        --install-name-dir=@rpath \
        --enable-shared --disable-static --enable-pic --disable-debug --enable-optimizations "${asm[@]}" \
        --enable-pthreads \
        --disable-programs --disable-doc --disable-network --disable-autodetect --disable-everything \
        --disable-avformat --disable-avfilter --disable-avdevice --disable-swscale --disable-swresample \
        --enable-avcodec --enable-avutil \
        "${COMPONENTS[@]}"
}

build_arch() {
    local slice="$1" sdk="$2" arch="$3" suffix="$4" minimum="$5"
    local triple="${arch}-apple-${suffix%%-*}${minimum}"
    [[ "$suffix" == *-simulator ]] && triple="${triple}-simulator"
    local build="$WORK_DIR/obj/$slice-$arch" prefix="$WORK_DIR/install/$slice-$arch"
    rm -rf "$build" "$prefix"
    mkdir -p "$build"
    local args=()
    while IFS= read -r line; do args+=("$line"); done < <(configure_args "$prefix" "$sdk" "$arch" "$triple")
    for arg in "${args[@]}"; do
        case "$arg" in
            --enable-gpl|--enable-nonfree|--enable-version3) die "refusing $arg: Consolation ships LGPL-2.1 only" ;;
        esac
    done
    log "configure $slice $arch ($triple)"
    (cd "$build" && "$SOURCE/configure" "${args[@]}" >configure.out 2>&1) \
        || { tail -n 40 "$build/configure.out" "$build/ffbuild/config.log" 2>/dev/null; die "configure failed"; }
    grep -q '^License: LGPL version 2.1 or later' "$build/configure.out" \
        || die "configure did not report LGPL version 2.1 or later for $slice $arch"
    log "make $slice $arch"
    make -C "$build" -j"$JOBS" >"$build/make.out" 2>&1 || { tail -n 40 "$build/make.out"; die "make failed"; }
    make -C "$build" install >>"$build/make.out" 2>&1 || { tail -n 40 "$build/make.out"; die "install failed"; }
    local sysroot
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    {
        echo "# $slice $arch"
        printf '%s' "$SOURCE/configure"
        for arg in "${args[@]}"; do printf " \\\\\n    '%s'" "$arg"; done
        printf '\n\n'
    } | sed -e "s|$WORK_DIR|<work>|g" -e "s|$sysroot|\$(xcrun --sdk $sdk --show-sdk-path)|g" \
        >>"$WORK_DIR/configure-lines.txt"
}

lib_version() {
    sed -n 's/^Version: //p' "$1/lib/pkgconfig/$2.pc"
}

write_info_plist() {
    local path="$1" lib="$2" version="$3" platform="$4" minimum="$5"
    local minimum_key="MinimumOSVersion"
    [[ "$platform" == "MacOSX" ]] && minimum_key="LSMinimumSystemVersion"
    cat >"$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$lib</string>
    <key>CFBundleIdentifier</key><string>org.centennialoss.thirdparty.$lib</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$lib</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
    <key>$minimum_key</key><string>$minimum</string>
    <key>NSHumanReadableCopyright</key><string>FFmpeg $FFMPEG_VERSION, LGPL version 2.1 or later</string>
</dict>
</plist>
PLIST
}

# make_framework <slice> <sdk> <minimum> <archs...>: lipo the slice's architectures into framework bundles.
make_framework() {
    local slice="$1" sdk="$2" minimum="$3"
    shift 3
    local archs=("$@") first="$WORK_DIR/install/$slice-$1"
    local platform
    case "$sdk" in
        macosx) platform="MacOSX" ;; iphoneos) platform="iPhoneOS" ;; iphonesimulator) platform="iPhoneSimulator" ;;
        appletvos) platform="AppleTVOS" ;; appletvsimulator) platform="AppleTVSimulator" ;;
    esac
    for lib in "${LIBS[@]}"; do
        local fw="$WORK_DIR/frameworks/$slice/$lib.framework" version binary install_name
        version="$(lib_version "$first" "$lib")"
        rm -rf "$fw"
        if [[ "$sdk" == "macosx" ]]; then
            # macOS frameworks must be versioned bundles, or codesign rejects them.
            mkdir -p "$fw/Versions/A/Resources" "$fw/Versions/A/Headers"
            binary="$fw/Versions/A/$lib"
            install_name="@rpath/$lib.framework/Versions/A/$lib"
            write_info_plist "$fw/Versions/A/Resources/Info.plist" "$lib" "$version" "$platform" "$minimum"
            cp -R "$first/include/$lib/." "$fw/Versions/A/Headers/"
            ln -s A "$fw/Versions/Current"
            ln -s "Versions/Current/$lib" "$fw/$lib"
            ln -s Versions/Current/Headers "$fw/Headers"
            ln -s Versions/Current/Resources "$fw/Resources"
        else
            mkdir -p "$fw/Headers"
            binary="$fw/$lib"
            install_name="@rpath/$lib.framework/$lib"
            write_info_plist "$fw/Info.plist" "$lib" "$version" "$platform" "$minimum"
            cp -R "$first/include/$lib/." "$fw/Headers/"
        fi
        local inputs=()
        for arch in "${archs[@]}"; do
            local dylib
            dylib="$(find "$WORK_DIR/install/$slice-$arch/lib" -maxdepth 1 -type f -name "$lib.*.dylib" | head -n 1)"
            [[ -n "$dylib" ]] || die "no $lib dylib for $slice $arch"
            inputs+=("$dylib")
        done
        lipo -create "${inputs[@]}" -output "$binary"
        strip -x "$binary" 2>/dev/null || true
        install_name_tool -id "$install_name" "$binary" 2>/dev/null
        local dep
        for dep in $(otool -L "$binary" | awk '/@rpath\/libav/ {print $1}'); do
            local name="${dep#@rpath/}"
            name="${name%%.*}"
            if [[ "$sdk" == "macosx" ]]; then
                install_name_tool -change "$dep" "@rpath/$name.framework/Versions/A/$name" "$binary" 2>/dev/null
            else
                install_name_tool -change "$dep" "@rpath/$name.framework/$name" "$binary" 2>/dev/null
            fi
        done
        codesign --force --sign - --timestamp=none "$fw" >/dev/null 2>&1 || die "ad-hoc signing $fw failed"
    done
}

write_configuration() {
    mkdir -p "$(dirname "$CONFIG_TXT")"
    {
        echo "FFmpeg build used by PlaybackKit (generated by scripts/build-ffmpeg.sh; do not edit by hand)"
        echo
        echo "Version:        FFmpeg $FFMPEG_VERSION"
        echo "Source:         $FFMPEG_URL"
        echo "SHA-256:        $FFMPEG_SHA256"
        echo "Signature:      $FFMPEG_URL.asc (FFmpeg release signing key)"
        echo "Patches:        none (exact upstream source)"
        echo "Licence:        LGPL version 2.1 or later (no --enable-gpl, --enable-nonfree or --enable-version3)"
        echo "Libraries:      libavcodec $(lib_version "$WORK_DIR/install/macos-arm64" libavcodec)," \
            "libavutil $(lib_version "$WORK_DIR/install/macos-arm64" libavutil)"
        echo "Components:     ${COMPONENTS[*]}"
        echo "Xcode:          $(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')"
        for sdk in macosx iphoneos iphonesimulator appletvos appletvsimulator; do
            printf 'SDK:            %s %s\n' "$sdk" "$(xcrun --sdk "$sdk" --show-sdk-version)"
        done
        echo "Rebuild:        make ffmpeg (or FFMPEG_FORCE=1 scripts/build-ffmpeg.sh)"
        echo
        echo "Binary sizes (bytes, stripped, all architectures of the slice):"
        for entry in "${SLICES[@]}"; do
            IFS='|' read -r slice _ archs _ _ <<<"$entry"
            for lib in "${LIBS[@]}"; do
                local fw="$WORK_DIR/frameworks/$slice/$lib.framework"
                local binary="$fw/$lib"
                [[ -L "$binary" ]] && binary="$fw/Versions/A/$lib"
                printf '  %-15s %-11s %-13s %9s\n' "$slice" "$lib" "($archs)" "$(stat -f %z "$binary")"
            done
        done
        echo
        echo "Configure lines (<work> is build/ffmpeg-work in the repository):"
        echo
        cat "$WORK_DIR/configure-lines.txt"
    } >"$CONFIG_TXT"
}

main() {
    command -v xcodebuild >/dev/null || die "xcodebuild not found"
    command -v nasm >/dev/null || die "nasm not found (brew install nasm); the x86_64 slices need it"
    if up_to_date; then
        log "FFmpeg $FFMPEG_VERSION frameworks are up to date"
        exit 0
    fi
    fetch_source
    rm -rf "$WORK_DIR/obj" "$WORK_DIR/install" "$WORK_DIR/frameworks" "$WORK_DIR/configure-lines.txt"
    for entry in "${SLICES[@]}"; do
        IFS='|' read -r slice sdk archs suffix minimum <<<"$entry"
        for arch in $archs; do build_arch "$slice" "$sdk" "$arch" "$suffix" "$minimum"; done
        # shellcheck disable=SC2086
        make_framework "$slice" "$sdk" "$minimum" $archs
    done
    rm -rf "$OUT_DIR"
    mkdir -p "$OUT_DIR"
    for lib in "${LIBS[@]}"; do
        local args=()
        for entry in "${SLICES[@]}"; do
            IFS='|' read -r slice _ _ _ _ <<<"$entry"
            args+=(-framework "$WORK_DIR/frameworks/$slice/$lib.framework")
        done
        xcodebuild -create-xcframework "${args[@]}" -output "$OUT_DIR/$lib.xcframework" >/dev/null
    done
    write_configuration
    stamp_value >"$STAMP"
    rm -rf "$WORK_DIR/src" "$WORK_DIR/obj"
    log "wrote $OUT_DIR/{libavcodec,libavutil}.xcframework and $CONFIG_TXT"
}

main "$@"
