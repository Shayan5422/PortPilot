#!/usr/bin/env bash
# Installs PortPilot into ~/Applications and registers the LaunchAgent that starts it at login
# and brings it back after a crash (but not after you choose Quit).
#
# Usage: scripts/install.sh [--no-build]

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/install.sh [--no-build]

Builds PortPilot, installs it to ~/Applications/PortPilot.app and starts it through a
LaunchAgent (~/Library/LaunchAgents/app.portpilot.agent.plist) so it runs at every login.

  --no-build   install the existing dist/PortPilot.app instead of building first
  -h, --help   show this help
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '==> %s\n' "$*"; }

build=1
for arg in "$@"; do
    case "$arg" in
        --no-build) build=0 ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $arg" ;;
    esac
done

[[ "$EUID" -ne 0 ]] || die "run this as your normal user, not with sudo (PortPilot is a per-user agent)"
[[ -n "${HOME:-}" && -d "$HOME" ]] || die "HOME is not set to an existing directory"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

readonly APP_NAME="PortPilot"
readonly BUNDLE_ID="app.portpilot.PortPilot"
readonly LABEL="app.portpilot.agent"
readonly DOMAIN="gui/$UID"
readonly DIST_APP="$ROOT/dist/$APP_NAME.app"
readonly INSTALL_DIR="$HOME/Applications"
readonly INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
readonly EXECUTABLE="$INSTALLED_APP/Contents/MacOS/$APP_NAME"
readonly AGENT_DIR="$HOME/Library/LaunchAgents"
readonly AGENT_PLIST="$AGENT_DIR/$LABEL.plist"
readonly LOG_DIR="$HOME/Library/Logs/$APP_NAME"
readonly LOG_FILE="$LOG_DIR/portpilot.log"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Temporary paths removed on exit, whatever happens.
staging=""
tmp_plist=""
cleanup() {
    [[ -z "$staging" ]] || rm -rf "$staging"
    [[ -z "$tmp_plist" ]] || rm -f "$tmp_plist"
}
trap cleanup EXIT

# --- Stopping the running copy -----------------------------------------------------------------
# Only processes named exactly "PortPilot" and owned by this user are ever touched.

is_running() { pgrep -x -U "$UID" "$APP_NAME" >/dev/null 2>&1; }

# Polls until no PortPilot process is left; returns 1 after $1 seconds.
wait_for_exit() {
    local ticks=$(($1 * 5)) i
    for ((i = 0; i < ticks; i++)); do
        is_running || return 0
        sleep 0.2
    done
    ! is_running
}

stop_portpilot() {
    # 1. Polite quit: the app exits with status 0, so launchd's KeepAlive {SuccessfulExit=false}
    #    does not restart it. osascript can block on an Automation prompt, so it gets 5 seconds.
    if is_running; then
        step "Quitting the running $APP_NAME"
        osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 &
        local osascript_pid=$!
        wait_for_exit 5 || true
        # Kill our osascript only while bash still tracks it as a running job (no stale-pid kill).
        if jobs -pr | grep -qx "$osascript_pid"; then
            kill "$osascript_pid" 2>/dev/null || true
        fi
        wait "$osascript_pid" 2>/dev/null || true
    fi

    # 2. Unload the previous agent (also stops an instance launchd started or restarted).
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

    # 3. Last resort: SIGTERM, then SIGKILL.
    if is_running; then
        pkill -TERM -x -U "$UID" "$APP_NAME" 2>/dev/null || true
        if ! wait_for_exit 3; then
            pkill -KILL -x -U "$UID" "$APP_NAME" 2>/dev/null || true
            wait_for_exit 2 || die "could not stop the running $APP_NAME (pids: $(pgrep -x -U "$UID" "$APP_NAME" | tr '\n' ' '))"
        fi
    fi
}

# --- LaunchAgent -------------------------------------------------------------------------------

# Writes the agent plist in exactly the format LoginItemManager uses, so the app recognises it
# as "Launch at login: on". Built with plutil so paths never need XML escaping.
write_agent_plist() {
    mkdir -p "$AGENT_DIR" "$LOG_DIR"
    tmp_plist="$(mktemp "$AGENT_DIR/.$LABEL.plist.XXXXXX")"
    plutil -create xml1 "$tmp_plist"
    plutil -insert Label -string "$LABEL" "$tmp_plist"
    plutil -insert ProgramArguments -array "$tmp_plist"
    plutil -insert ProgramArguments -string "$EXECUTABLE" -append "$tmp_plist"
    plutil -insert RunAtLoad -bool YES "$tmp_plist"
    plutil -insert KeepAlive -dictionary "$tmp_plist"
    plutil -insert KeepAlive.SuccessfulExit -bool NO "$tmp_plist"
    plutil -insert ProcessType -string Interactive "$tmp_plist"
    plutil -insert LimitLoadToSessionType -string Aqua "$tmp_plist"
    plutil -insert StandardOutPath -string "$LOG_FILE" "$tmp_plist"
    plutil -insert StandardErrorPath -string "$LOG_FILE" "$tmp_plist"
    plutil -lint -s "$tmp_plist" >/dev/null || die "generated LaunchAgent plist failed plutil -lint"
    chmod 644 "$tmp_plist"
    mv -f "$tmp_plist" "$AGENT_PLIST"
    tmp_plist=""
}

# bootstrap can fail transiently while the previous instance is still being torn down
# (error 37 "Operation already in progress", or 5 "Input/output error"), so retry a few times.
bootstrap_agent() {
    launchctl enable "$DOMAIN/$LABEL"
    local attempt output=""
    for attempt in 1 2 3 4 5; do
        if output="$(launchctl bootstrap "$DOMAIN" "$AGENT_PLIST" 2>&1)"; then
            return 0
        fi
        sleep "$attempt"
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    done
    printf '%s\n' "$output" >&2
    die "launchctl bootstrap $DOMAIN $AGENT_PLIST failed.
   If System Settings > General > Login Items & Extensions lists PortPilot under
   'Allow in the Background', make sure it is switched on, then run this script again."
}

verify_running() {
    local i pid=""
    for ((i = 0; i < 50; i++)); do
        pid="$(pgrep -x -U "$UID" -n "$APP_NAME" 2>/dev/null || true)"
        [[ -n "$pid" ]] && break
        sleep 0.2
    done
    if [[ -z "$pid" ]]; then
        printf '\n%s did not start. launchd state:\n' "$APP_NAME" >&2
        launchctl print "$DOMAIN/$LABEL" 2>&1 | grep -E '^[[:space:]]*(state|last exit code|pid|path|program) =' >&2 || true
        if [[ -f "$LOG_FILE" ]]; then
            printf '\nLast lines of %s:\n' "$LOG_FILE" >&2
            tail -n 20 "$LOG_FILE" >&2
        fi
        exit 1
    fi
    # Give it a moment: a crash on launch would show up as a vanished pid.
    sleep 1
    kill -0 "$pid" 2>/dev/null || die "$APP_NAME (pid $pid) exited right after launch; see $LOG_FILE"
    step "$APP_NAME is running (pid $pid) — look for its icon in the menu bar"
}

# --- Main --------------------------------------------------------------------------------------

if [[ "$build" -eq 1 ]]; then
    "$ROOT/scripts/build.sh"
fi
[[ -x "$DIST_APP/Contents/MacOS/$APP_NAME" ]] \
    || die "$DIST_APP not found or incomplete — run scripts/build.sh first (or drop --no-build)"

stop_portpilot

step "Installing to $INSTALLED_APP"
mkdir -p "$INSTALL_DIR"
staging="$(mktemp -d "$INSTALL_DIR/.$APP_NAME.install.XXXXXX")"
ditto "$DIST_APP" "$staging/$APP_NAME.app"
rm -rf "$INSTALLED_APP"
mv "$staging/$APP_NAME.app" "$INSTALLED_APP"
xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true
# Let Launch Services know about the new copy (Spotlight, `open -b`, notification icons).
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1 || true
fi

step "Registering LaunchAgent $LABEL"
write_agent_plist
bootstrap_agent
verify_running

cat <<EOF

Installed:   $INSTALLED_APP
LaunchAgent: $AGENT_PLIST (starts at login, restarts after a crash)
Log file:    $LOG_FILE
Uninstall:   $ROOT/scripts/uninstall.sh
EOF
