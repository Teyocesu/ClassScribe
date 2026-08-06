#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPENDENCIES_DIR="$PROJECT_ROOT/.dependencies"
FLUID_DIR="$DEPENDENCIES_DIR/FluidAudio"
FLUID_REVISION="19600a485baa4998812e4654b70d2bab8f2c9949"

mkdir -p "$DEPENDENCIES_DIR"
if [ ! -d "$FLUID_DIR/.git" ]; then
    git clone https://github.com/FluidInference/FluidAudio.git "$FLUID_DIR"
fi

git -C "$FLUID_DIR" fetch --depth 1 origin "$FLUID_REVISION"
git -C "$FLUID_DIR" checkout --detach "$FLUID_REVISION"

# CLT 16.4 on this machine has a stale private PackageDescription interface
# for manifests <= 6.0. FluidAudio supports Swift 6.1; changing only this
# generated checkout's manifest header selects the coherent public interface.
LC_ALL=C sed -i '' 's#// swift-tools-version: 6\.[012]#// swift-tools-version: 6.1#' "$FLUID_DIR/Package.swift"
LC_ALL=C sed -i '' '/^import Foundation$/d' "$FLUID_DIR/Package.swift"

echo "FluidAudio 0.15.5 preparado en $FLUID_DIR"
