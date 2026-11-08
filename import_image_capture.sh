#!/bin/bash
# ==============================================================================
# iPhone Auto Backup - Image Capture & External Folder Import Tool
# Author: Vaibhav Bhootna
# Repository: https://github.com/vbv611/iphone-auto-backup
#
# Purpose:
#   Ingests media previously copied from an iPhone via macOS Image Capture,
#   Finder, or manual transfers into this backup utility's ecosystem.
#
# Capabilities:
#   1. Organizes flat/unstructured media into standardized date-based hierarchies:
#        Videos:  $BACKUP_ROOT/YYYY-MM-DD/001.mov
#        Photos:  $PHOTO_BACKUP_ROOT/Photos|Screenshots|Saved_Images/YYYY-MM-DD/001.heic
#   2. Computes and registers SHA1 partial content hashes into local databases
#      (~/.iphone_*_backup_v3.hashes), ensuring connected iPhones will NEVER
#      re-download or duplicate these files.
#   3. Supports in-place indexing (--index-only) if you wish to keep your existing
#      folder untouched while preventing iPhone duplicate backups.
#
# Usage:
#   bash import_image_capture.sh [options] <source_folder>
#
# Options:
#   --copy        Copy files into standardized backup structure (default)
#   --move        Move files into standardized backup structure
#   --index-only  Do not copy/move files; only index hashes to prevent duplicates
#   --dry-run     Preview actions without moving files or modifying databases
# ==============================================================================

set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

# ---------- Terminal Styling ----------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; }
pr()    { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }

VIDEO_HASH_INDEX="$HOME/.iphone_video_backup_v3.hashes"
PHOTO_HASH_INDEX="$HOME/.iphone_photo_backup_v3.hashes"

# ---------- Core Helper Functions ----------

compute_hash() {
    local f="$1"
    local size; size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
    local head tail
    head=$(head -c 524288 "$f" | shasum | cut -d' ' -f1)
    tail=$(tail -c 524288 "$f" | shasum | cut -d' ' -f1)
    echo "${size}_${head}_${tail}"
}

is_video() {
    local ext="${1##*.}"
    local pat="^(${VIDEO_EXTENSIONS// /|})$"
    shopt -s nocasematch 2>/dev/null || true
    local res=1
    if [[ "$ext" =~ $pat ]]; then res=0; fi
    shopt -u nocasematch 2>/dev/null || true
    return $res
}

is_photo() {
    local ext="${1##*.}"
    local pat="^(${PHOTO_EXTENSIONS// /|})$"
    shopt -s nocasematch 2>/dev/null || true
    local res=1
    if [[ "$ext" =~ $pat ]]; then res=0; fi
    shopt -u nocasematch 2>/dev/null || true
    return $res
}

get_video_date() {
    local fp="$1"
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

    # Fallback to filesystem modification date
    local fm
    fm=$(stat -f%Sm -t "%Y-%m-%d" "$fp" 2>/dev/null || stat -c%y "$fp" 2>/dev/null | cut -d' ' -f1 || true)
    if [[ -n "$fm" && "$fm" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$fm" != "1970-01-01" ]]; then
        echo "$fm"; return
    fi

    echo "_unknown_date"
}

get_photo_date() {
    local fp="$1"
    local d=""

    d=$("$EXIFTOOL" -DateTimeOriginal -s3 -d "%Y-%m-%d" "$fp" 2>/dev/null | head -1)
    if [[ -n "$d" && "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "$d"; return
    fi

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
    ds=$(expr "$bn" : 'IMG_\([0-9]\{8\}\)' 2>/dev/null || true)
    if [[ -n "$ds" && ${#ds} -eq 8 ]]; then
        echo "${ds:0:4}-${ds:4:2}-${ds:6:2}"; return
    fi

    # Fallback to filesystem modification date
    local fm
    fm=$(stat -f%Sm -t "%Y-%m-%d" "$fp" 2>/dev/null || stat -c%y "$fp" 2>/dev/null | cut -d' ' -f1 || true)
    if [[ -n "$fm" && "$fm" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$fm" != "1970-01-01" ]]; then
        echo "$fm"; return
    fi

    echo "_unknown_date"
}

get_timestamp() {
    local fp="$1"
    local tag="$2"
    local ts=""
    ts=$("$EXIFTOOL" -"$tag" -s3 -d "%Y%m%d%H%M.%S" "$fp" 2>/dev/null | head -1)
    if [[ -n "$ts" && "$ts" =~ ^[0-9]{12}\.[0-9]{2}$ ]]; then
        echo "$ts"; return
    fi
    echo ""
}

_screen_dims_set() {
    cat <<'DIMS'
640x1136 1136x640 750x1334 1334x750 828x1792 1792x828 1080x2340 2340x1080
1125x2436 2436x1125 1170x2532 2532x1170 1179x2556 2556x1179 1206x2622 2622x1206
1242x2208 2208x1242 1242x2688 2688x1242 1284x2778 2778x1284 1290x2796 2796x1290
1320x2868 2868x1320 886x1920 1920x886 1620x2160 2160x1620 1640x2360 2360x1640
1668x2388 2388x1668 2048x2732 2732x2048 2560x1600 1600x2560 2880x1800 1800x2880
3024x1964 1964x3024 3456x2234 2234x3456 1512x982 982x1512 1728x1117 1117x1728
1440x2560 2560x1440 1440x2960 2960x1440 1440x3088 3088x1440 1440x3120 3120x1440
1536x2560 2560x1536 1600x2560 2560x1600
DIMS
}

_camera_dims_set() {
    cat <<'DIMS'
4032x3024 3024x4032 4032x2268 2268x4032 3264x2448 2448x3264 3840x2160 2160x3840
4000x3000 3000x4000 4128x3096 3096x4128 4624x3472 3472x4624 5712x4284 4284x5712
1080x1920 1920x1080 720x1280 1280x720
DIMS
}

_dims_match() {
    local dims="$1" set_name="$2"
    local pattern
    if [[ "$set_name" == "screen" ]]; then
        pattern="$(_screen_dims_set | tr '\n' ' ')"
    else
        pattern="$(_camera_dims_set | tr '\n' ' ')"
    fi
    echo " $pattern " | grep -q " $dims "
}

classify_photo_type() {
    local fp="$1"
    local ext="${1##*.}"
    ext=$(echo "$ext" | tr '[:lower:]' '[:upper:]')

    if [[ " HEIC HEIF DNG RAW " == *" $ext "* ]]; then
        echo "photo"; return
    fi
    if [[ " GIF WEBP " == *" $ext "* ]]; then
        echo "saved_image"; return
    fi

    local w h dims=""
    local sips_out
    sips_out=$(sips -g pixelWidth -g pixelHeight "$fp" 2>/dev/null) || true
    w=$(echo "$sips_out" | awk '/pixelWidth/{print $2}')
    h=$(echo "$sips_out" | awk '/pixelHeight/{print $2}')
    if [[ -n "$w" && -n "$h" ]]; then
        dims="${w}x${h}"
    fi

    if [[ "$ext" == "PNG" ]]; then
        if [[ -n "$dims" ]] && _dims_match "$dims" "screen"; then
            echo "screenshot"; return
        fi
        echo "saved_image"; return
    fi

    if [[ " JPG JPEG TIF TIFF " == *" $ext "* ]]; then
        if [[ -n "$dims" ]] && _dims_match "$dims" "screen"; then
            echo "screenshot"; return
        fi
        if [[ -n "$dims" ]] && _dims_match "$dims" "camera"; then
            echo "photo"; return
        fi
        local make
        make=$("$EXIFTOOL" -Make -s3 "$fp" 2>/dev/null | head -1)
        if [[ -n "$make" ]]; then
            echo "photo"; return
        fi
        echo "saved_image"; return
    fi

    echo "saved_image"
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

# ---------- Usage Banner ----------
show_help() {
    cat <<EOF
iPhone Auto Backup - Image Capture / External Folder Importer
Author: Vaibhav Bhootna

Usage:
  bash import_image_capture.sh [options] <source_folder>

Options:
  --copy           Copy files into standardized backup structure (Default)
  --move           Move files into standardized backup structure
  --index-only     Do NOT copy or move files; only record content hashes so
                   connected iPhones will never re-download or duplicate them.
  --device <name>  Label media with a specific device name (e.g. "iPhone 15 Pro", "Imported")
  --dry-run        Preview actions without copying/moving files or modifying index.
  --help           Show this help message.

Examples:
  # Organize and copy all files from an Image Capture dump into backup roots:
  bash import_image_capture.sh /Volumes/MyExternalDrive/Old_Image_Capture_Dump

  # Keep existing directory as-is, but register all files in dedup databases:
  bash import_image_capture.sh --index-only /Volumes/MyExternalDrive/Photos2025

  # Move files and organize into date folders:
  bash import_image_capture.sh --move /Volumes/MyExternalDrive/Raw_Imports
EOF
}

# ---------- Main Importer Logic ----------
main() {
    local mode="copy"
    local dry_run=false
    local source_dir=""
    local device_label="Imported"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --copy)       mode="copy"; shift ;;
            --move)       mode="move"; shift ;;
            --index-only) mode="index"; shift ;;
            --dry-run)    dry_run=true; shift ;;
            --device)     shift; device_label="${1:-Imported}"; shift ;;
            --help|-h)    show_help; exit 0 ;;
            *)
                if [[ -z "$source_dir" ]]; then
                    source_dir="$1"
                else
                    err "Unexpected argument: $1"
                    show_help; exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$source_dir" ]]; then
        err "Missing source folder path."
        show_help; exit 1
    fi

    if [[ ! -d "$source_dir" ]]; then
        err "Source directory does not exist: $source_dir"
        exit 1
    fi

    if [[ "$mode" != "index" ]]; then
        if config_has_placeholders; then
            err "config.sh still has YourExternalDrive placeholders. Update config.sh first."
            exit 1
        fi
    fi

    echo ""
    echo "======================================================================"
    echo "   iPhone Auto Backup - External Media Importer"
    echo "   Author: Vaibhav Bhootna"
    echo "======================================================================"
    info "Source Directory: $source_dir"
    info "Operation Mode:   $mode $( $dry_run && echo '[DRY-RUN]' )"
    echo "======================================================================"
    echo ""

    if [[ "$mode" != "index" ]]; then
        local missing_vol=""
        if ! missing_vol=$(ensure_backup_root "$BACKUP_ROOT"); then
            err "Video backup root is not mounted: $missing_vol"
            exit 1
        fi
        if ! missing_vol=$(ensure_backup_root "$PHOTO_BACKUP_ROOT"); then
            err "Photo backup root is not mounted: $missing_vol"
            exit 1
        fi
    fi

    touch "$VIDEO_HASH_INDEX" "$PHOTO_HASH_INDEX"

    local vid_history_db photo_history_db safe_dev
    safe_dev=$(sanitize_device_name "$device_label")
    vid_history_db=$(resolve_history_db "$BACKUP_ROOT")
    photo_history_db=$(resolve_history_db "$PHOTO_BACKUP_ROOT")
    if [[ "$mode" != "index" && "$dry_run" = false ]]; then
        init_history_db "$vid_history_db"
        [[ "$photo_history_db" != "$vid_history_db" ]] && init_history_db "$photo_history_db"
    fi

    # Enumerate all files in source directory
    pr "Scanning source folder for media files..."
    local media_files=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local bn; bn=$(basename "$f")
        [[ "$bn" == .DS_Store || "$bn" == ._* || "$bn" == .* ]] && continue
        if is_video "$f" || is_photo "$f"; then
            media_files+=("$f")
        fi
    done < <(find "$source_dir" -type f 2>/dev/null | sort)

    local total=${#media_files[@]}
    if [[ "$total" -eq 0 ]]; then
        warn "No matching media files found in $source_dir."
        exit 0
    fi
    info "Found $total media file(s) to process."
    echo ""

    local imported_videos=0
    local imported_photos=0
    local already_indexed=0
    local failed=0
    local idx=0

    local LAST_VID_DIR=""
    local LAST_VID_SEQ=-1
    local LAST_PHO_DIR=""
    local LAST_PHO_SEQ=-1

    for file in "${media_files[@]}"; do
        ((idx++)) || true
        local fname; fname=$(basename "$file")
        printf "\r  [%d/%d] Processing %s..." "$idx" "$total" "$fname"

        local h; h=$(compute_hash "$file")

        # Determine media category and target database
        local is_vid=false
        local target_db=""
        if is_video "$file"; then
            is_vid=true
            target_db="$VIDEO_HASH_INDEX"
        else
            target_db="$PHOTO_HASH_INDEX"
        fi

        # Check if hash already exists in database
        if grep -qxF "$h" "$target_db" 2>/dev/null; then
            ((already_indexed++)) || true
            if [[ "$mode" == "move" && "$dry_run" = false ]]; then
                mkdir -p "$source_dir/_already_backed_up"
                mv "$file" "$source_dir/_already_backed_up/" 2>/dev/null || true
                local base_no_ext="${file%.*}"
                [[ -f "${base_no_ext}.AAE" ]] && mv "${base_no_ext}.AAE" "$source_dir/_already_backed_up/" 2>/dev/null || true
                [[ -f "${base_no_ext}.aae" ]] && mv "${base_no_ext}.aae" "$source_dir/_already_backed_up/" 2>/dev/null || true
            fi
            continue
        fi

        if [[ "$mode" == "index" ]]; then
            # Mode: Index Only
            if ! $dry_run; then
                echo "$h" >> "$target_db"
            fi
            if $is_vid; then ((imported_videos++)) || true; else ((imported_photos++)) || true; fi
            continue
        fi

        # Mode: Copy or Move
        local target_dir=""
        local target_date=""

        if $is_vid; then
            target_date=$(get_video_date "$file")
            target_dir="$BACKUP_ROOT/$target_date"
        else
            target_date=$(get_photo_date "$file")
            local ptype; ptype=$(classify_photo_type "$file")
            local type_subdir
            case "$ptype" in
                photo)      type_subdir="Photos" ;;
                screenshot) type_subdir="Screenshots" ;;
                *)          type_subdir="Saved_Images" ;;
            esac
            target_dir="$PHOTO_BACKUP_ROOT/$type_subdir/$target_date"
        fi

        # Extract precise capture timestamp
        local ts=""
        if $is_vid; then
            ts=$(get_timestamp "$file" "CreateDate")
            [[ -z "$ts" ]] && ts=$(get_timestamp "$file" "MediaCreateDate")
        else
            ts=$(get_timestamp "$file" "DateTimeOriginal")
            [[ -z "$ts" ]] && ts=$(get_timestamp "$file" "CreateDate")
        fi

        local compact_ts human_ts
        if [[ -n "$ts" && "$ts" =~ ^[0-9]{12}\.[0-9]{2}$ ]]; then
            compact_ts="${ts:0:8}_${ts:8:4}${ts:13:2}"
            human_ts="${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:8:2}:${ts:10:2}:${ts:13:2}"
        else
            compact_ts="${target_date//-/}_000000"
            human_ts="$target_date 00:00:00"
        fi

        local ext="${fname##*.}"
        local new_name target_path

        local file_dev="$safe_dev"
        if [[ "$device_label" == "Imported" ]]; then
            local detected_model
            detected_model=$("$EXIFTOOL" -Model -s3 "$file" 2>/dev/null | head -1)
            [[ -z "$detected_model" ]] && detected_model=$("$EXIFTOOL" -Make -s3 "$file" 2>/dev/null | head -1)
            if [[ -n "$detected_model" ]]; then
                file_dev=$(sanitize_device_name "$detected_model")
            else
                file_dev="iPhone"
            fi
        fi

        case "${FILENAME_FORMAT:-timestamp_device_original}" in
            timestamp_device_original)
                new_name="${compact_ts}_${file_dev}_${fname}"
                ;;
            timestamp_original)
                new_name="${compact_ts}_${fname}"
                ;;
            device_original)
                new_name="${file_dev}_${fname}"
                ;;
            original)
                new_name="${fname}"
                ;;
            sequential|*)
                local seq
                if $is_vid; then
                    if [[ "$target_dir" == "$LAST_VID_DIR" && "$LAST_VID_SEQ" -ge 0 ]]; then
                        LAST_VID_SEQ=$((LAST_VID_SEQ + 1))
                        seq=$LAST_VID_SEQ
                    else
                        LAST_VID_DIR="$target_dir"
                        LAST_VID_SEQ=$(get_max_seq_for_dir "$target_dir")
                        LAST_VID_SEQ=$((LAST_VID_SEQ + 1))
                        seq=$LAST_VID_SEQ
                    fi
                else
                    if [[ "$target_dir" == "$LAST_PHO_DIR" && "$LAST_PHO_SEQ" -ge 0 ]]; then
                        LAST_PHO_SEQ=$((LAST_PHO_SEQ + 1))
                        seq=$LAST_PHO_SEQ
                    else
                        LAST_PHO_DIR="$target_dir"
                        LAST_PHO_SEQ=$(get_max_seq_for_dir "$target_dir")
                        LAST_PHO_SEQ=$((LAST_PHO_SEQ + 1))
                        seq=$LAST_PHO_SEQ
                    fi
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

        if $dry_run; then
            printf "\r\033[K"
            echo "  [DRY-RUN] $fname -> $target_path ($mode)"
            if $is_vid; then ((imported_videos++)) || true; else ((imported_photos++)) || true; fi
            continue
        fi

        mkdir -p "$target_dir"

        local transfer_ok=false
        if [[ "$mode" == "move" ]]; then
            mv "$file" "$target_path" 2>/dev/null && transfer_ok=true || transfer_ok=false
            if $transfer_ok; then
                local parent_d="${file%/*}"
                rm -f "$parent_d/._$fname" 2>/dev/null || true
            fi
        else
            cp "$file" "$target_path" 2>/dev/null && transfer_ok=true || transfer_ok=false
        fi

        if $transfer_ok; then
            echo "$h" >> "$target_db"
            if $is_vid; then ((imported_videos++)) || true; else ((imported_photos++)) || true; fi

            # Set file mtime to capture timestamp
            if [[ -n "$ts" ]]; then
                touch -t "$ts" "$target_path" 2>/dev/null || true
            fi

            # Record in SQLite history database
            local active_db rel_path cat_name mtype
            if $is_vid; then
                active_db="$vid_history_db"
                rel_path="$target_date/$new_name"
                cat_name="Videos"
                mtype="video"
            else
                active_db="$photo_history_db"
                rel_path="$type_subdir/$target_date/$new_name"
                cat_name="$type_subdir"
                mtype="photo"
            fi
            local fsize
            fsize=$(stat -f%z "$target_path" 2>/dev/null || stat -c%s "$target_path" 2>/dev/null || echo 0)

            record_backup_history "$active_db" \
                "$rel_path" \
                "$fname" \
                "$mtype" \
                "$cat_name" \
                "$file_dev" \
                "Imported" \
                "" \
                "$human_ts" \
                "$fsize" \
                "$h"

            # Attach macOS extended attributes (zero-byte impact)
            if command -v xattr >/dev/null 2>&1; then
                xattr -w user.original_filename "$fname" "$target_path" 2>/dev/null || true
                xattr -w user.device_name "$file_dev" "$target_path" 2>/dev/null || true
                xattr -w com.apple.metadata:kMDItemOriginator "$file_dev" "$target_path" 2>/dev/null || true
            fi

            # Also transfer companion Apple .AAE edit sidecars if present
            local base_no_ext="${file%.*}"
            local aae_src=""
            if [[ -f "${base_no_ext}.AAE" ]]; then
                aae_src="${base_no_ext}.AAE"
            elif [[ -f "${base_no_ext}.aae" ]]; then
                aae_src="${base_no_ext}.aae"
            fi
            if [[ -n "$aae_src" ]]; then
                local aae_target="${target_dir}/${new_name%.*}.aae"
                if [[ "$mode" == "move" ]]; then
                    mv "$aae_src" "$aae_target" 2>/dev/null || true
                else
                    cp "$aae_src" "$aae_target" 2>/dev/null || true
                fi
                if [[ -n "$ts" ]]; then
                    touch -t "$ts" "$aae_target" 2>/dev/null || true
                fi
            fi
        else
            ((failed++)) || true
        fi
    done

    printf "\r\033[K"
    echo ""
    echo "======================================================================"
    echo "                    Import Summary Report"
    echo "======================================================================"
    printf "%-22s %s\n" "Source Folder:" "$source_dir"
    printf "%-22s %s\n" "Total Scanned:" "$total"
    printf "%-22s ${GREEN}%s${NC}\n" "Videos Processed:" "$imported_videos"
    printf "%-22s ${GREEN}%s${NC}\n" "Photos Processed:" "$imported_photos"
    printf "%-22s ${YELLOW}%s${NC}\n" "Already in Index:" "$already_indexed"
    printf "%-22s ${RED}%s${NC}\n" "Failed:" "$failed"
    echo "======================================================================"
    echo ""

    if [[ "$mode" == "index" ]]; then
        info "Index complete. Existing media registered in deduplication databases."
        echo "  When your iPhone connects, these files will be skipped automatically."
    else
        info "Media imported and structured successfully."
        echo "  Deduplication hashes updated. Connected iPhones will skip these files."

        if [[ "${AUTO_EXPORT_MANIFEST:-1}" == "1" && "$dry_run" = false ]]; then
            export_editor_manifest "$vid_history_db" "$BACKUP_ROOT/editor_manifest.csv"
            export_editor_manifest "$photo_history_db" "$PHOTO_BACKUP_ROOT/editor_manifest.csv"
            info "Editor manifests refreshed:"
            echo "  - $BACKUP_ROOT/editor_manifest.csv"
            echo "  - $PHOTO_BACKUP_ROOT/editor_manifest.csv"
        fi
    fi
    echo ""
}

main "$@"
