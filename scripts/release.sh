#!/usr/bin/env bash
# Builds a signed, notarized and stapled PortPilot-<version>.dmg ready for GitHub Releases.
#
# One-time setup:
#   • A "Developer ID Application" certificate in your login keychain (Xcode → Settings → Accounts).
#   • notarytool credentials stored in the keychain:
#       xcrun notarytool store-credentials PortPilot --apple-id <apple-id> --team-id <TEAM_ID>
#
# Usage: scripts/release.sh [--skip-notarize] [--skip-tests]
# Env:   SIGN_IDENTITY   Developer ID identity name or SHA-1 (default: first "Developer ID Application" found)
#        NOTARY_PROFILE  notarytool keychain profile (default: PortPilot)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NOTARIZE=1
RUN_TESTS=1
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) NOTARIZE=0 ;;
        --skip-tests) RUN_TESTS=0 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

NOTARY_PROFILE="${NOTARY_PROFILE:-PortPilot}"
VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
BUILD_DIR="$ROOT/build/release"
DIST_DIR="$ROOT/dist"
APP_NAME="PortPilot"
DMG_NAME="$APP_NAME-$VERSION.dmg"
VOLUME_NAME="$APP_NAME"

step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "$VERSION" ]] || fail "could not read MARKETING_VERSION from project.yml"
command -v xcodegen >/dev/null || fail "xcodegen is required (brew install xcodegen)"

# Pick the signing identity by SHA-1 so duplicate certificates in several keychains are not ambiguous.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk '/"Developer ID Application/ {print $2; exit}')"
fi
[[ -n "$SIGN_IDENTITY" ]] || fail "no \"Developer ID Application\" identity found in the keychain"
IDENTITY_NAME="$(security find-identity -v -p codesigning | grep -F "$SIGN_IDENTITY" | head -1 | sed -E 's/.*"(.*)"/\1/')"
echo "Version:   $VERSION"
echo "Identity:  ${IDENTITY_NAME:-$SIGN_IDENTITY}"
if (( NOTARIZE )); then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 ||
        fail "notarytool profile \"$NOTARY_PROFILE\" not found — run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id <TEAM_ID>"
    echo "Notary:    keychain profile \"$NOTARY_PROFILE\""
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

step "Generating Xcode project"
xcodegen generate --quiet

if (( RUN_TESTS )); then
    step "Running tests"
    xcodebuild -project PortPilot.xcodeproj -scheme PortPilot -configuration Debug \
        -derivedDataPath "$BUILD_DIR/TestData" -destination "platform=macOS,arch=$(uname -m)" \
        CODE_SIGN_IDENTITY=- test >"$BUILD_DIR/test.log" 2>&1 ||
        { grep -E 'error:|failed' "$BUILD_DIR/test.log" | sort -u | tail -40; fail "tests failed (log: $BUILD_DIR/test.log)"; }
    grep -E 'Executed [0-9]+ tests' "$BUILD_DIR/test.log" | tail -1
fi

step "Building universal Release (arm64 + x86_64)"
xcodebuild -project PortPilot.xcodeproj -scheme PortPilot -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" -destination 'generic/platform=macOS' \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build >"$BUILD_DIR/build.log" 2>&1 ||
    { grep -E 'error:' "$BUILD_DIR/build.log" | sort -u | tail -40; fail "build failed (log: $BUILD_DIR/build.log)"; }
APP="$BUILD_DIR/$APP_NAME.app"
ditto "$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME.app" "$APP"
lipo -archs "$APP/Contents/MacOS/$APP_NAME"

step "Signing with Developer ID (hardened runtime + secure timestamp)"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

notarize() {   # $1 = file to submit
    local log="$BUILD_DIR/notary-$(basename "$1").json"
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m \
        --output-format json >"$log" || true
    local status
    status="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$log" 2>/dev/null || true)"
    if [[ "$status" != "Accepted" ]]; then
        cat "$log" >&2
        local id
        id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$log" 2>/dev/null || true)"
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        fail "notarization of $(basename "$1") failed (status: ${status:-unknown})"
    fi
    echo "Notarization accepted: $(basename "$1")"
}

if (( NOTARIZE )); then
    step "Notarizing the app"
    ditto -c -k --keepParent "$APP" "$BUILD_DIR/$APP_NAME.zip"
    notarize "$BUILD_DIR/$APP_NAME.zip"
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi

step "Building the disk image"
# dmgbuild writes the Finder layout (.DS_Store) itself — no Finder scripting or Automation prompts.
DMGBUILD="$ROOT/build/tools-venv/bin/dmgbuild"
if [[ ! -x "$DMGBUILD" ]]; then
    echo "Installing dmgbuild into build/tools-venv …"
    python3 -m venv "$ROOT/build/tools-venv"
    "$ROOT/build/tools-venv/bin/pip" install --quiet --disable-pip-version-check "dmgbuild>=1.6"
fi
BACKGROUND="$BUILD_DIR/background.tiff"
tiffutil -cathidpicheck Design/dmg-background.png Design/dmg-background@2x.png -out "$BACKGROUND" >/dev/null
FINAL_DMG="$DIST_DIR/$DMG_NAME"
rm -f "$FINAL_DMG"
"$DMGBUILD" -s scripts/dmg-settings.py -D app="$APP" -D background="$BACKGROUND" \
    -D icon="$APP/Contents/Resources/AppIcon.icns" "$VOLUME_NAME" "$FINAL_DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$FINAL_DMG"

if (( NOTARIZE )); then
    step "Notarizing the disk image"
    notarize "$FINAL_DMG"
    xcrun stapler staple "$FINAL_DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$FINAL_DMG"
fi

step "Done"
( cd "$DIST_DIR" && shasum -a 256 "$DMG_NAME" | tee "$DMG_NAME.sha256" )
ls -lh "$FINAL_DMG"
echo "$FINAL_DMG"
