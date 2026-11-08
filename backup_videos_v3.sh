#!/bin/bash
# ==============================================================================
# iPhone Auto Backup - Video Backup Engine (v3.7)
# Author: Vaibhav Bhootna
# Repository: https://github.com/vbv611/iphone-auto-backup
#
# Key Features:
#   - Quality-first AFC extraction over USB (libimobiledevice)
#   - Partial SHA1 content-hash deduplication (512KB head + 512KB tail + size)
#   - Hardware UDID-isolated incremental pre-filtering (device_seen)
#   - Chronological EXIF date organization (YYYY-MM-DD)
#   - High-performance O(1) sequence calculation in pure Bash
#   - Sleep prevention via macOS caffeinate
#   - Strict security hardening (umask 077, private temp directories)
# ==============================================================================

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

# ---------- Paths & Storage ----------
STATE_FILE="$HOME/.iphone_video_backup_v3.state"
HASH_INDEX="$HOME/.iphone_video_backup_v3.hashes"
DEVICE_SEEN="$HOME/.iphone_video_backup_v3.device_seen"
TMP_DIR="$(mktemp -d -t iphone_video_backup_XXXXXX 2>/dev/null || mktemp -d /tmp/iphone_video_backup_XXXXXX)"
chmod 700 "$TMP_DIR"

# ---------- Concurrency Lock (Atomic mkdir) ----------
LOCKDIR="/tmp/iphone_video_backup_v3.lockdir"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    _lock_pid=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "")
    if [[ -n "$_lock_pid" ]] && kill -0 "$_lock_pid" 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] [INFO] Video backup already running (PID $_lock_pid), exiting."
        exit 0
    fi
    # Stale lock cleanup
    rm -rf "$LOCKDIR"
    if ! mkdir "$LOCKDIR" 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] [INFO] Video backup lock claimed by another process, exiting."
        exit 0
    fi
fi
echo $$ > "$LOCKDIR/pid"

cleanup_on_exit() {
    restore_sleep
    rm -rf "$LOCKDIR"
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup_on_exit EXIT

# ---------- Terminal Styling ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
prok()  { echo -e "${GREEN}[OK]${NC} $*"; }
prskip(){ echo -e "${YELLOW}[SKIP]${NC} $*"; }
prerr() { echo -e "${RED}[ERR]${NC} $*"; }
prwarn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
pr()    { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }

# Display native macOS notification using positional arguments
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

# ---------- Tool & Device Helpers ----------
afc() {
    if [[ -n "${IPHONE_UDID:-}" ]]; then
        "$AFCCLIENT" -u "$IPHONE_UDID" "$@"
    else
        "$AFCCLIENT" "$@"
    fi
}

pair_check() {
    if [[ -n "${IPHONE_UDID:-}" ]]; then
        "$IDEVICEPAIR" -u "$IPHONE_UDID" pair 2>&1
    else
        "$IDEVICEPAIR" pair 2>&1
    fi
}

device_key() {
    local dpath="$1" size="$2"
    if [[ -n "${IPHONE_UDID:-}" ]]; then
        printf '%s|%s|%s\n' "$IPHONE_UDID" "$dpath" "$size"
    else
        printf '%s|%s\n' "$dpath" "$size"
    fi
}

get_max_seq_for_dir() {
    local tdir="$1"
    local max=0 _f _bn _num
    for _f in "$tdir"/*; do
        [[ -f "$_f" ]] || continue
        _bn="${_f##*/}"
        if [[ "$_bn" =~ ^([0-9]+) ]]; then
            _num="${BASH_REMATCH[1]}"
            _num=$((10#$_num))
            (( _num > max )) && max=$_num
        fi
    done
    echo "$max"
}

other_iphone_backup_running() {
    pgrep -f "backup_photos_v3.sh" >/dev/null 2>&1
}

run_media_index_if_ready() {
    local copied="$1"; local failed="$2"
    local pending_flag="/tmp/iphone_media_index.pending"

    if [[ "${AUTO_REFRESH_INDEX:-0}" != "1" ]]; then
        save_field "phase" "done"
        return 0
    fi
    if [[ "$failed" -gt 0 ]]; then
        save_field "phase" "done_unindexed"
        notify "iPhone Media Index Paused" "Video backup had $failed failure(s). Resolve failed files before indexing."
        return 0
    fi
    if [[ "$copied" -gt 0 ]]; then
        echo "video $(date '+%Y-%m-%dT%H:%M:%S') copied=$copied" >> "$pending_flag"
    fi
    if [[ ! -f "$pending_flag" ]]; then
        save_field "phase" "done"
        return 0
    fi
    if other_iphone_backup_running; then
        save_field "phase" "waiting_sibling_for_index"
        notify "Pipeline Waiting" "Videos backed up; waiting for photo backup to complete before indexing."
        return 0
    fi

    local refresh="$SCRIPT_DIR/refresh_index.sh"
    if [[ ! -x "$refresh" ]]; then
        save_field "phase" "index_missing"
        notify "Media Index Skipped" "refresh_index.sh not found; backup finished."
        return 1
    fi

    local index_lock="/tmp/iphone_media_index.lockdir"
    if ! mkdir "$index_lock" 2>/dev/null; then
        save_field "phase" "index_already_running"
        notify "Media Index Active" "Videos backed up; indexing is already in progress."
        return 0
    fi
    trap 'restore_sleep; rm -rf "$LOCKDIR"; rm -rf /tmp/iphone_media_index.lockdir' EXIT

    save_field "phase" "indexing"
    notify "Media Index Started" "$copied video(s) added; starting automated indexing."
    pr "AUTO_REFRESH_INDEX=1 -> running media index refresh"
    if "$refresh"; then
        save_field "phase" "done_indexed"
        notify "Pipeline Finished" "Video backup and media index refreshed successfully."
        rm -f "$pending_flag"
        rm -rf "$index_lock"
        return 0
    fi

    save_field "phase" "index_failed"
    notify "Media Index Failed" "Video backup succeeded, but index refresh failed. Check logs."
    rm -f "$pending_flag"
    rm -rf "$index_lock"
    return 1
}

# ---------- Sleep Prevention ----------
CAFFEINATE_PID=""
prevent_sleep() {
    caffeinate -dims -t 0 &
    CAFFEINATE_PID=$!
    pr "Mac sleep prevented (caffeinate PID $CAFFEINATE_PID)"
}
restore_sleep() {
    if [[ -n "$CAFFEINATE_PID" ]]; then
        kill "$CAFFEINATE_PID" 2>/dev/null || true
        CAFFEINATE_PID=""
    fi
}

# ---------- Progress Bar ----------
draw_bar() {
    local cur="$1"; local tot="$2"; local name="$3"
    (( tot == 0 )) && tot=1
    local pct=$(( cur * 100 / tot ))
    local wid=24; local fill=$(( cur * wid / tot )); local empty=$(( wid - fill ))
    printf "\r  %3d%% |%${fill}s%${empty}s| %d/%d  %s" "$pct" "" "" "$cur" "$tot" "$name"
}
clear_bar() { printf "\r%68s\r" ""; }

# ---------- State Persistence ----------
save_field() {
    local key="$1"; local val="$2"
    local tmp; tmp=$(mktemp)
    grep -v "^${key}=" "$STATE_FILE" >> "$tmp" 2>/dev/null || true
    echo "${key}=${val}" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
}

write_progress_state() {
    local phase="$1" processed="$2" total="$3" current="$4" copied="$5" skipped="$6" failed="$7"
    local tmp; tmp=$(mktemp)
    {
        echo "phase=$phase"
        echo "processed=$processed"
        echo "total=$total"
        echo "current_file=$current"
        echo "copied=$copied"
        echo "skipped=$skipped"
        echo "failed=$failed"
        echo "started_at=${PROGRESS_STARTED_AT:-}"
        echo "updated_at=$(date '+%Y-%m-%dT%H:%M:%S')"
    } > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

get_field() {
    local key="$1"
    grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2- || echo ""
}

touch_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    mkdir -p "$TMP_DIR"
    chmod 700 "$TMP_DIR"
    touch "$HASH_INDEX"
    touch "$DEVICE_SEEN"
    : > "$TMP_DIR/.run_done"
}

# ---------- Content Hashing ----------
compute_hash() {
    local f="$1"
    local size; size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
    local head tail
    head=$(head -c 524288 "$f" | shasum | cut -d' ' -f1)
    tail=$(tail -c 524288 "$f" | shasum | cut -d' ' -f1)
    echo "${size}_${head}_${tail}"
}

hash_seen() {
    local h="$1"
    grep -qx "$h" "$HASH_INDEX" 2>/dev/null
}
hash_record() {
    echo "$1" >> "$HASH_INDEX"
}

# ---------- Device Metadata (afcclient info) ----------
device_info() {
    local dpath="$1"
    local out size mtns mts=""
    out=$(afc info "$dpath" 2>/dev/null) || return 1
    size=$(printf '%s' "$out" | sed -n 's/.*"st_size":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
    mtns=$(printf '%s' "$out" | sed -n 's/.*"st_mtime":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
    [[ -n "$size" ]] || return 1
    if [[ -n "$mtns" ]]; then
        if (( ${#mtns} > 10 )); then mts="${mtns:0:10}"; else mts="$mtns"; fi
    fi
    printf '%s|%s\n' "$size" "$mts"
}

device_seen() {
    grep -qxF "$1" "$DEVICE_SEEN" 2>/dev/null
}
device_record() {
    echo "$1" >> "$DEVICE_SEEN"
}

# ---------- Date Parsing (EXIF -> Filename -> Device mtime -> _unknown_date) ----------
get_video_date() {
    local fp="$1"
    local dev_mtime="${2:-}"
    local d=""

    d=$("$EXIFTOOL" -CreateDate -s3 -d "%Y-%m-%d" "$fp" 2>/dev/null | head -1)
    if [[ -n "$d" && "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "$d"; return
    fi

    d=$("$EXIFTOOL" -MediaCreateDate -s3 -d "%Y-%m-%d" "$fp" 2>/dev/null | head -1)
    if [[ -n "$d" && "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "$d"; return
    fi

    local bn; bn=$(basename "$fp")
    local ds
    ds=$(expr "$bn" : 'IMG_\([0-9]\{8\}\)_' 2>/dev/null || true)
    if [[ -n "$ds" && ${#ds} -eq 8 ]]; then
        echo "${ds:0:4}-${ds:4:2}-${ds:6:2}"; return
    fi

    # Fallback to device-side modification timestamp
    if [[ -n "$dev_mtime" && "$dev_mtime" =~ ^[0-9]{9,10}$ ]]; then
        d=$(date -r "$dev_mtime" '+%Y-%m-%d' 2>/dev/null || true)
        if [[ -n "$d" && "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            echo "$d"; return
        fi
    fi

    echo "_unknown_date"
}

# ---------- Timestamp Extraction (touch -t compatible) ----------
get_video_timestamp() {
    local fp="$1"
    local dev_mtime="${2:-}"
    local ts=""
    ts=$("$EXIFTOOL" -CreateDate -s3 -d "%Y%m%d%H%M.%S" "$fp" 2>/dev/null | head -1)
    if [[ -n "$ts" && "$ts" =~ ^[0-9]{12}\.[0-9]{2}$ ]]; then
        echo "$ts"; return
    fi
    ts=$("$EXIFTOOL" -MediaCreateDate -s3 -d "%Y%m%d%H%M.%S" "$fp" 2>/dev/null | head -1)
    if [[ -n "$ts" && "$ts" =~ ^[0-9]{12}\.[0-9]{2}$ ]]; then
        echo "$ts"; return
    fi
    if [[ -n "$dev_mtime" && "$dev_mtime" =~ ^[0-9]{9,10}$ ]]; then
        ts=$(date -r "$dev_mtime" '+%Y%m%d%H%M.%S' 2>/dev/null || true)
        if [[ -n "$ts" ]]; then
            echo "$ts"; return
        fi
    fi
    echo ""
}

# ---------- Format Validation ----------
is_video() {
    local ext="${1##*.}"
    ext=$(echo "$ext" | tr '[:lower:]' '[:upper:]')
    [[ " $VIDEO_EXTENSIONS " == *" $ext "* ]]
}

tmp_path_for() {
    local fname="$1"
    local base
    base="$(basename "$fname")"
    if [[ -z "$base" || "$base" = "." || "$base" = ".." || "$base" != "$fname" ]]; then
        return 1
    fi
    # Reject blank or whitespace-only stems (e.g. " .mov")
    local stem="${base%.*}"
    if [[ -z "${stem//[[:space:]]/}" ]]; then
        return 1
    fi
    printf "%s/%s\n" "$TMP_DIR" "$base"
}

# ---------- Target Directory Cleanup ----------
cleanup_target_dirs() {
    local removed_empty=0
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        rmdir "$d" 2>/dev/null && removed_empty=$((removed_empty + 1)) || true
    done < <(find "$BACKUP_ROOT" -mindepth 1 -type d -empty 2>/dev/null || true)
    if (( removed_empty > 0 )); then
        pr "  Cleanup: removed ${removed_empty} empty folder(s)"
    fi
}

count_backup_files() {
    find "$BACKUP_ROOT" -type f 2>/dev/null | wc -l | tr -d ' '
}

# ---------- Main Execution Flow ----------
main() {
    if config_has_placeholders; then
        prerr "config.sh still has YourExternalDrive placeholder. Please update BACKUP_ROOT."
        notify "iPhone Video Backup Not Configured" "Edit config.sh to specify your mounted disk name."
        exit 1
    fi
    local missing_vol=""
    if ! missing_vol=$(ensure_backup_root "$BACKUP_ROOT"); then
        prerr "Backup volume not mounted or missing: $missing_vol"
        notify "iPhone Video Backup Failed" "External volume not mounted: $missing_vol"
        exit 1
    fi
    touch_state

    # Device connection verification
    if ! pair_check | grep -qiq "success\|paired\|already"; then
        if [[ "${IPHONE_BACKUP_QUIET_NO_DEVICE:-0}" = "1" ]]; then
            exit 0
        fi
        echo ""
        pr "==== iPhone Video Backup v3 ===="
        prerr "iPhone not connected or not trusted. Please connect USB and trust computer."
        pr "  (Exiting cleanly; waiting for next USB connection event)"
        exit 0
    fi

    echo ""
    pr "==== iPhone Video Backup v3 ===="
    prevent_sleep
    prok "iPhone connected"

    # Device & History Resolution
    local dev_details dev_name dev_model safe_dev history_db
    dev_details=$(get_device_details "${IPHONE_UDID:-}")
    dev_name=$(echo "$dev_details" | head -n 1)
    dev_model=$(echo "$dev_details" | tail -n 1)
    safe_dev=$(sanitize_device_name "$dev_name")
    prok "Device: $dev_name ($dev_model) | Tag: $safe_dev"

    history_db=$(resolve_history_db "$BACKUP_ROOT")
    init_history_db "$history_db"

    # Stage 1: Device Scan
    PROGRESS_STARTED_AT=$(date '+%Y-%m-%dT%H:%M:%S')
    write_progress_state "scanning" 0 0 "" 0 0 0
    pr "Scanning iPhone camera roll for videos..."

    local iphone_videos=()
    local total=0

    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            if is_video "$f"; then
                iphone_videos+=("/DCIM/$dir/$f"$'\t'"$f")
                ((total++)) || true
            fi
        done < <(afc list "/DCIM/$dir" 2>/dev/null || true)
    done < <(afc list /DCIM 2>/dev/null | grep -E '^[0-9]+APPLE$' || true)

    prok "Found ${total} video(s)"
    write_progress_state "downloading" 0 "$total" "" 0 0 0

    cleanup_target_dirs

    # Stage 2: Process Files
    local copied=0 skipped=0 failed=0 prefilter_skipped=0
    local -a fail_names fail_reasons
    local -a new_files
    local idx=0
    local LAST_TARGET_DIR=""
    local LAST_MAX_SEQ=-1

    for entry in "${iphone_videos[@]}"; do
        ((idx++)) || true
        local src_path fname
        src_path="${entry%$'\t'*}"
        fname="${entry#*$'\t'}"
        draw_bar "$idx" "$total" "$fname"
        write_progress_state "downloading" "$idx" "$total" "$fname" "$copied" "$skipped" "$failed"

        # Staging path validation
        local tmp_path
        if ! tmp_path=$(tmp_path_for "$fname"); then
            fail_names+=("$fname")
            fail_reasons+=("Invalid filename, skipped")
            ((failed++)) || true
            clear_bar
            continue
        fi

        # Device-side metadata
        local dev_size="" dev_mtime="" dinfo=""
        if dinfo=$(device_info "$src_path"); then
            dev_size="${dinfo%%|*}"
            dev_mtime="${dinfo##*|}"
        fi

        local dkey=""
        if [[ -n "$dev_size" ]]; then
            dkey=$(device_key "$src_path" "$dev_size")
        fi

        # Incremental pre-filter: skip download if path, size, and UDID matched previous run
        if [[ -n "$dkey" ]] && device_seen "$dkey"; then
            ((skipped++)) || true
            ((prefilter_skipped++)) || true
            clear_bar
            continue
        fi

        # Download via AFC
        if ! afc get "$src_path" "$tmp_path" 2>/dev/null; then
            fail_names+=("$fname")
            fail_reasons+=("Download failed (USB disconnected or file missing)")
            ((failed++)) || true
            clear_bar
            continue
        fi

        # Integrity verification: compare downloaded size against device size
        local fsize; fsize=$(stat -f%z "$tmp_path" 2>/dev/null || stat -c%s "$tmp_path" 2>/dev/null || echo 0)
        if [[ -n "$dev_size" ]] && (( fsize != dev_size )); then
            rm -f "$tmp_path"
            afc get "$src_path" "$tmp_path" 2>/dev/null || true
            fsize=$(stat -f%z "$tmp_path" 2>/dev/null || stat -c%s "$tmp_path" 2>/dev/null || echo 0)
            if (( fsize != dev_size )); then
                fail_names+=("$fname")
                fail_reasons+=("Download incomplete (Local: ${fsize}B != Device: ${dev_size}B; retry failed)")
                rm -f "$tmp_path"
                ((failed++)) || true
                clear_bar
                continue
            fi
        fi

        # Content-hash deduplication
        local h; h=$(compute_hash "$tmp_path")
        if hash_seen "$h"; then
            prskip "Duplicate content: $fname"
            rm -f "$tmp_path"
            [[ -n "$dkey" ]] && device_record "$dkey"
            ((skipped++)) || true
            clear_bar
            continue
        fi

        # Sanity check: minimum file size
        if (( fsize < 1024 )); then
            fail_names+=("$fname")
            fail_reasons+=("File corrupted (${fsize}B < 1KB)")
            rm -f "$tmp_path"
            ((failed++)) || true
            clear_bar
            continue
        fi

        # Extract capture date and precise timestamp
        local video_date; video_date=$(get_video_date "$tmp_path" "$dev_mtime")
        local ts; ts=$(get_video_timestamp "$tmp_path" "$dev_mtime")

        local compact_ts human_ts
        if [[ -n "$ts" && "$ts" =~ ^[0-9]{12}\.[0-9]{2}$ ]]; then
            compact_ts="${ts:0:8}_${ts:8:4}${ts:13:2}"
            human_ts="${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:8:2}:${ts:10:2}:${ts:13:2}"
        else
            compact_ts="${video_date//-/}_000000"
            human_ts="$video_date 00:00:00"
        fi

        # Archive to target directory
        local target_dir="$BACKUP_ROOT/$video_date"
        mkdir -p "$target_dir"

        local ext="${fname##*.}"
        local new_name target_path

        case "${FILENAME_FORMAT:-timestamp_device_original}" in
            timestamp_device_original)
                new_name="${compact_ts}_${safe_dev}_${fname}"
                ;;
            timestamp_original)
                new_name="${compact_ts}_${fname}"
                ;;
            device_original)
                new_name="${safe_dev}_${fname}"
                ;;
            original)
                new_name="${fname}"
                ;;
            sequential|*)
                local seq
                if [[ "$target_dir" == "$LAST_TARGET_DIR" && "$LAST_MAX_SEQ" -ge 0 ]]; then
                    LAST_MAX_SEQ=$((LAST_MAX_SEQ + 1))
                    seq=$LAST_MAX_SEQ
                else
                    LAST_TARGET_DIR="$target_dir"
                    LAST_MAX_SEQ=$(get_max_seq_for_dir "$target_dir")
                    LAST_MAX_SEQ=$((LAST_MAX_SEQ + 1))
                    seq=$LAST_MAX_SEQ
                fi
                local low_ext; low_ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
                printf -v new_name "%03d.%s" "$seq" "$low_ext"
                ;;
        esac

        target_path="$target_dir/$new_name"

        # Resolve any collisions automatically
        if [[ -e "$target_path" ]]; then
            local cur_stem="${new_name%.*}"
            local cur_ext="${new_name##*.}"
            local c_idx=1
            while [[ -e "$target_dir/${cur_stem}_$(printf '%02d' $c_idx).${cur_ext}" ]]; do
                ((c_idx++)) || true
            done
            new_name="${cur_stem}_$(printf '%02d' $c_idx).${cur_ext}"
            target_path="$target_dir/$new_name"
        fi

        if mv "$tmp_path" "$target_path" 2>/dev/null; then
            new_files+=("$video_date/$new_name")
            hash_record "$h"
            [[ -n "$dkey" ]] && device_record "$dkey"
            ((copied++)) || true

            # Set file mtime to capture timestamp
            if [[ -n "$ts" ]]; then
                touch -t "$ts" "$target_path" 2>/dev/null || true
            fi

            # Record in persistent SQLite history database
            record_backup_history "$history_db" \
                "$video_date/$new_name" \
                "$fname" \
                "video" \
                "Videos" \
                "$dev_name" \
                "$dev_model" \
                "${IPHONE_UDID:-}" \
                "$human_ts" \
                "$fsize" \
                "$h"

            # Attach macOS extended attributes (zero-byte impact)
            if command -v xattr >/dev/null 2>&1; then
                xattr -w user.original_filename "$fname" "$target_path" 2>/dev/null || true
                xattr -w user.device_name "$dev_name" "$target_path" 2>/dev/null || true
                xattr -w com.apple.metadata:kMDItemOriginator "$dev_name" "$target_path" 2>/dev/null || true
            fi
        else
            fail_names+=("$fname")
            fail_reasons+=("Archive failed (mv permission denied: $target_path)")
            rm -f "$tmp_path"
            ((failed++)) || true
        fi

        clear_bar
        prok "$fname -> $video_date/$new_name"
    done

    write_progress_state "done" "$total" "$total" "" "$copied" "$skipped" "$failed"
    cleanup_target_dirs
    restore_sleep

    # Summary Report
    local total_backup; total_backup=$(count_backup_files)

    echo ""
    echo "======================================================================"
    echo "                    iPhone Video Backup Report"
    echo "                    Author: Vaibhav Bhootna"
    echo "======================================================================"
    printf "%-14s %s\n" "Destination:" "$BACKUP_ROOT"
    printf "%-14s %s\n" "Total:" "$total_backup video file(s)"
    printf "%-14s ${GREEN}%s${NC}\n" "New:" "$copied video(s)"
    printf "%-14s ${YELLOW}%s${NC}\n" "Skipped:" "$skipped ($prefilter_skipped skipped instantly via pre-filter)"
    printf "%-14s ${RED}%s${NC}\n" "Failed:" "$failed video(s)"
    echo ""

    if (( copied > 0 )); then
        echo "Newly Added Files:"
        for nf in "${new_files[@]}"; do
            echo "  -> $BACKUP_ROOT/$nf"
        done
        echo ""
    fi

    if (( failed > 0 )); then
        echo "Failure Details:"
        for i in "${!fail_names[@]}"; do
            echo -e "  ${RED}✗${NC} ${fail_names[$i]}"
            echo "    Reason: ${fail_reasons[$i]}"
        done
        echo ""
    fi

    echo "----------------------------------------------------------------------"
    echo "Operational Notes:"
    if (( failed > 0 )); then
        echo "  - Ensure iPhone remains unlocked and USB connection is stable."
        echo "  - Avoid navigating albums or modifying media during backup."
    fi
    if (( skipped == 0 && copied == 0 && total > 0 )); then
        echo "  - All videos are up to date. No new media detected."
    fi
    if (( total == 0 )); then
        echo "  - No videos found in DCIM. Check if media is offloaded to iCloud."
    fi
    echo "======================================================================"
    echo ""

    if (( copied > 0 )) && [[ "${AUTO_EXPORT_MANIFEST:-1}" == "1" ]]; then
        export_editor_manifest "$history_db" "$BACKUP_ROOT/editor_manifest.csv"
        prok "Editor manifest updated: $BACKUP_ROOT/editor_manifest.csv"
    fi

    rm -rf "$TMP_DIR" 2>/dev/null || true
    notify "iPhone Video Backup Finished" "Added: ${copied} | Skipped: ${skipped} | Failed: ${failed}"
    run_media_index_if_ready "$copied" "$failed"
}

main "$@"
