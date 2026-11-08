#!/bin/bash
# shellcheck disable=SC2034
# ==============================================================================
# iPhone Auto Backup - Configuration File
# Author: Vaibhav Bhootna
# Repository: https://github.com/vbv611/iphone-auto-backup
#
# This file defines destination directories, supported file formats, execution
# hooks, and dynamic binary paths. It is sourced by all backup scripts.
# ==============================================================================

# Target directory for video backups.
# Point this to your mounted external drive (e.g. /Volumes/MyExternalDrive/iPhone_Videos).
# NOTE: The installer will refuse to proceed if 'YourExternalDrive' placeholder remains.
: "${BACKUP_ROOT:=/Volumes/My Passport/iPhone_Videos}"

# Target directory for photo backups.
# Point this to your mounted external drive (e.g. /Volumes/MyExternalDrive/iPhone_Photos).
: "${PHOTO_BACKUP_ROOT:=/Volumes/My Passport/iPhone_Photos}"

# Normalize accidental double-nesting if callers pass a subpath
while [[ "$BACKUP_ROOT" == */iPhone_Videos/iPhone_Videos ]]; do
    BACKUP_ROOT="${BACKUP_ROOT%/iPhone_Videos}"
done
while [[ "$PHOTO_BACKUP_ROOT" == */iPhone_Photos/iPhone_Photos ]]; do
    PHOTO_BACKUP_ROOT="${PHOTO_BACKUP_ROOT%/iPhone_Photos}"
done

# Space-separated list of supported video file extensions (case-insensitive).
: "${VIDEO_EXTENSIONS:=MOV MP4 M4V 3GP AVI MKV}"

# Space-separated list of supported photo file extensions (case-insensitive).
# Includes Apple ProRAW DNG files.
: "${PHOTO_EXTENSIONS:=JPG JPEG HEIC PNG GIF DNG}"

is_video() {
    local ext="${1##*.}"
    ext=$(echo "$ext" | tr '[:lower:]' '[:upper:]')
    [[ " $VIDEO_EXTENSIONS " == *" $ext "* ]]
}

is_photo() {
    local ext="${1##*.}"
    ext=$(echo "$ext" | tr '[:lower:]' '[:upper:]')
    [[ " $PHOTO_EXTENSIONS " == *" $ext "* ]]
}

# Post-backup indexing hook:
# 1 = Run refresh_index.sh (if present in the script directory) after successful backup.
# 0 = Disabled (default).
: "${AUTO_REFRESH_INDEX:=0}"

# Filename naming strategy:
# "timestamp_device_original" (default, recommended):
#     e.g. 20261106_143205_Vaibhavs_iPhone_IMG_4521.mov
#     Ensures zero filename collisions when handing assets to video/photo editors.
# "timestamp_original": e.g. 20261106_143205_IMG_4521.mov
# "device_original":    e.g. Vaibhavs_iPhone_IMG_4521.mov
# "original":           e.g. IMG_4521.mov (with automatic collision suffixes if needed)
# "sequential":         Legacy mode (e.g. 001.mov)
: "${FILENAME_FORMAT:=timestamp_device_original}"

# Custom path to SQLite backup history database.
# If empty (default), automatically placed at the volume root of the backup directory:
# e.g. /Volumes/My Passport/.iphone_backup_history.sqlite3
: "${BACKUP_HISTORY_DB:=}"

# Automatically export / refresh an editor-friendly CSV manifest (1 = enabled, 0 = disabled)
: "${AUTO_EXPORT_MANIFEST:=1}"

# ── Dynamic Tool Paths ──
# Auto-detected across Apple Silicon (/opt/homebrew/bin), Intel Mac (/usr/local/bin),
# and general system PATH. Override these environment variables if installed elsewhere.
: "${AFCCLIENT:=}"
: "${IDEVICEPAIR:=}"
: "${IDEVICE_ID:=}"
: "${EXIFTOOL:=}"
: "${IDEVICEINFO:=}"
: "${IDEVICENAME:=}"
: "${SQLITE3:=}"

# ==============================================================================
# Internal Helper Functions
# ==============================================================================

# Resolve the absolute path to a required CLI executable.
# Arguments:
#   $1 - Binary executable name (e.g., 'afcclient')
#   $2 - Current explicit path override, if any
# Returns:
#   Outputs resolved path to stdout and returns 0.
_iphone_resolve_tool() {
    local name="$1"
    local current="${2:-}"
    if [[ -n "$current" && -x "$current" ]]; then
        printf '%s\n' "$current"
        return 0
    fi
    if [[ -x "/opt/homebrew/bin/$name" ]]; then
        printf '%s\n' "/opt/homebrew/bin/$name"
        return 0
    fi
    if [[ -x "/usr/local/bin/$name" ]]; then
        printf '%s\n' "/usr/local/bin/$name"
        return 0
    fi
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    # Predictable default so error messages stay informative before installation
    printf '%s\n' "/opt/homebrew/bin/$name"
}

AFCCLIENT="$(_iphone_resolve_tool afcclient "${AFCCLIENT:-}")"
IDEVICEPAIR="$(_iphone_resolve_tool idevicepair "${IDEVICEPAIR:-}")"
IDEVICE_ID="$(_iphone_resolve_tool idevice_id "${IDEVICE_ID:-}")"
EXIFTOOL="$(_iphone_resolve_tool exiftool "${EXIFTOOL:-}")"
IDEVICEINFO="$(_iphone_resolve_tool ideviceinfo "${IDEVICEINFO:-}")"
IDEVICENAME="$(_iphone_resolve_tool idevicename "${IDEVICENAME:-}")"
SQLITE3="$(_iphone_resolve_tool sqlite3 "${SQLITE3:-}")"

# Check if configuration still contains unconfigured template placeholders.
# Returns:
#   0 if placeholders are detected, 1 otherwise.
config_has_placeholders() {
    [[ "$BACKUP_ROOT" == *YourExternalDrive* || "$PHOTO_BACKUP_ROOT" == *YourExternalDrive* ]]
}

# Determine the parent volume mount point that must exist before creating folders.
# Arguments:
#   $1 - Full root target path (e.g. /Volumes/MyDisk/Photos)
# Returns:
#   Outputs the volume path (e.g. /Volumes/MyDisk) to stdout.
backup_root_volume() {
    local root="$1"
    if [[ "$root" == /Volumes/* ]]; then
        local name="${root#/Volumes/}"
        name="${name%%/*}"
        printf '%s\n' "/Volumes/$name"
        return 0
    fi
    printf '%s\n' "$(dirname "$root")"
}

# Validate and initialize the backup target directory.
# For paths located under /Volumes/, this requires the underlying volume to be
# actively mounted to avoid accidentally creating fake mount directories on the Mac boot disk.
# Arguments:
#   $1 - Target root path
# Returns:
#   0 on success; 1 on failure (with missing path written to stdout).
ensure_backup_root() {
    local root="$1"
    local vol
    vol="$(backup_root_volume "$root")"
    if [[ "$root" == /Volumes/* && ! -d "$vol" ]]; then
        printf '%s\n' "$vol"
        return 1
    fi
    if ! mkdir -p "$root"; then
        printf '%s\n' "$root"
        return 1
    fi
    return 0
}

# Compute partial SHA1 content hash identical across the backup ecosystem.
# (File size + first 512KB + last 512KB)
compute_hash() {
    local f="$1"
    local size; size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
    local head tail
    head=$(head -c 524288 "$f" | shasum | cut -d' ' -f1)
    tail=$(tail -c 524288 "$f" | shasum | cut -d' ' -f1)
    echo "${size}_${head}_${tail}"
}

# Convert arbitrary device names to safe, clean ASCII identifiers for filenames.
# Handles unicode quotes, spaces, and punctuation gracefully.
# Arguments:
#   $1 - Raw device name (e.g., "Vaibhav’s iPhone (2)")
# Returns:
#   Clean sanitized string (e.g., "Vaibhavs_iPhone_2")
sanitize_device_name() {
    local str="${1:-iPhone}"
    # Remove single, double, and curly quotes
    str="${str//[\'’\`\"]/}"
    local out=""
    local last_was_sep=0
    for (( i=0; i<${#str}; i++ )); do
        local ch="${str:i:1}"
        if [[ "$ch" =~ [a-zA-Z0-9] ]]; then
            out="${out}${ch}"
            last_was_sep=0
        elif (( last_was_sep == 0 && ${#out} > 0 )); then
            out="${out}_"
            last_was_sep=1
        fi
    done
    out="${out%_}"
    [[ -z "$out" ]] && out="iPhone"
    printf '%s\n' "$out"
}

# Retrieve connected device name and model over USB.
# Arguments:
#   $1 - Device UDID (optional)
# Outputs:
#   Two lines on stdout: 1st line is device name, 2nd line is device model.
get_device_details() {
    local udid="${1:-}"
    local dev_name="iPhone"
    local dev_model="iPhone"

    if [[ -x "$IDEVICEINFO" ]]; then
        local -a u_args=()
        [[ -n "$udid" ]] && u_args=("-u" "$udid")

        local q_name; q_name=$("$IDEVICEINFO" "${u_args[@]}" -k DeviceName 2>/dev/null || true)
        local q_model; q_model=$("$IDEVICEINFO" "${u_args[@]}" -k ProductType 2>/dev/null || true)

        [[ -n "$q_name" ]] && dev_name="$q_name"
        [[ -n "$q_model" ]] && dev_model="$q_model"
    elif [[ -x "$IDEVICENAME" ]]; then
        local -a un_args=()
        [[ -n "$udid" ]] && un_args=("-u" "$udid")
        local q_name; q_name=$("$IDEVICENAME" "${un_args[@]}" 2>/dev/null || true)
        [[ -n "$q_name" ]] && dev_name="$q_name"
    fi

    printf '%s\n%s\n' "$dev_name" "$dev_model"
}

# Resolve location for the SQLite history database.
# Arguments:
#   $1 - Target root path (default: BACKUP_ROOT)
# Returns:
#   Absolute path to .backup_history.sqlite3
resolve_history_db() {
    local target_root="${1:-$BACKUP_ROOT}"
    if [[ -n "${BACKUP_HISTORY_DB:-}" ]]; then
        printf '%s\n' "$BACKUP_HISTORY_DB"
        return 0
    fi
    local vol
    vol="$(backup_root_volume "$target_root")"
    if [[ "$target_root" == /Volumes/* && -d "$vol" ]]; then
        printf '%s\n' "$vol/.iphone_backup_history.sqlite3"
        return 0
    fi
    printf '%s\n' "$HOME/.iphone_backup_history.sqlite3"
}

# Initialize history SQLite database schema and indexes.
# Arguments:
#   $1 - History DB file path
init_history_db() {
    local db="$1"
    [[ -z "$db" ]] && return 0
    local db_dir
    db_dir="$(dirname "$db")"
    mkdir -p "$db_dir" 2>/dev/null || true

    if command -v "$SQLITE3" >/dev/null 2>&1; then
        "$SQLITE3" "$db" <<'SQL' 2>/dev/null || true
CREATE TABLE IF NOT EXISTS backup_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    backup_path TEXT UNIQUE,
    original_filename TEXT NOT NULL,
    media_type TEXT NOT NULL,
    category TEXT,
    device_name TEXT,
    device_model TEXT,
    device_udid TEXT,
    capture_timestamp TEXT,
    file_size INTEGER,
    content_hash TEXT,
    backed_up_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_history_orig_name ON backup_history(original_filename);
CREATE INDEX IF NOT EXISTS idx_history_device ON backup_history(device_name);
CREATE INDEX IF NOT EXISTS idx_history_hash ON backup_history(content_hash);
CREATE INDEX IF NOT EXISTS idx_history_capture ON backup_history(capture_timestamp);
SQL
    fi
}

# Escape single quotes in string values for SQL literal safety.
_sql_escape() {
    printf '%s' "${1:-}" | sed "s/'/''/g"
}

# Record a backup transaction into the history database.
record_backup_history() {
    local db="$1"
    local bpath="$2" orig_fname="$3" mtype="$4" cat="$5"
    local dev_name="$6" dev_model="$7" dev_udid="$8"
    local cap_ts="$9" fsize="${10:-0}" chash="${11:-}"

    [[ -z "$db" ]] && return 0
    command -v "$SQLITE3" >/dev/null 2>&1 || return 0

    local esc_path esc_orig esc_dev esc_model
    esc_path=$(_sql_escape "$bpath")
    esc_orig=$(_sql_escape "$orig_fname")
    esc_dev=$(_sql_escape "$dev_name")
    esc_model=$(_sql_escape "$dev_model")

    "$SQLITE3" "$db" <<SQL 2>/dev/null || true
INSERT OR REPLACE INTO backup_history (
    backup_path, original_filename, media_type, category,
    device_name, device_model, device_udid, capture_timestamp,
    file_size, content_hash
) VALUES (
    '$esc_path', '$esc_orig', '$mtype', '$cat',
    '$esc_dev', '$esc_model', '$dev_udid', '$cap_ts',
    $fsize, '$chash'
);
SQL
}

# Export editor-friendly CSV manifest from history database.
# Arguments:
#   $1 - SQLite DB path
#   $2 - CSV output path
export_editor_manifest() {
    local db="$1"
    local csv_out="$2"
    [[ -z "$db" || ! -f "$db" ]] && return 0
    command -v "$SQLITE3" >/dev/null 2>&1 || return 0

    local csv_dir
    csv_dir="$(dirname "$csv_out")"
    mkdir -p "$csv_dir" 2>/dev/null || true

    "$SQLITE3" -header -csv "$db" <<'SQL' > "$csv_out" 2>/dev/null || true
SELECT
    backup_path AS "Backup Path",
    original_filename AS "Original Filename",
    media_type AS "Media Type",
    category AS "Category",
    device_name AS "Device Name",
    device_model AS "Device Model",
    capture_timestamp AS "Capture Timestamp",
    round(file_size / (1024.0 * 1024.0), 2) AS "File Size (MB)",
    content_hash AS "Content Hash",
    backed_up_at AS "Backed Up At"
FROM backup_history
ORDER BY capture_timestamp ASC;
SQL
}
