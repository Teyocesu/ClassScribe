#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSTEM_MANIFEST_API="/Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI"
LOCAL_MANIFEST_API="$PROJECT_ROOT/.toolchain/ManifestAPI"
LOCAL_USR="$PROJECT_ROOT/.toolchain/usr"
LOCAL_FLUID_AUDIO="$PROJECT_ROOT/.toolchain/FluidAudio"
FLUID_AUDIO_URL="https://github.com/FluidInference/FluidAudio.git"
FLUID_AUDIO_REVISION="19600a485baa4998812e4654b70d2bab8f2c9949"

if [ ! -d "$SYSTEM_MANIFEST_API" ]; then
    echo "No se encontró PackageDescription de Command Line Tools" >&2
    exit 1
fi

mkdir -p "$PROJECT_ROOT/.toolchain"
if [ ! -d "$LOCAL_MANIFEST_API" ]; then
    cp -R "$SYSTEM_MANIFEST_API" "$LOCAL_MANIFEST_API"
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
if [ ! -d "$LOCAL_FLUID_AUDIO/.git" ]; then
    git clone "$FLUID_AUDIO_URL" "$LOCAL_FLUID_AUDIO" >&2
fi
git -C "$LOCAL_FLUID_AUDIO" fetch --quiet origin "$FLUID_AUDIO_REVISION" >&2
git -C "$LOCAL_FLUID_AUDIO" checkout --quiet --detach "$FLUID_AUDIO_REVISION" >&2

if grep -qx 'import Foundation' "$LOCAL_FLUID_AUDIO/Package.swift"; then
    sed -i '' '/^import Foundation$/d' "$LOCAL_FLUID_AUDIO/Package.swift"
fi

echo "$PROJECT_ROOT/.toolchain"
