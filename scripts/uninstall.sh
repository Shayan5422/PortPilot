#!/usr/bin/env bash
# Removes PortPilot: unloads and deletes its LaunchAgent, quits the app and deletes
# ~/Applications/PortPilot.app. The repository (including build/ and dist/) is left alone.
#
# Usage: scripts/uninstall.sh [-y|--yes] [--purge]

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/uninstall.sh [-y|--yes] [--purge]

Stops PortPilot, removes its LaunchAgent (~/Library/LaunchAgents/app.portpilot.agent.plist)
and deletes ~/Applications/PortPilot.app.

  -y, --yes    do not ask for confirmation
  --purge      also delete the logs (~/Library/Logs/PortPilot) and the app's preferences
  -h, --help   show this help
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '==> %s\n' "$*"; }

assume_yes=0
purge=0
for arg in "$@"; do
    case "$arg" in
        -y | --yes) assume_yes=1 ;;
        --purge) purge=1 ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $arg" ;;
    esac
done

[[ "$EUID" -ne 0 ]] || die "run this as your normal user, not with sudo"
[[ -n "${HOME:-}" && -d "$HOME" ]] || die "HOME is not set to an existing directory"

readonly APP_NAME="PortPilot"
readonly BUNDLE_ID="app.portpilot.PortPilot"
readonly LABEL="app.portpilot.agent"
readonly DOMAIN="gui/$UID"
readonly INSTALLED_APP="$HOME/Applications/$APP_NAME.app"
readonly AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly LOG_DIR="$HOME/Library/Logs/$APP_NAME"

# --- Stopping the running copy (same logic as install.sh) --------------------------------------
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
        step "Quitting $APP_NAME"
        osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 &
        local osascript_pid=$!
        wait_for_exit 5 || true
        # Kill our osascript only while bash still tracks it as a running job (no stale-pid kill).
        if jobs -pr | grep -qx "$osascript_pid"; then
            kill "$osascript_pid" 2>/dev/null || true
        fi
        wait "$osascript_pid" 2>/dev/null || true
    fi

    # 2. Unload the agent (also stops an instance launchd started or restarted).
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        step "Unloading LaunchAgent $LABEL"
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    fi

    # 3. Last resort: SIGTERM, then SIGKILL.
    if is_running; then
        pkill -TERM -x -U "$UID" "$APP_NAME" 2>/dev/null || true
        if ! wait_for_exit 3; then
            pkill -KILL -x -U "$UID" "$APP_NAME" 2>/dev/null || true
            wait_for_exit 2 || die "could not stop $APP_NAME (pids: $(pgrep -x -U "$UID" "$APP_NAME" | tr '\n' ' '))"
        fi
    fi
}

# --- Confirmation ------------------------------------------------------------------------------

printf 'This will stop PortPilot and remove:\n'
printf '  %s\n' "$AGENT_PLIST" "$INSTALLED_APP"
if [[ "$purge" -eq 1 ]]; then
    printf '  %s\n' "$LOG_DIR" "preferences (defaults domain $BUNDLE_ID)"
fi

if [[ "$assume_yes" -ne 1 ]]; then
    [[ -t 0 ]] || die "not running interactively; pass -y to confirm"
    read -r -p "Continue? [y/N] " answer
    case "$answer" in
        [yY] | [yY][eE][sS]) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac
fi

# --- Removal -----------------------------------------------------------------------------------

stop_portpilot

if [[ -f "$AGENT_PLIST" ]]; then
    step "Removing $AGENT_PLIST"
    rm -f "$AGENT_PLIST"
fi

if [[ -d "$INSTALLED_APP" ]]; then
    step "Removing $INSTALLED_APP"
    rm -rf "$INSTALLED_APP"
fi

if [[ "$purge" -eq 1 ]]; then
    if [[ -d "$LOG_DIR" ]]; then
        step "Removing $LOG_DIR"
        rm -rf "$LOG_DIR"
    fi
    step "Removing preferences ($BUNDLE_ID)"
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

step "PortPilot is uninstalled"
