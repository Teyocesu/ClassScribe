#!/usr/bin/env bash
# Assemble and verify the distributable ClassScribe macOS release.
#
# Usage:
#   ./scripts/build_release.sh --signing-mode=adhoc
#   ./scripts/build_release.sh --signing-mode=developer-id --notarize \
#       --notary-profile classscribe-notary
#
# Output (the VERSION file is the single version source):
#   .build/release/ClassScribe-vX.Y.Z-arm64.dmg
#   .build/release/ClassScribe-vX.Y.Z-arm64.dmg.sha256

set -euo pipefail

# Kept sourceable for the small regression test in scripts/tests.
detect_sign_hash() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '[0-9A-F]{40}' | head -1 || true
}

# Notarization accepts Developer ID Application signatures, not an arbitrary
# local development identity. Keep detect_sign_hash above for its existing
# sourceable regression test, but never select a non-Developer-ID identity for
# an official build.
detect_developer_id_hash() {
    security find-identity -v -p codesigning 2>/dev/null \
        | awk '/Developer ID Application/ { print $2; exit }' || true
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$PROJECT_ROOT/app/MeetingTranscriber"
BUILD_DIR="$PROJECT_ROOT/.build/release"
APP_BUNDLE="$BUILD_DIR/ClassScribe.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
HELPERS_DIR="$CONTENTS/Helpers"
RESOURCES_DIR="$CONTENTS/Resources"
INFO_TEMPLATE="$PACKAGE_DIR/ClassScribeSources/Info.plist"
ENTITLEMENTS="$PACKAGE_DIR/Entitlements/Homebrew.entitlements"
SIGNING_MODE="auto"
NOTARIZE=false
NOTARY_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
OVERRIDE_VERSION=""

usage() {
    sed -n '1,15p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  --signing-mode=adhoc|developer-id  Explicit signing mode (default: auto).
  --notarize                         Submit and staple with notarytool (Developer ID only).
  --notary-profile NAME              notarytool keychain profile to use.
  --version=X.Y.Z                    Override VERSION after validation (CI only).
  --no-notarize                      Compatibility alias for --signing-mode=adhoc.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --signing-mode=*) SIGNING_MODE="${arg#*=}" ;;
        --notarize) NOTARIZE=true ;;
        --notary-profile=*) NOTARY_PROFILE="${arg#*=}" ;;
        --version=*) OVERRIDE_VERSION="${arg#*=}" ;;
        --no-notarize) SIGNING_MODE="adhoc" ;;
        --help|-h) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

# A developer-owned .env is convenient locally. GitHub Actions passes secrets
# through the environment; neither branch prints values or enables xtrace.
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/.env"
    set +a
fi

VERSION="${OVERRIDE_VERSION:-$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: VERSION must be a release version in X.Y.Z form; got '$VERSION'." >&2
    exit 2
fi

if [ "$SIGNING_MODE" = "auto" ]; then
    if [ -n "${DEVELOPER_ID:-}" ] || [ -n "$(detect_developer_id_hash)" ]; then
        SIGNING_MODE="developer-id"
    else
        SIGNING_MODE="adhoc"
    fi
fi
case "$SIGNING_MODE" in adhoc|developer-id) ;; *)
    echo "ERROR: --signing-mode must be adhoc or developer-id." >&2; exit 2 ;;
esac
if [ "$NOTARIZE" = true ] && [ "$SIGNING_MODE" != "developer-id" ]; then
    echo "ERROR: notarization requires --signing-mode=developer-id." >&2
    exit 2
fi

if [ "$SIGNING_MODE" = "developer-id" ]; then
    DEVELOPER_ID="${DEVELOPER_ID:-$(detect_developer_id_hash)}"
    if [ -z "$DEVELOPER_ID" ]; then
        echo "ERROR: no Developer ID Application signing identity is available." >&2
        exit 1
    fi
fi

DMG_NAME="ClassScribe-v${VERSION}-arm64.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
STAGING_DIR="$BUILD_DIR/dmg-staging"
ICONSET="$BUILD_DIR/ClassScribe.iconset"

cleanup() {
    rm -rf "$STAGING_DIR" "$ICONSET"
}
trap cleanup EXIT

set_plist_string() {
    local key="$1" value="$2" plist="$3"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist"
}

sign_nested_code() {
    local identity="$1"

    sign_item() {
        if [ "$SIGNING_MODE" = "developer-id" ]; then
            codesign --force --sign "$identity" --options runtime --timestamp "$1"
        else
            codesign --force --sign "$identity" "$1"
        fi
    }

    # Sign every nested Mach-O before its enclosing code container and sign the
    # main app last. This covers the helper plus future SwiftPM dylibs without
    # relying on --deep, which can mask an incorrectly signed structure.
    while IFS= read -r -d '' item; do
        [ "$item" = "$MACOS_DIR/ClassScribe" ] && continue
        if file "$item" | grep -q 'Mach-O'; then
            sign_item "$item"
        fi
    done < <(find "$APP_BUNDLE/Contents" -type f -print0)

    while IFS= read -r -d '' container; do
        sign_item "$container"
    done < <(find "$APP_BUNDLE/Contents" -depth -type d \
        \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \) -print0)
}

assert_arm64() {
    local executable="$1" architectures
    architectures="$(lipo -archs "$executable")"
    if [[ " $architectures " != *" arm64 "* ]]; then
        echo "ERROR: $executable is not arm64 (found: $architectures)." >&2
        exit 1
    fi
    file "$executable"
}

assert_no_prohibited_files() {
    local root="$1" forbidden
    forbidden="$(find "$root" \( -name '.git' -o -name '.github' -o -name '.swiftpm' -o -name '.build' \
        -o -name '.env' -o -name '.env.*' -o -name '*.swift' -o -iname '*Tests*' -o -name 'signing' \
        -o -name '*.p12' -o -name '*.p8' -o -name '*.pem' -o -name '*.key' -o -name '*.mobileprovision' \
        -o -name '*.log' -o -name '*.wav' -o -name '*.aiff' -o -name '*.m4a' -o -name '*.mp3' \
        -o -name '*.mlmodel' -o -name '*.mlpackage' -o -name '*.mlmodelc' -o -name 'Models' \
        -o -name 'Classes' -o -name 'ProfessorVoices' \) -print)"
    if [ -n "$forbidden" ]; then
        echo "ERROR: prohibited source, credential, model, audio, or local file in app bundle:" >&2
        printf '%s\n' "$forbidden" >&2
        exit 1
    fi
}

mach_o_rpaths() {
    otool -l "$1" | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { want_path = 1; next }
        want_path && $1 == "path" { print $2; want_path = 0 }
    '
}

remove_developer_rpaths() {
    local executable="$1" rpath
    while IFS= read -r rpath; do
        [ -n "$rpath" ] || continue
        case "$rpath" in
            @*) ;;
            /System/*|/usr/lib/*) ;;
            *)
                echo "  Removing build-machine rpath from $(basename "$executable"): $rpath"
                install_name_tool -delete_rpath "$rpath" "$executable"
                ;;
        esac
    done < <(mach_o_rpaths "$executable")
}

assert_self_contained_executable() {
    local executable="$1" dependency rpath
    while IFS= read -r dependency; do
        [ -n "$dependency" ] || continue
        case "$dependency" in
            /System/Library/*|/usr/lib/*|@loader_path/*|@executable_path/*|@rpath/*) ;;
            *)
                echo "ERROR: external dynamic-library dependency in $executable: $dependency" >&2
                exit 1
                ;;
        esac
    done < <(otool -L "$executable" | tail -n +2 | awk '{print $1}')

    while IFS= read -r rpath; do
        [ -n "$rpath" ] || continue
        case "$rpath" in
            @*|/System/*|/usr/lib/*) ;;
            *)
                echo "ERROR: external runtime search path in $executable: $rpath" >&2
                exit 1
                ;;
        esac
    done < <(mach_o_rpaths "$executable")
}

assert_clean_bundle() {
    assert_no_prohibited_files "$APP_BUNDLE"
    assert_self_contained_executable "$MACOS_DIR/ClassScribe"
    assert_self_contained_executable "$HELPERS_DIR/ClassScribeDiarizer"
    if {
        otool -L "$MACOS_DIR/ClassScribe" | tail -n +2
        otool -L "$HELPERS_DIR/ClassScribeDiarizer" | tail -n +2
    } | grep -E '/(Users|private|opt/homebrew|Applications/Xcode|Library/Developer|Volumes)/' >/dev/null; then
        echo "ERROR: bundle has a developer-local dynamic-library reference." >&2
        exit 1
    fi
}

verify_dmg() {
    local mount_dir mounted_app
    hdiutil verify "$DMG_PATH"
    mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/classscribe-dmg.XXXXXX")"
    trap 'hdiutil detach "$mount_dir" -quiet 2>/dev/null || true; rmdir "$mount_dir" 2>/dev/null || true; cleanup' EXIT
    hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$mount_dir" >/dev/null
    mounted_app="$mount_dir/ClassScribe.app"
    test -d "$mounted_app"
    test -L "$mount_dir/Applications"
    test "$(readlink "$mount_dir/Applications")" = /Applications
    test -x "$mounted_app/Contents/MacOS/ClassScribe"
    test -x "$mounted_app/Contents/Helpers/ClassScribeDiarizer"
    plutil -lint "$mounted_app/Contents/Info.plist"
    assert_no_prohibited_files "$mounted_app"
    codesign --verify --deep --strict --verbose=2 "$mounted_app"
    codesign --verify --strict --verbose=2 "$mounted_app/Contents/Helpers/ClassScribeDiarizer"
    test "$(diskutil info -plist "$mount_dir" | plutil -extract VolumeName raw -o - -)" = ClassScribe
    hdiutil detach "$mount_dir" -quiet
    rmdir "$mount_dir"
    trap cleanup EXIT
}

echo "Building ClassScribe v$VERSION for Apple Silicon"
echo "  Signing mode: $SIGNING_MODE"
echo "  Notarization: $NOTARIZE"

rm -rf "$APP_BUNDLE" "$STAGING_DIR"
mkdir -p "$MACOS_DIR" "$HELPERS_DIR" "$RESOURCES_DIR"

echo "Step 1: Building SwiftPM products"
# Reuse run_app.sh's local-CLT workaround. GitHub's full Xcode toolchain uses
# the tracked package directly; a partially upgraded Command Line Tools install
# cannot evaluate the Swift 6.1 manifest without this ignored local mirror.
BUILD_PACKAGE_DIR="$PACKAGE_DIR"
SWIFT_ARGS=(-c release --arch arm64 -j 2)
if [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then
    SWIFTPM_CUSTOM_LIBS_DIR="$("$SCRIPT_DIR/prepare_local_toolchain.sh")"
    export SWIFTPM_CUSTOM_LIBS_DIR
    SWIFT_ARGS+=(-Xswiftc -resource-dir -Xswiftc "$PROJECT_ROOT/.toolchain/usr/lib/swift")
    BUILD_PACKAGE_DIR="$PROJECT_ROOT/.toolchain/ClassScribePackage"
fi
swift build --package-path "$BUILD_PACKAGE_DIR" "${SWIFT_ARGS[@]}"
MAIN_PRODUCT="$BUILD_PACKAGE_DIR/.build/arm64-apple-macosx/release/ClassScribe"
HELPER_PRODUCT="$BUILD_PACKAGE_DIR/.build/arm64-apple-macosx/release/ClassScribeDiarizer"
test -x "$MAIN_PRODUCT"
test -x "$HELPER_PRODUCT"
cp "$MAIN_PRODUCT" "$MACOS_DIR/ClassScribe"
cp "$HELPER_PRODUCT" "$HELPERS_DIR/ClassScribeDiarizer"
remove_developer_rpaths "$MACOS_DIR/ClassScribe"
remove_developer_rpaths "$HELPERS_DIR/ClassScribeDiarizer"

echo "Step 2: Assembling ClassScribe.app"
cp "$INFO_TEMPLATE" "$CONTENTS/Info.plist"
set_plist_string CFBundleShortVersionString "$VERSION" "$CONTENTS/Info.plist"
set_plist_string CFBundleVersion "$VERSION" "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist"
GIT_HASH="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || printf unknown)"
BUILD_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
/usr/libexec/PlistBuddy -c "Add :ClassScribeBuildCommit string $GIT_HASH" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ClassScribeBuildTimestamp string $BUILD_TIMESTAMP" "$CONTENTS/Info.plist"

ICON_SOURCE="$PACKAGE_DIR/ClassScribeAssets/AppIcon.png"
test -f "$ICON_SOURCE"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns"

echo "Step 3: Signing and validating ClassScribe.app"
if [ "$SIGNING_MODE" = "developer-id" ]; then
    # shellcheck source=lib/signing.sh
    source "$SCRIPT_DIR/lib/signing.sh"
    # shellcheck source=lib/bundle-ids.sh
    source "$SCRIPT_DIR/lib/bundle-ids.sh"
    prepare_signing "$APP_BUNDLE" "$ENTITLEMENTS" "$RELEASE_BUNDLE_ID" "$DEVELOPER_ID"
    sign_nested_code "$SIGNING_IDENTITY"
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
        --entitlements "$SIGNING_ENTITLEMENTS" "$APP_BUNDLE"
    verify_signing "$APP_BUNDLE"
else
    sign_nested_code -
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
fi
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$HELPERS_DIR/ClassScribeDiarizer"
if [ "$SIGNING_MODE" = "developer-id" ]; then
    for signed_item in "$APP_BUNDLE" "$HELPERS_DIR/ClassScribeDiarizer"; do
        signature_details="$(codesign -d --verbose=4 "$signed_item" 2>&1)"
        grep -Fq 'Authority=Developer ID Application:' <<<"$signature_details"
        grep -Eq 'flags=.*runtime' <<<"$signature_details"
    done
fi
assert_arm64 "$MACOS_DIR/ClassScribe"
assert_arm64 "$HELPERS_DIR/ClassScribeDiarizer"
assert_clean_bundle

if [ "$NOTARIZE" = true ]; then
    if [ -z "$NOTARY_PROFILE" ]; then
        echo "ERROR: --notary-profile (or NOTARY_KEYCHAIN_PROFILE) is required for notarization." >&2
        exit 2
    fi
    echo "Step 4: Notarizing and stapling ClassScribe.app"
    APP_ZIP="$BUILD_DIR/ClassScribe-v${VERSION}-arm64.app.zip"
    rm -f "$APP_ZIP"
    ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
    xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$APP_ZIP"
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
fi

echo "Step 5: Creating DMG"
rm -f "$DMG_PATH" "$CHECKSUM_PATH"
mkdir -p "$STAGING_DIR"
ditto "$APP_BUNDLE" "$STAGING_DIR/ClassScribe.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "ClassScribe" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

if [ "$SIGNING_MODE" = "developer-id" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH"
fi

if [ "$NOTARIZE" = true ]; then
    echo "Step 6: Notarizing and stapling DMG"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH"
fi

echo "Step 7: Verifying distributable artifact"
verify_dmg
if [ "$NOTARIZE" = true ]; then
    spctl --assess --type execute --verbose "$APP_BUNDLE"
fi
(
    cd "$BUILD_DIR"
    LC_ALL=C shasum -a 256 "$DMG_NAME" > "${DMG_NAME}.sha256"
)

echo "Release ready: $DMG_PATH"
echo "Checksum:      $CHECKSUM_PATH"
