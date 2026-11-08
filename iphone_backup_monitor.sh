#!/bin/bash
# ==============================================================================
# iPhone Auto Backup - Connection Monitor Daemon
# Author: Vaibhav Bhootna
# Repository: https://github.com/vbv611/iphone-auto-backup
#
# This persistent daemon is supervised by macOS launchd. It monitors the USB
# bus via libimobiledevice for trusted iPhone connections and coordinates
# sequential video and photo backups.
# ==============================================================================

set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

STATUS_FILE="/tmp/iphone_backup_monitor.status"
LOCKDIR="/tmp/iphone_backup_monitor.lockdir"
TRIGGER_FILE="/tmp/iphone_backup_manual.trigger"
: "${IPHONE_MONITOR_INTERVAL:=10}"
: "${IPHONE_SAME_CONN:=once}"
: "${IPHONE_RESYNC_INTERVAL:=300}"

# Display a native macOS notification safely using positional arguments.
# Arguments:
#   $1 - Title
#   $2 - Message body
notify() {
    local title="$1" msg="$2"
    command -v osascript >/dev/null 2>&1 || return 0
    osascript - "$title" "$msg" <<'APPLESCRIPT' 2>/dev/null || true
on run argv
    set theTitle to item 1 of argv
    set theMsg to item 2 of argv
    display notification theMsg with title theTitle
end run
APPLESCRIPT
}

# Write current monitor state to status tracking file.
# Arguments:
#   $1 - State (e.g. watching, running, done, waiting_trust)
#   $2 - Device UDID (optional)
#   $3 - Diagnostic details (optional)
write_status() {
    local state="$1" device="${2:-}" detail="${3:-}"
    {
        echo "state=$state"
        echo "device=$device"
        echo "detail=$detail"
        echo "updated_at=$(date '+%Y-%m-%dT%H:%M:%S')"
    } > "$STATUS_FILE"
}

# Retrieve connected device UDID (first connected device).
# Returns:
#   Outputs UDID string or empty if no device connected.
devices() {
    "$IDEVICE_ID" -l 2>/dev/null | head -n 1 | tr -d '[:space:]'
}

# Validate pairing and trust status for the specified UDID.
# Arguments:
#   $1 - Device UDID
# Returns:
#   0 if validated, 1 otherwise.
trusted() {
    local udid="${1:-}"
    local -a args=("validate")
    [[ -n "$udid" ]] && args=("-u" "$udid" "validate")
    "$IDEVICEPAIR" "${args[@]}" 2>&1 | grep -Eiq 'success|valid'
}

# Execute video and photo backups sequentially for the active device.
# Arguments:
#   $1 - Device UDID
# Returns:
#   0 on full success; 1 if any worker failed.
run_backups() {
    local device="$1"
    notify "iPhone Connected" "Starting automatic backup of videos and photos."
    write_status "running" "$device" "video+photo backup"

    # Execute video and photo backups sequentially to eliminate USB/AFC socket contention
    IPHONE_BACKUP_QUIET_NO_DEVICE=1 IPHONE_UDID="$device" bash "$SCRIPT_DIR/backup_videos_v3.sh"
    local video_rc=$?
    IPHONE_BACKUP_QUIET_NO_DEVICE=1 IPHONE_UDID="$device" bash "$SCRIPT_DIR/backup_photos_v3.sh"
    local photo_rc=$?

    if [[ "$video_rc" -eq 0 && "$photo_rc" -eq 0 ]]; then
        write_status "done" "$device" "video_rc=0 photo_rc=0"
        notify "iPhone Backup Complete" "Video and photo backups finished successfully."
        return 0
    fi

    write_status "failed" "$device" "video_rc=$video_rc photo_rc=$photo_rc"
    notify "iPhone Backup Warning" "Video returned $video_rc, photo returned $photo_rc. Check /tmp/iphone_* logs."
    return 1
}

# Acquire daemon lock directory to prevent duplicate instances
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    old_pid=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        exit 0
    fi
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT

previous_state=$(grep '^state=' "$STATUS_FILE" 2>/dev/null | cut -d= -f2- || true)
previous_device=$(grep '^device=' "$STATUS_FILE" 2>/dev/null | cut -d= -f2- || true)
last_device=""
backed_up_device=""
last_backup_ts=0

# Avoid re-scanning on daemon restart if device remains connected from prior session
if [[ ( "$previous_state" == "watching_connected" || "$previous_state" == "done" ) && -n "$previous_device" ]]; then
    last_device="$previous_device"
    backed_up_device="$previous_device"
fi

trust_notice_at=0
write_status "watching" "" "interval=${IPHONE_MONITOR_INTERVAL}s same_conn=${IPHONE_SAME_CONN}"

# Main polling loop
while true; do
    current="$(devices)"
    if [[ -z "$current" ]]; then
        if [[ -n "$last_device" ]]; then
            write_status "watching" "" "device disconnected"
        fi
        rm -f "$TRIGGER_FILE"
        last_device=""
        backed_up_device=""
        last_backup_ts=0
        trust_notice_at=0
        sleep "$IPHONE_MONITOR_INTERVAL"
        continue
    fi

    last_device="$current"
    if ! trusted "$current"; then
        now=$(date +%s)
        write_status "waiting_trust" "$current" "unlock iPhone and trust this computer"
        if (( now - trust_notice_at >= 60 )); then
            notify "iPhone Awaiting Trust" "Please unlock your iPhone and tap 'Trust This Computer'."
            trust_notice_at=$now
        fi
        sleep "$IPHONE_MONITOR_INTERVAL"
        continue
    fi

    # Manual backup trigger: consuming trigger file forces an immediate backup pass
    if [[ -f "$TRIGGER_FILE" ]]; then
        rm -f "$TRIGGER_FILE"
        backed_up_device=""
        notify "Manual Backup Triggered" "Starting backup pass (already backed up files are skipped instantly)."
    fi

    now_ts=$(date +%s)
    if [[ "$current" != "$backed_up_device" ]]; then
        run_backups "$current" || true
        backed_up_device="$current"
        last_backup_ts=$(date +%s)
    elif [[ "$IPHONE_SAME_CONN" == "resync" ]] && (( now_ts - last_backup_ts >= IPHONE_RESYNC_INTERVAL )); then
        write_status "resync_check" "$current" "checking for new files (resync interval)"
        run_backups "$current" || true
        last_backup_ts=$(date +%s)
    else
        if [[ "$IPHONE_SAME_CONN" == "resync" ]]; then
            remaining=$(( IPHONE_RESYNC_INTERVAL - (now_ts - last_backup_ts) ))
            write_status "watching_connected" "$current" "already backed up this connection; resync in ${remaining}s"
        else
            write_status "watching_connected" "$current" "already backed up this connection; manual trigger or re-plug to run again"
        fi
    fi

    sleep "$IPHONE_MONITOR_INTERVAL"
done
