#!/bin/bash
# ==============================================================================
# iPhone Auto Backup - Safe Copy Utility (v1 Legacy)
# Author: Vaibhav Bhootna
# Repository: https://github.com/vbv611/iphone-auto-backup
#
# Legacy helper (not scheduled by launchd). Copies new files into flat root
# directories without date sorting or content-hash deduplication.
# For production backups, use backup_videos_v3.sh and backup_photos_v3.sh.
# ==============================================================================

set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

TMP_DIR="$(mktemp -d -t iphone_safe_backup_XXXXXX 2>/dev/null || mktemp -d /tmp/iphone_safe_backup_XXXXXX)"
chmod 700 "$TMP_DIR"

if config_has_placeholders; then
    echo "[ERR] config.sh still has YourExternalDrive placeholders; edit BACKUP_ROOT and PHOTO_BACKUP_ROOT first."
    exit 1
fi
if ! vol=$(ensure_backup_root "$BACKUP_ROOT"); then
    echo "[ERR] Video backup disk not mounted: $vol"
    exit 1
fi
if ! vol=$(ensure_backup_root "$PHOTO_BACKUP_ROOT"); then
    echo "[ERR] Photo backup disk not mounted: $vol"
    exit 1
fi

LOCKDIR="/tmp/iphone_safe_backup.lockdir"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    echo "[INFO] Backup already in progress, exiting."
    exit 0
fi

caffeinate -dims -t 0 &
CAFFPID=$!
cleanup() {
    kill "$CAFFPID" 2>/dev/null || true
    rm -rf "$LOCKDIR" "$TMP_DIR"
}
trap cleanup EXIT

# Verify iPhone connection and trust
PAIR_OK=$("$IDEVICEPAIR" pair 2>&1 | grep -ciE "success|paired|already" || true)
if [[ "$PAIR_OK" -eq 0 ]]; then
    echo "[ERR] iPhone not connected or not trusted. Please unlock and trust."
    exit 0
fi
echo "[OK] iPhone connected and verified."

mkdir -p "$TMP_DIR" "$BACKUP_ROOT" "$PHOTO_BACKUP_ROOT"

echo "Scanning iPhone camera roll..."
ALL_DIRS=$("$AFCCLIENT" list /DCIM 2>/dev/null | grep -E '^[0-9]+APPLE$' || true)

# Collect pending files
TODO_VIDEO=""
TODO_PHOTO=""
while IFS= read -r D; do
    [[ -z "$D" ]] && continue
    FILES=$("$AFCCLIENT" list "/DCIM/$D" 2>/dev/null || true)
    while IFS= read -r F; do
        [[ -z "$F" ]] && continue
        EXT=$(echo "${F##*.}" | tr '[:lower:]' '[:upper:]')
        # Only process files that do not exist at the target root
        case "$EXT" in
            MOV|MP4|M4V|3GP)
                [[ ! -f "$BACKUP_ROOT/$F" ]] && TODO_VIDEO="$TODO_VIDEO$F|$D"$'\n'
                ;;
            JPG|JPEG|HEIC|PNG|GIF|DNG)
                [[ ! -f "$PHOTO_BACKUP_ROOT/$F" ]] && TODO_PHOTO="$TODO_PHOTO$F|$D"$'\n'
                ;;
        esac
    done <<< "$FILES"
done <<< "$ALL_DIRS"

COUNT_V=$(echo "$TODO_VIDEO" | grep -c '|' || true)
COUNT_P=$(echo "$TODO_PHOTO" | grep -c '|' || true)
echo "Pending media: Videos: $COUNT_V / Photos: $COUNT_P"

# Transfer files using copy without overwrite
backup_files() {
    local LIST="$1" DST="$2" TYPE="$3"
    local COPIED=0 SKIPPED=0 FAILED=0 IDX=0 TOTAL=0
    TOTAL=$(echo "$LIST" | grep -c '|' || true)
    [[ "$TOTAL" -eq 0 ]] && { echo "$TYPE: None to back up"; return; }

    while IFS= read -r E; do
        [[ -z "$E" ]] && continue
        ((IDX++)) || true
        FNAME="${E%|*}"; DIR="${E#*|}"
        printf "\r  %3d%% | %d/%d  %s" "$((IDX*100/TOTAL))" "$IDX" "$TOTAL" "$FNAME"

        # Safety check: skip if destination file already exists
        [[ -f "$DST/$FNAME" ]] && { ((SKIPPED++)) || true; continue; }

        # Download from device
        "$AFCCLIENT" get "/DCIM/$DIR/$FNAME" "$TMP_DIR/$FNAME" 2>/dev/null || { ((FAILED++)) || true; continue; }

        # Copy to destination ensuring no overwrite
        if [[ ! -f "$DST/$FNAME" ]] && cp "$TMP_DIR/$FNAME" "$DST/$FNAME" 2>/dev/null; then
            rm -f "$TMP_DIR/$FNAME"
            ((COPIED++)) || true
        else
            rm -f "$TMP_DIR/$FNAME"
            ((FAILED++)) || true
        fi
    done <<< "$LIST"
    echo ""
    echo "$TYPE: Added $COPIED / Skipped $SKIPPED / Failed $FAILED"
}

echo "=== Videos ==="
backup_files "$TODO_VIDEO" "$BACKUP_ROOT" "Videos"
echo "=== Photos ==="
backup_files "$TODO_PHOTO" "$PHOTO_BACKUP_ROOT" "Photos"

rm -rf "$TMP_DIR" 2>/dev/null || true
echo "=== Complete ==="
echo "Video directory: $(find "$BACKUP_ROOT" -type f 2>/dev/null | wc -l) files"
echo "Photo directory: $(find "$PHOTO_BACKUP_ROOT" -type f 2>/dev/null | wc -l) files"
