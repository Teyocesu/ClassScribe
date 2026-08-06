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
mkdir -p "$MACOS"
cp "$PACKAGE_DIR/ClassScribeSources/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD_PACKAGE_DIR/.build/release/ClassScribe" "$MACOS/ClassScribe"

codesign --force --sign - \
    --entitlements "$PACKAGE_DIR/Entitlements/Homebrew.entitlements" \
    "$APP" >/dev/null

echo "Aplicación lista: $APP"
if [ "$BUILD_ONLY" = false ]; then
    open "$APP"
fi
