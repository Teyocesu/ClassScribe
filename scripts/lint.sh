#!/usr/bin/env bash
# Lint orchestrator. Single source of truth for the Swift directories that get
# formatted and linted by the optional local quality check.
#
# Usage:
#   ./scripts/lint.sh                # check both (dry-run)
#   ./scripts/lint.sh --fix          # auto-correct both
#   ./scripts/lint.sh --format-only  # only SwiftFormat
#   ./scripts/lint.sh --lint-only    # only SwiftLint

set -euo pipefail
cd "$(dirname "$0")/.."

SWIFT_DIRS=(
    app/MeetingTranscriber/ClassScribeSources
    app/MeetingTranscriber/ClassScribeTests
    app/MeetingTranscriber/ProcessingIPCSources
    app/MeetingTranscriber/DiarizationHelperSources
    tools/audiotap/Sources
    tools/audiotap/Tests
)

MODE="${1:-}"
RUN_FORMAT=true
RUN_LINT=true
case "$MODE" in
    --format-only) RUN_LINT=false ;;
    --lint-only)   RUN_FORMAT=false ;;
esac

# --- SwiftFormat (formatter) ---
if [[ "$RUN_FORMAT" == "true" ]]; then
    if command -v swiftformat &>/dev/null; then
        if [[ "$MODE" == "--fix" ]]; then
            echo "Running swiftformat..."
            swiftformat "${SWIFT_DIRS[@]}"
        else
            echo "Checking swiftformat..."
            swiftformat --dryrun --lint "${SWIFT_DIRS[@]}"
        fi
    else
        echo "Warning: swiftformat not found; format check skipped."
    fi
fi

# --- SwiftLint (linter) ---
# `--strict` promotes warning-level rules to errors so any new violation
# fails CI rather than slowly accumulating. Pair with the swiftSettings'
# `-warnings-as-errors` for full zero-warning enforcement.
if [[ "$RUN_LINT" == "true" ]]; then
    if command -v swiftlint &>/dev/null; then
        SWIFTLINT_ARGS=(--strict)
        # This Mac intentionally has Command Line Tools only. SwiftLint cannot
        # dynamically load SourceKit from that partially upgraded toolchain;
        # A host with full Xcode runs every SourceKit-backed rule.
        if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" ]]; then
            SWIFTLINT_ARGS+=(--disable-sourcekit)
        fi
        if [[ "$MODE" == "--fix" ]]; then
            echo "Running swiftlint --fix..."
            swiftlint lint --fix "${SWIFTLINT_ARGS[@]}"
        else
            echo "Running swiftlint --strict..."
            swiftlint lint "${SWIFTLINT_ARGS[@]}"
        fi
    else
        echo "Error: swiftlint not found. Install it with your preferred tool manager."
        exit 1
    fi
fi
