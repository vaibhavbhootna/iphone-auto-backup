#!/bin/bash
# ==============================================================================
# iPhone Auto Backup - Existing Media Migration Tool
# Author: Vaibhav Bhootna
# Repository: https://github.com/vbv611/iphone-auto-backup
#
# Migrates existing sequential backups (e.g. 001.mov, 001.heic) to the production
# collision-proof naming format:
#   YYYYMMDD_HHMMSS_<Device>_<OriginalName>.<ext>
#
# Capabilities:
#   1. Restores true original camera roll filenames (e.g. IMG_0212.MOV) by
#      cross-referencing MediaManager's library.sqlite index.
#   2. Reads exact capture timestamps from EXIF / QuickTime metadata.
#   3. Detects camera model from EXIF (e.g. "iPhone 13 Pro") or uses --device override.
#   4. Renames media and companion Apple .AAE edit sidecars in-place.
#   5. Preserves file modification time (mtime = shoot date).
#   6. Stamps native macOS extended attributes (xattr).
#   7. Indexes all existing files into .backup_history.sqlite3.
#   8. Verifies deduplication hashes so future iPhone connections skip them.
#   9. Generates / refreshes editor_manifest.csv for video/photo editors.
#  10. Safe Dry-Run mode enabled by default until --run is passed.
#
# Usage:
#   bash migrate_existing_data.sh [options]
#
# Options:
#   --all                   Migrate both Video and Photo backup directories (default)
#   --videos                Migrate only Video backup directory ($BACKUP_ROOT)
#   --photos                Migrate only Photo backup directory ($PHOTO_BACKUP_ROOT)
#   --dir <path>            Migrate a specific custom folder path
#   --device <name>         Custom device label override (e.g. "Vaibhavs_iPhone")
#                           (Default: Auto-detected from camera model in EXIF metadata)
#   --media-manager-db <p>  Custom path to MediaManager library.sqlite database
#                           (Auto-detected from ~/Library/Application Support/MediaManager/...)
#   --no-media-manager      Skip MediaManager cross-referencing
#   --run                   Execute renaming, database registration, and manifest export
#   --dry-run               Preview all migration changes without modifying files (default)
#   --help, -h              Show this help message
# ==============================================================================

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; }
pr()    { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }

VIDEO_HASH_INDEX="$HOME/.iphone_video_backup_v3.hashes"
PHOTO_HASH_INDEX="$HOME/.iphone_photo_backup_v3.hashes"

show_help() {
    cat <<EOF
iPhone Auto Backup - Existing Media Migration Tool

Usage:
  bash migrate_existing_data.sh [options]

Options:
  --all                   Migrate both Video and Photo backup directories (Default)
  --videos                Migrate only Video backup directory ($BACKUP_ROOT)
  --photos                Migrate only Photo backup directory ($PHOTO_BACKUP_ROOT)
  --dir <path>            Migrate a specific custom directory
  --device <name>         Custom device name override (Default: Auto-detected from EXIF)
  --media-manager-db <p>  Path to MediaManager library.sqlite database
                          (Auto-detected if omitted)
  --no-media-manager      Do not attempt to restore original names from MediaManager
  --run                   Execute renaming and history database population
  --dry-run               Preview actions without making changes (Default safe mode)
  --help, -h              Show this help message

Examples:
  # 1. Preview migration of all existing backups:
  bash migrate_existing_data.sh --dry-run

  # 2. Execute migration restoring original filenames from MediaManager:
  bash migrate_existing_data.sh --run

  # 3. Execute migration with a custom device tag:
  bash migrate_existing_data.sh --run --device "Vaibhavs_iPhone"

  # 4. Migrate only the video library:
  bash migrate_existing_data.sh --videos --run
EOF
}

# Extract capture timestamp from file (returns YYYYMMDDHHMM.SS for touch -t)
get_file_timestamp() {
    local fp="$1" is_vid="$2"
    local ts=""
    if $is_vid; then
        ts=$("$EXIFTOOL" -CreateDate -s3 -d "%Y%m%d%H%M.%S" "$fp" 2>/dev/null | head -1)
        if [[ -z "$ts" || ! "$ts" =~ ^[0-9]{12}\.[0-9]{2}$ ]]; then
            ts=$("$EXIFTOOL" -MediaCreateDate -s3 -d "%Y%m%d%H%M.%S" "$fp" 2>/dev/null | head -1)
        fi
    else
        ts=$("$EXIFTOOL" -DateTimeOriginal -s3 -d "%Y%m%d%H%M.%S" "$fp" 2>/dev/null | head -1)
        if [[ -z "$ts" || ! "$ts" =~ ^[0-9]{12}\.[0-9]{2}$ ]]; then
            ts=$("$EXIFTOOL" -CreateDate -s3 -d "%Y%m%d%H%M.%S" "$fp" 2>/dev/null | head -1)
        fi
        if [[ -z "$ts" || ! "$ts" =~ ^[0-9]{12}\.[0-9]{2}$ ]]; then
            ts=$("$EXIFTOOL" -MediaCreateDate -s3 -d "%Y%m%d%H%M.%S" "$fp" 2>/dev/null | head -1)
        fi
    fi

    # Fallback to filesystem modification time
    if [[ -z "$ts" || ! "$ts" =~ ^[0-9]{12}\.[0-9]{2}$ ]]; then
        ts=$(stat -f%Sm -t "%Y%m%d%H%M.%S" "$fp" 2>/dev/null || stat -c%y "$fp" 2>/dev/null | tr -d ' :-' | head -c 12 || true)
        if [[ -n "$ts" && "$ts" =~ ^[0-9]{12}$ ]]; then
            ts="${ts}.00"
        fi
    fi

    printf '%s\n' "$ts"
}

# Determine camera model from EXIF
get_camera_model() {
    local fp="$1"
    local model
    model=$("$EXIFTOOL" -Model -s3 "$fp" 2>/dev/null | head -1)
    if [[ -z "$model" ]]; then
        model=$("$EXIFTOOL" -Make -s3 "$fp" 2>/dev/null | head -1)
    fi
    [[ -z "$model" ]] && model="iPhone"
    printf '%s\n' "$model"
}

# Look up original camera roll filename from MediaManager library.sqlite database
lookup_media_manager_filename() {
    local mm_db="$1" fsize="$2" ext="$3" date_prefix="${4:-}"
    [[ -z "$mm_db" || ! -f "$mm_db" ]] && return 1

    # 1. Try matching by exact file size + extension + date prefix
    local q="SELECT original_filename FROM assets WHERE file_size = $fsize AND lower(file_extension) = lower('$ext')"
    if [[ -n "$date_prefix" ]]; then
        q="$q ORDER BY CASE WHEN date_taken LIKE '$date_prefix%' THEN 0 ELSE 1 END"
    fi
    q="$q LIMIT 1;"

    local res
    res=$(sqlite3 "$mm_db" "$q" 2>/dev/null || true)
    if [[ -n "$res" ]]; then
        printf '%s\n' "$res"
        return 0
    fi

    # 2. Fallback to file_size match alone
    res=$(sqlite3 "$mm_db" "SELECT original_filename FROM assets WHERE file_size = $fsize LIMIT 1;" 2>/dev/null || true)
    if [[ -n "$res" ]]; then
        printf '%s\n' "$res"
        return 0
    fi

    return 1
}

# Migrate a designated target media directory
migrate_directory() {
    local root_dir="$1"
    local media_kind="$2" # "video", "photo", or "mixed"
    local custom_device="$3"
    local mm_db="$4"
    local dry_run="$5"

    echo ""
    echo "======================================================================"
    echo "   Scanning Directory: $root_dir"
    echo "   Media Type:         $media_kind"
    echo "   Mode:               $( $dry_run && echo '[DRY-RUN PREVIEW]' || echo '[EXECUTE LIVE]' )"
    if [[ -n "$mm_db" ]]; then
        echo "   MediaManager DB:    $mm_db"
    fi
    echo "======================================================================"

    if [[ ! -d "$root_dir" ]]; then
        warn "Directory not found (is external disk mounted?): $root_dir"
        return 0
    fi

    # Pre-dump MediaManager index to temporary map for lightning-fast lookups
    local mm_map_file=""
    if [[ -n "$mm_db" && -f "$mm_db" ]]; then
        mm_map_file="$(mktemp -t mm_lookup_XXXXXX 2>/dev/null || mktemp /tmp/mm_lookup_XXXXXX)"
        sqlite3 "$mm_db" "SELECT file_size || '|' || lower(file_extension) || '|' || substr(date_taken, 1, 10), original_filename FROM assets;" > "$mm_map_file" 2>/dev/null || true
    fi

    local history_db
    history_db=$(resolve_history_db "$root_dir")
    if ! $dry_run; then
        init_history_db "$history_db"
    fi

    pr "Enumerating files in $root_dir..."
    local files=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local bn; bn=$(basename "$f")

        # Skip system metadata files, apple double files, database, and manifests
        [[ "$bn" == .DS_Store || "$bn" == ._* || "$bn" == *.sqlite3* || "$bn" == *.csv ]] && continue

        if is_video "$f" || is_photo "$f"; then
            files+=("$f")
        fi
    done < <(find "$root_dir" -type f 2>/dev/null | sort)

    local total=${#files[@]}
    if [[ "$total" -eq 0 ]]; then
        info "No matching video or photo files found in $root_dir."
        [[ -n "$mm_map_file" && -f "$mm_map_file" ]] && rm -f "$mm_map_file"
        return 0
    fi

    info "Found $total media file(s) to inspect."
    echo ""

    local count_migrated=0
    local count_restored_mm=0
    local count_already_formatted=0
    local count_failed=0
    local idx=0

    for file in "${files[@]}"; do
        ((idx++)) || true
        local bn; bn=$(basename "$file")
        local dir; dir=$(dirname "$file")

        # Check if file is a video or photo
        local is_vid=false
        if is_video "$file"; then
            is_vid=true
        fi

        # Target deduplication database
        local target_hash_db="$PHOTO_HASH_INDEX"
        if $is_vid; then
            target_hash_db="$VIDEO_HASH_INDEX"
        fi

        # Compute partial SHA1 hash
        local h; h=$(compute_hash "$file")
        local fsize; fsize=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)

        # Check if file already adheres to the new format: YYYYMMDD_HHMMSS_*
        if [[ "$bn" =~ ^[0-9]{8}_[0-9]{6}_ ]]; then
            ((count_already_formatted++)) || true

            # Even if already formatted, ensure it is recorded in the SQLite history DB
            if ! $dry_run; then
                # Determine relative path
                local rel_path="${file#"$root_dir"/}"
                local cat_name="Videos"
                if ! $is_vid; then
                    if [[ "$rel_path" == Screenshots/* ]]; then
                        cat_name="Screenshots"
                    elif [[ "$rel_path" == Saved_Images/* ]]; then
                        cat_name="Saved_Images"
                    else
                        cat_name="Photos"
                    fi
                fi

                # Ensure registered in deduplication hash file
                if ! grep -qxF "$h" "$target_hash_db" 2>/dev/null; then
                    echo "$h" >> "$target_hash_db"
                fi

                # Read existing capture timestamp for DB
                local ts_str=""
                if [[ "$bn" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2}) ]]; then
                    ts_str="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
                fi

                local dev_label="$custom_device"
                [[ -z "$dev_label" ]] && dev_label="iPhone"

                record_backup_history "$history_db" \
                    "$rel_path" \
                    "$bn" \
                    "$( $is_vid && echo "video" || echo "photo" )" \
                    "$cat_name" \
                    "$dev_label" \
                    "$dev_label" \
                    "" \
                    "$ts_str" \
                    "$fsize" \
                    "$h"
            fi
            continue
        fi

        # File needs migration! Extract timestamp and camera model in a single exiftool pass
        local dev_label="$custom_device"
        local ts="" cam_model=""
        local meta_lines=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && meta_lines+=("$line")
        done < <("$EXIFTOOL" -DateTimeOriginal -CreateDate -MediaCreateDate -Model -Make -s3 -d "%Y%m%d%H%M.%S" "$file" 2>/dev/null || true)

        if (( ${#meta_lines[@]} > 0 )); then
            for l in "${meta_lines[@]}"; do
                if [[ "$l" =~ ^[0-9]{12}\.[0-9]{2}$ ]]; then
                    [[ -z "$ts" ]] && ts="$l"
                elif [[ -z "$cam_model" && "$l" != "Apple" ]]; then
                    cam_model="$l"
                fi
            done
        fi

        # Fallback to filesystem modification time if EXIF tags were absent or empty
        if [[ -z "$ts" || ! "$ts" =~ ^[0-9]{12}\.[0-9]{2}$ ]]; then
            local fm
            fm=$(stat -f%Sm -t "%Y%m%d%H%M.%S" "$file" 2>/dev/null || stat -c%y "$file" 2>/dev/null | tr -d ' :-' | head -c 12 || true)
            if [[ -n "$fm" && "$fm" =~ ^[0-9]{12}$ ]]; then
                ts="${fm}.00"
            fi
        fi

        [[ -z "$cam_model" ]] && cam_model="iPhone"
        [[ -z "$dev_label" ]] && dev_label="$cam_model"
        local safe_dev
        safe_dev=$(sanitize_device_name "$dev_label")

        local compact_ts human_ts
        if [[ -n "$ts" && "$ts" =~ ^[0-9]{12}\.[0-9]{2}$ ]]; then
            compact_ts="${ts:0:8}_${ts:8:4}${ts:13:2}"
            human_ts="${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:8:2}:${ts:10:2}:${ts:13:2}"
        else
            local parent_bn; parent_bn=$(basename "$dir")
            if [[ "$parent_bn" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                compact_ts="${parent_bn//-/}_000000"
                human_ts="$parent_bn 00:00:00"
            else
                compact_ts="$(date '+%Y%m%d_%H%M%S')"
                human_ts="$(date '+%Y-%m-%d %H:%M:%S')"
            fi
        fi

        # Recover original camera roll filename from MediaManager if indexed
        local ext="${bn##*.}"
        local orig_fname=""
        local date_for_lookup="${compact_ts:0:4}-${compact_ts:4:2}-${compact_ts:6:2}"
        if [[ -n "$mm_map_file" && -f "$mm_map_file" ]]; then
            local match=""
            match=$(grep -m 1 "^${fsize}|${ext}|${date_for_lookup}|" "$mm_map_file" 2>/dev/null || true)
            [[ -z "$match" ]] && match=$(grep -m 1 "^${fsize}|${ext}|" "$mm_map_file" 2>/dev/null || true)
            [[ -n "$match" ]] && orig_fname="${match##*|}"
        fi

        local restored_from_mm=false
        if [[ -n "$orig_fname" ]]; then
            restored_from_mm=true
            ((count_restored_mm++)) || true
        else
            orig_fname="$bn"
        fi

        # Construct new filename
        local new_name="${compact_ts}_${safe_dev}_${orig_fname}"
        local target_path="$dir/$new_name"

        # Check for collision
        if [[ -e "$target_path" && "$target_path" != "$file" ]]; then
            local cur_stem="${new_name%.*}"
            local cur_ext="${new_name##*.}"
            local c_idx=1
            while [[ -e "$dir/${cur_stem}_$(printf '%02d' $c_idx).${cur_ext}" ]]; do
                ((c_idx++)) || true
            done
            new_name="${cur_stem}_$(printf '%02d' $c_idx).${cur_ext}"
            target_path="$dir/$new_name"
        fi

        if $dry_run; then
            if $restored_from_mm; then
                printf "  [%d/%d] [PREVIEW] %s -> %s  (Original name: %s)\n" "$idx" "$total" "$bn" "$new_name" "$orig_fname"
            else
                printf "  [%d/%d] [PREVIEW] %s -> %s\n" "$idx" "$total" "$bn" "$new_name"
            fi
            ((count_migrated++)) || true
            continue
        fi

        # Live Execution: Move file
        if mv "$file" "$target_path" 2>/dev/null; then
            ((count_migrated++)) || true
            if $restored_from_mm; then
                printf "\r  [%d/%d] Migrated: %s -> %s  (Original: %s)" "$idx" "$total" "$bn" "$new_name" "$orig_fname"
            else
                printf "\r  [%d/%d] Migrated: %s -> %s" "$idx" "$total" "$bn" "$new_name"
            fi

            # Set file mtime = capture timestamp
            if [[ -n "$ts" && "$ts" =~ ^[0-9]{12}\.[0-9]{2}$ ]]; then
                touch -t "$ts" "$target_path" 2>/dev/null || true
            fi

            # Handle companion Apple .AAE edit sidecar
            local base_no_ext="${file%.*}"
            local aae_src=""
            if [[ -f "${base_no_ext}.AAE" ]]; then
                aae_src="${base_no_ext}.AAE"
            elif [[ -f "${base_no_ext}.aae" ]]; then
                aae_src="${base_no_ext}.aae"
            fi
            if [[ -n "$aae_src" ]]; then
                local aae_target="${dir}/${new_name%.*}.aae"
                mv "$aae_src" "$aae_target" 2>/dev/null || true
                if [[ -n "$ts" && "$ts" =~ ^[0-9]{12}\.[0-9]{2}$ ]]; then
                    touch -t "$ts" "$aae_target" 2>/dev/null || true
                fi
            fi

            # Determine category name and relative path
            local rel_path="${target_path#"$root_dir"/}"
            local cat_name="Videos"
            if ! $is_vid; then
                if [[ "$rel_path" == Screenshots/* ]]; then
                    cat_name="Screenshots"
                elif [[ "$rel_path" == Saved_Images/* ]]; then
                    cat_name="Saved_Images"
                else
                    cat_name="Photos"
                fi
            fi

            # Record in SQLite history database
            record_backup_history "$history_db" \
                "$rel_path" \
                "$orig_fname" \
                "$( $is_vid && echo "video" || echo "photo" )" \
                "$cat_name" \
                "$dev_label" \
                "$dev_label" \
                "" \
                "$human_ts" \
                "$fsize" \
                "$h"

            # Attach macOS extended attributes
            if command -v xattr >/dev/null 2>&1; then
                xattr -w user.original_filename "$orig_fname" "$target_path" 2>/dev/null || true
                xattr -w user.device_name "$dev_label" "$target_path" 2>/dev/null || true
                xattr -w com.apple.metadata:kMDItemOriginator "$dev_label" "$target_path" 2>/dev/null || true
            fi

            # Ensure registered in deduplication hash file
            if ! grep -qxF "$h" "$target_hash_db" 2>/dev/null; then
                echo "$h" >> "$target_hash_db"
            fi
        else
            ((count_failed++)) || true
            warn "Failed to rename: $file"
        fi
    done

    echo ""
    echo ""
    echo "----------------------------------------------------------------------"
    printf "%-28s %s\n" "Total Scanned:" "$total"
    printf "%-28s ${GREEN}%s${NC}\n" "Migrated to New Format:" "$count_migrated"
    if [[ -n "$mm_db" ]]; then
        printf "%-28s ${GREEN}%s${NC}\n" "Original Names Restored:" "$count_restored_mm"
    fi
    printf "%-28s ${YELLOW}%s${NC}\n" "Already in New Format:" "$count_already_formatted"
    printf "%-28s ${RED}%s${NC}\n" "Failed Renames:" "$count_failed"
    echo "----------------------------------------------------------------------"

    [[ -n "$mm_map_file" && -f "$mm_map_file" ]] && rm -f "$mm_map_file"

    if ! $dry_run && (( count_migrated > 0 || count_already_formatted > 0 )); then
        local manifest_file="$root_dir/editor_manifest.csv"
        export_editor_manifest "$history_db" "$manifest_file"
        info "Exported manifest: $manifest_file"
    fi
}

main() {
    local target_scope="all"
    local custom_dir=""
    local custom_device=""
    local custom_mm_db=""
    local use_mm=true
    local dry_run=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)                   target_scope="all"; shift ;;
            --videos)                target_scope="videos"; shift ;;
            --photos)                target_scope="photos"; shift ;;
            --dir)                   shift; custom_dir="${1:-}"; target_scope="custom"; shift ;;
            --device)                shift; custom_device="${1:-}"; shift ;;
            --media-manager-db|--mm-db) shift; custom_mm_db="${1:-}"; shift ;;
            --no-media-manager)      use_mm=false; shift ;;
            --run|--execute)         dry_run=false; shift ;;
            --dry-run)               dry_run=true; shift ;;
            --help|-h)               show_help; exit 0 ;;
            *)
                err "Unknown option: $1"
                show_help; exit 1
                ;;
        esac
    done

    # Resolve MediaManager database location
    local resolved_mm_db=""
    if $use_mm; then
        if [[ -n "$custom_mm_db" && -f "$custom_mm_db" ]]; then
            resolved_mm_db="$custom_mm_db"
        elif [[ -f "$HOME/Library/Application Support/MediaManager/database/library.sqlite" ]]; then
            resolved_mm_db="$HOME/Library/Application Support/MediaManager/database/library.sqlite"
        fi
    fi

    echo ""
    echo "======================================================================"
    echo "       iPhone Auto Backup - Existing Media Migration Engine"
    echo "       Author: Vaibhav Bhootna"
    echo "======================================================================"
    info "Target Scope:     $target_scope"
    info "Execution:        $( $dry_run && echo 'PREVIEW ONLY (Dry-Run)' || echo 'LIVE EXECUTION' )"
    if [[ -n "$custom_device" ]]; then
        info "Device Label:     $custom_device (explicit override)"
    else
        info "Device Label:     Auto-detect from EXIF camera model"
    fi
    if [[ -n "$resolved_mm_db" ]]; then
        info "MediaManager DB:  $resolved_mm_db"
        info "Name Recovery:    ENABLED (restoring original camera roll names)"
    else
        info "Name Recovery:    Disabled (MediaManager DB not found or skipped)"
    fi
    echo "======================================================================"

    if $dry_run; then
        echo ""
        warn "Running in PREVIEW mode. No files or databases will be modified."
        echo "  To execute the migration live, run with the --run flag:"
        echo "    bash migrate_existing_data.sh --run"
    fi

    case "$target_scope" in
        videos)
            migrate_directory "$BACKUP_ROOT" "video" "$custom_device" "$resolved_mm_db" "$dry_run"
            ;;
        photos)
            migrate_directory "$PHOTO_BACKUP_ROOT" "photo" "$custom_device" "$resolved_mm_db" "$dry_run"
            ;;
        custom)
            if [[ -z "$custom_dir" || ! -d "$custom_dir" ]]; then
                err "Invalid custom directory: $custom_dir"
                exit 1
            fi
            migrate_directory "$custom_dir" "mixed" "$custom_device" "$resolved_mm_db" "$dry_run"
            ;;
        all|*)
            migrate_directory "$BACKUP_ROOT" "video" "$custom_device" "$resolved_mm_db" "$dry_run"
            migrate_directory "$PHOTO_BACKUP_ROOT" "photo" "$custom_device" "$resolved_mm_db" "$dry_run"
            ;;
    esac

    echo ""
    if $dry_run; then
        info "Dry-run complete. Review the planned names above."
        echo "  Ready to proceed? Run:"
        echo "    bash migrate_existing_data.sh --run"
    else
        info "Migration completed successfully!"
        echo "  - Original camera roll filenames restored from MediaManager."
        echo "  - Collision-proof timestamps and camera models attached."
        echo "  - SQLite backup history recorded at $(resolve_history_db "$BACKUP_ROOT")."
        echo "  - Deduplication hashes verified (connected iPhones will skip these files)."
        echo "  - Handover manifests exported to editor_manifest.csv."
    fi
    echo ""
}

main "$@"
