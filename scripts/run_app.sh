#!/usr/bin/env bash
set -euo pipefail

BUILD_ONLY=false
if [ "${1:-}" = "--build-only" ]; then BUILD_ONLY=true; fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$PROJECT_ROOT/app/MeetingTranscriber"
BUILD_PACKAGE_DIR="$PACKAGE_DIR"

echo "Compilando ClassScribe (la primera compilación de FluidAudio puede tardar)…"
SWIFT_ARGS=(-c release -j 2)
if [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then
    # Workaround local for a partially upgraded Command Line Tools install.
    SWIFTPM_CUSTOM_LIBS_DIR="$("$SCRIPT_DIR/prepare_local_toolchain.sh")"
    export SWIFTPM_CUSTOM_LIBS_DIR
    SWIFT_ARGS+=(-Xswiftc -resource-dir -Xswiftc "$PROJECT_ROOT/.toolchain/usr/lib/swift")

    # SwiftPM does not forward -resource-dir while evaluating a dependency
    # manifest. Build an ignored package mirror that points at the exact,
    # official FluidAudio copy prepared above. The tracked Package.swift
    # remains a fixed remote dependency for normal toolchains and CI.
    BUILD_PACKAGE_DIR="$PROJECT_ROOT/.toolchain/ClassScribePackage"
    mkdir -p "$BUILD_PACKAGE_DIR"
    ln -sfn "$PACKAGE_DIR/ClassScribeSources" "$BUILD_PACKAGE_DIR/ClassScribeSources"
    ln -sfn "$PACKAGE_DIR/ClassScribeTests" "$BUILD_PACKAGE_DIR/ClassScribeTests"
    cat > "$BUILD_PACKAGE_DIR/Package.swift" <<EOF
// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ClassScribe",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "ClassScribe", targets: ["ClassScribe"])],
    dependencies: [
        .package(path: "$PROJECT_ROOT/.toolchain/FluidAudio"),
        .package(path: "$PROJECT_ROOT/tools/audiotap"),
    ],
    targets: [
        .executableTarget(
            name: "ClassScribe",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "AudioTapLib", package: "audiotap"),
            ],
            path: "ClassScribeSources",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "ClassScribeTests",
            dependencies: ["ClassScribe"],
            path: "ClassScribeTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
EOF
fi
swift build --package-path "$BUILD_PACKAGE_DIR" "${SWIFT_ARGS[@]}"

APP="$PACKAGE_DIR/.build/ClassScribe-Dev.app"
MACOS="$APP/Contents/MacOS"
INFO_PLIST="$APP/Contents/Info.plist"
BUILD_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
BUILD_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# `open "$APP"` activates an already-running app with this bundle identity.
# That previously left an old process alive after a newly compiled executable
# was copied over its path. Stop only the exact executable this script owns,
# then replace the whole ignored .app product and force a fresh launch.
running_app_pids() {
    ps -axo pid=,command= | awk -v executable="$MACOS/ClassScribe" '$2 == executable { print $1 }'
}

OLD_PIDS="$(running_app_pids)"
if [ -n "$OLD_PIDS" ]; then
    echo "Cerrando instancia(s) anterior(es) de ClassScribe: $OLD_PIDS"
    for PROCESS_ID in $OLD_PIDS; do
        kill "$PROCESS_ID"
    done
    for _ in $(seq 1 20); do
        [ -z "$(running_app_pids)" ] && break
        sleep 0.1
    done
    if [ -n "$(running_app_pids)" ]; then
        echo "La instancia anterior no se cerró: $(running_app_pids)" >&2
        exit 1
    fi
fi

# Guard the only destructive operation: this script may replace precisely its
# own ignored development bundle, never an arbitrary caller-provided path.
case "$APP" in
    "$PACKAGE_DIR"/.build/ClassScribe-Dev.app) ;;
    *) echo "Destino de producto inesperado: $APP" >&2; exit 1 ;;
esac
rm -rf "$APP"
mkdir -p "$MACOS"
cp "$PACKAGE_DIR/ClassScribeSources/Info.plist" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :ClassScribeBuildCommit string $BUILD_COMMIT" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :ClassScribeBuildTimestamp string $BUILD_TIMESTAMP" "$INFO_PLIST"
cp "$BUILD_PACKAGE_DIR/.build/release/ClassScribe" "$MACOS/ClassScribe"

codesign --force --sign - \
    --entitlements "$PACKAGE_DIR/Entitlements/Homebrew.entitlements" \
    "$APP" >/dev/null

echo "Aplicación lista: $APP"
echo "Build: commit=$BUILD_COMMIT builtAt=$BUILD_TIMESTAMP executable=$MACOS/ClassScribe"
if [ "$BUILD_ONLY" = false ]; then
    open -n "$APP"
    for _ in $(seq 1 30); do
        NEW_PIDS="$(running_app_pids)"
        [ -n "$NEW_PIDS" ] && break
        sleep 0.1
    done
    NEW_PIDS="$(running_app_pids)"
    if [ -z "$NEW_PIDS" ]; then
        echo "ClassScribe no inició desde el producto recién construido." >&2
        exit 1
    fi
    if [ "$(printf '%s\n' "$NEW_PIDS" | wc -l | tr -d ' ')" -ne 1 ]; then
        echo "Se esperaba una única instancia; se encontraron: $NEW_PIDS" >&2
        exit 1
    fi
    echo "ClassScribe iniciado: pid=$NEW_PIDS executable=$MACOS/ClassScribe"
fi
