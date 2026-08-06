#!/usr/bin/env bash
# Pre-push parity check. Runs the strictest local builds that surface issues
# CI's release pipeline would otherwise catch first.
#
# Usage:
#   ./scripts/pre-push.sh                     # release bundle of ClassScribe
#   ./scripts/pre-push.sh --with-tests        # also run ClassScribe tests
#
# Why this exists: `swift build` (debug) and `swift build -c release` use
# different Sendable-inference rules. Release mode enables WMO which can
# surface concurrency diagnostics that incremental debug builds tolerate
# (see PR #191 for the canonical example: ScreenCaptureKit Sendable hop
# only failed under -c release on CI). Running release locally before
# `git push` keeps that round-trip out of CI.

set -euo pipefail
cd "$(dirname "$0")/.."

WITH_TESTS=0
for arg in "$@"; do
    case "$arg" in
        --with-tests) WITH_TESTS=1 ;;
        -h|--help)
            sed -n '2,11p' "$0"
            exit 0
            ;;
        *)
            echo "unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

echo "==> ClassScribe release bundle + isolated diarization helper"
./scripts/run_app.sh --build-only

if [[ "$WITH_TESTS" == 1 ]]; then
    echo "==> ClassScribe tests"
    if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" ]]; then
        TASK_SWIFTPM_CUSTOM_LIBS_DIR="$(./scripts/prepare_local_toolchain.sh)"
        export SWIFTPM_CUSTOM_LIBS_DIR="$TASK_SWIFTPM_CUSTOM_LIBS_DIR"
        swift test --package-path .toolchain/ClassScribePackage -j 2 \
            -Xswiftc -resource-dir -Xswiftc "$PWD/.toolchain/usr/lib/swift" \
            -Xswiftc -strict-concurrency=complete
    else
        swift test --package-path app/MeetingTranscriber -j 2 \
            -Xswiftc -strict-concurrency=complete
        swift test --package-path tools/audiotap -j 2 \
            -Xswiftc -strict-concurrency=complete
    fi
fi

echo
echo "OK — pre-push parity check passed."
