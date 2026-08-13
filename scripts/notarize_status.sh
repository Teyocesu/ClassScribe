#!/usr/bin/env bash
# Check notarization status for a submission.
#
# Usage:
#   ./scripts/notarize_status.sh <submission-id>
#   ./scripts/notarize_status.sh              # shows history
#
# Uses NOTARY_KEYCHAIN_PROFILE when present (recommended), otherwise the
# legacy APPLE_ID, TEAM_ID and APP_PASSWORD variables from a local .env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    AUTH=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
    for var in APPLE_ID TEAM_ID APP_PASSWORD; do
        if [ -z "${!var:-}" ]; then
            echo "ERROR: set NOTARY_KEYCHAIN_PROFILE, or APPLE_ID, TEAM_ID, and APP_PASSWORD in .env" >&2
            exit 1
        fi
    done
    AUTH=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")
fi

if [ $# -ge 1 ]; then
    xcrun notarytool info "$1" "${AUTH[@]}"
else
    xcrun notarytool history "${AUTH[@]}"
fi
