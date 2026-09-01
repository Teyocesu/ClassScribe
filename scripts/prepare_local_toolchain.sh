#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSTEM_MANIFEST_API="/Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI"
LOCAL_MANIFEST_API="$PROJECT_ROOT/.toolchain/ManifestAPI"
LOCAL_USR="$PROJECT_ROOT/.toolchain/usr"
LOCAL_FLUID_AUDIO="$PROJECT_ROOT/.toolchain/FluidAudio"
LOCAL_PACKAGE="$PROJECT_ROOT/.toolchain/ClassScribePackage"
PACKAGE_DIR="$PROJECT_ROOT/app/MeetingTranscriber"
FLUID_AUDIO_URL="https://github.com/FluidInference/FluidAudio.git"
FLUID_AUDIO_REVISION="19600a485baa4998812e4654b70d2bab8f2c9949"
MANIFEST_TEMP=""

cleanup() {
    if [ -n "$MANIFEST_TEMP" ] && [ -d "$MANIFEST_TEMP" ]; then
        case "$MANIFEST_TEMP" in
            "$PROJECT_ROOT"/.toolchain/.ManifestAPI.*) rm -rf "$MANIFEST_TEMP" ;;
        esac
    fi
}
trap cleanup EXIT

if [ ! -d "$SYSTEM_MANIFEST_API" ]; then
    echo "No se encontró PackageDescription de Command Line Tools" >&2
    exit 1
fi

mkdir -p "$PROJECT_ROOT/.toolchain"
if [ ! -f "$LOCAL_MANIFEST_API/libPackageDescription.dylib" ] \
    || [ ! -f "$LOCAL_MANIFEST_API/PackageDescription.swiftmodule/arm64-apple-macos.swiftinterface" ] \
    || [ ! -f "$LOCAL_MANIFEST_API/PackageDescription.swiftmodule/x86_64-apple-macos.swiftinterface" ]; then
    MANIFEST_TEMP="$(mktemp -d "$PROJECT_ROOT/.toolchain/.ManifestAPI.XXXXXX")"
    cp -R "$SYSTEM_MANIFEST_API/." "$MANIFEST_TEMP/"
    case "$LOCAL_MANIFEST_API" in
        "$PROJECT_ROOT"/.toolchain/ManifestAPI) rm -rf "$LOCAL_MANIFEST_API" ;;
        *) echo "Destino ManifestAPI inesperado: $LOCAL_MANIFEST_API" >&2; exit 1 ;;
    esac
    mv "$MANIFEST_TEMP" "$LOCAL_MANIFEST_API"
    MANIFEST_TEMP=""
fi

# CLT 16.4 was installed with private interfaces from February 2024 but a
# May 2025 dylib. Use the matching public interfaces in this project-local
# copy. No system file is changed.
for arch in arm64 x86_64; do
    module="$LOCAL_MANIFEST_API/PackageDescription.swiftmodule"
    cp "$module/$arch-apple-macos.swiftinterface" "$module/$arch-apple-macos.private.swiftinterface"
done

# The same partial upgrade left two module maps declaring SwiftBridging.
# A local resource root exposes one declaration and symlinks the large runtime.
mkdir -p "$LOCAL_USR/lib" "$LOCAL_USR/include/swift"
if [ ! -e "$LOCAL_USR/lib/swift" ]; then
    ln -s /Library/Developer/CommandLineTools/usr/lib/swift "$LOCAL_USR/lib/swift"
fi
cp /Library/Developer/CommandLineTools/usr/include/swift/bridging "$LOCAL_USR/include/swift/bridging"
cp /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap "$LOCAL_USR/include/swift/module.modulemap"

# FluidAudio 0.15.5 imports Foundation in Package.swift even though its
# manifest does not use it. This particular partially-upgraded CLT install
# cannot compile Foundation because it publishes SwiftBridging twice. Keep the
# repository dependency remote and create an ignored, exact local mirror only
# for this machine's manifest compiler.
if ! git -C "$LOCAL_FLUID_AUDIO" rev-parse --git-dir >/dev/null 2>&1; then
    case "$LOCAL_FLUID_AUDIO" in
        "$PROJECT_ROOT"/.toolchain/FluidAudio) rm -rf "$LOCAL_FLUID_AUDIO" ;;
        *) echo "Destino FluidAudio inesperado: $LOCAL_FLUID_AUDIO" >&2; exit 1 ;;
    esac
    git clone "$FLUID_AUDIO_URL" "$LOCAL_FLUID_AUDIO" >&2
fi
git -C "$LOCAL_FLUID_AUDIO" fetch --quiet origin "$FLUID_AUDIO_REVISION" >&2
git -C "$LOCAL_FLUID_AUDIO" checkout --quiet --detach "$FLUID_AUDIO_REVISION" >&2

if grep -qx 'import Foundation' "$LOCAL_FLUID_AUDIO/Package.swift"; then
    sed -i '' '/^import Foundation$/d' "$LOCAL_FLUID_AUDIO/Package.swift"
fi

# SwiftPM does not forward -resource-dir while evaluating a dependency
# manifest. Prepare the complete ignored mirror here so README test commands,
# pre-push hooks, the launcher, and release builds all use the same repair.
mkdir -p "$LOCAL_PACKAGE"
for source in ClassScribeSources ClassScribeTests ProcessingIPCSources DiarizationHelperSources; do
    link="$LOCAL_PACKAGE/$source"
    case "$link" in
        "$PROJECT_ROOT"/.toolchain/ClassScribePackage/*) rm -rf "$link" ;;
        *) echo "Destino de mirror inesperado: $link" >&2; exit 1 ;;
    esac
    ln -s "$PACKAGE_DIR/$source" "$link"
done
cat > "$LOCAL_PACKAGE/Package.swift" <<EOF
// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ClassScribe",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "ClassScribe", targets: ["ClassScribe"]),
        .executable(name: "ClassScribeDiarizer", targets: ["ClassScribeDiarizer"]),
    ],
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
                "ClassScribeProcessingIPC",
            ],
            path: "ClassScribeSources",
            exclude: ["Info.plist"]
        ),
        .target(name: "ClassScribeProcessingIPC", path: "ProcessingIPCSources"),
        .executableTarget(
            name: "ClassScribeDiarizer",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "ClassScribeProcessingIPC",
            ],
            path: "DiarizationHelperSources"
        ),
        .testTarget(
            name: "ClassScribeTests",
            dependencies: [
                "ClassScribe",
                "ClassScribeProcessingIPC",
                .product(name: "AudioTapLib", package: "audiotap"),
            ],
            path: "ClassScribeTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
EOF

echo "$PROJECT_ROOT/.toolchain"
