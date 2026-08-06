#!/usr/bin/env bash
set -euo pipefail

BUILD_ONLY=false
if [ "${1:-}" = "--build-only" ]; then BUILD_ONLY=true; fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$PROJECT_ROOT/app/MeetingTranscriber"

"$SCRIPT_DIR/bootstrap_dependencies.sh"
SWIFTPM_CUSTOM_LIBS_DIR="$("$SCRIPT_DIR/prepare_local_toolchain.sh")"
export SWIFTPM_CUSTOM_LIBS_DIR

echo "Compilando ClassScribe (la primera compilación de FluidAudio puede tardar)…"
SWIFT_RESOURCE_DIR="$PROJECT_ROOT/.toolchain/usr/lib/swift"
swift build --package-path "$PACKAGE_DIR" -c release -j 2 \
    -Xswiftc -resource-dir -Xswiftc "$SWIFT_RESOURCE_DIR"

APP="$PACKAGE_DIR/.build/ClassScribe-Dev.app"
MACOS="$APP/Contents/MacOS"
mkdir -p "$MACOS"
cp "$PACKAGE_DIR/ClassScribeSources/Info.plist" "$APP/Contents/Info.plist"
cp "$PACKAGE_DIR/.build/release/ClassScribe" "$MACOS/ClassScribe"

codesign --force --sign - \
    --entitlements "$PACKAGE_DIR/Entitlements/Homebrew.entitlements" \
    "$APP" >/dev/null

echo "Aplicación lista: $APP"
if [ "$BUILD_ONLY" = false ]; then
    open "$APP"
fi
