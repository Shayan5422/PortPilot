#!/usr/bin/env bash
# Builds PortPilot.app (Release, ad-hoc signed) and copies it to dist/PortPilot.app.
#
# Usage: scripts/build.sh [--test]
#   --test    run the unit tests (xcodebuild test) before the Release build
#
# Needs Xcode (not just the Command Line Tools) and XcodeGen (brew install xcodegen).
# Full xcodebuild logs are kept in build/*.log; only errors are printed.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/build.sh [--test]

Builds PortPilot.app (Release, ad-hoc signed) into dist/PortPilot.app.

  --test       run the unit tests (xcodebuild test) before the Release build
  -h, --help   show this help
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '==> %s\n' "$*"; }

run_tests=0
for arg in "$@"; do
    case "$arg" in
        --test) run_tests=1 ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $arg" ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

readonly PROJECT="PortPilot.xcodeproj"
readonly SCHEME="PortPilot"
readonly DERIVED_DATA="build/DerivedData"
readonly PRODUCT="$DERIVED_DATA/Build/Products/Release/PortPilot.app"
readonly DIST_APP="dist/PortPilot.app"

# --- Preflight ---------------------------------------------------------------------------------

command -v xcodegen >/dev/null 2>&1 \
    || die "xcodegen not found. Install it with: brew install xcodegen"
if ! xcodebuild -version >/dev/null 2>&1; then
    die "xcodebuild is not usable. Install Xcode, then select it with:
       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   (and accept the license once with: sudo xcodebuild -license accept)"
fi

mkdir -p build

# Runs xcodebuild with all output going to a log file. On failure, prints the error lines
# (deduplicated, in order) or the tail of the log when no error line could be recognised.
run_xcodebuild() {
    local log="$1"
    shift
    if xcodebuild "$@" >"$log" 2>&1; then
        local warnings
        warnings="$(grep -c ': warning: ' "$log" || true)"
        if [[ "$warnings" -gt 0 ]]; then
            printf '    %s compiler warning line(s); see %s\n' "$warnings" "$log"
        fi
        return 0
    fi
    printf '\nxcodebuild failed. Relevant lines (full log: %s):\n\n' "$log" >&2
    local errors
    errors="$(grep -E ': (fatal )?error: |^error: |^xcodebuild: error|Test Case .* failed|\*\* .* FAILED \*\*' "$log" \
        | awk '!seen[$0]++' | head -n 80 || true)"
    if [[ -n "$errors" ]]; then
        printf '%s\n' "$errors" >&2
    else
        tail -n 40 "$log" >&2
    fi
    exit 1
}

# --- Build -------------------------------------------------------------------------------------

step "Generating $PROJECT (xcodegen)"
xcodegen generate --spec project.yml --quiet

if [[ "$run_tests" -eq 1 ]]; then
    step "Running unit tests"
    run_xcodebuild build/xcodebuild-test.log \
        -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
        -derivedDataPath "$DERIVED_DATA" \
        -destination "platform=macOS,arch=$(uname -m)" \
        CODE_SIGN_IDENTITY=- \
        test
    printf '    tests passed\n'
fi

step "Building $SCHEME (Release) — this can take a minute"
run_xcodebuild build/xcodebuild-release.log \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_IDENTITY=- \
    build

[[ -d "$PRODUCT" ]] || die "build reported success but $PRODUCT is missing"

# --- Package -----------------------------------------------------------------------------------

step "Copying to $DIST_APP"
mkdir -p dist
rm -rf "$DIST_APP"
ditto "$PRODUCT" "$DIST_APP"

if ! codesign --verify --strict "$DIST_APP" 2>/dev/null; then
    printf 'warning: codesign could not verify %s (it may not launch)\n' "$DIST_APP" >&2
fi

version="$(plutil -extract CFBundleShortVersionString raw "$DIST_APP/Contents/Info.plist" 2>/dev/null || echo '?')"
build_number="$(plutil -extract CFBundleVersion raw "$DIST_APP/Contents/Info.plist" 2>/dev/null || echo '?')"
step "Built PortPilot $version ($build_number)"
printf '%s\n' "$ROOT/$DIST_APP"
