#!/bin/bash
# ==============================================================================
# iPhone Auto Backup - Media Hash Index Rebuild Tool
# Author: Vaibhav Bhootna
# Repository: https://github.com/vbv611/iphone-auto-backup
#
# Scans existing photo and video files on your external backup volume and records
# their partial SHA1 content hashes into the local deduplication databases:
#   - ~/.iphone_photo_backup_v3.hashes
#   - ~/.iphone_video_backup_v3.hashes
#
# Usage:
#   bash rebuild_hash_index.sh           # Rebuilds photo hash index (default)
#   bash rebuild_hash_index.sh --photos  # Rebuilds photo hash index
#   bash rebuild_hash_index.sh --videos  # Rebuilds video hash index
#   bash rebuild_hash_index.sh --all     # Rebuilds both photo and video indexes
#   bash rebuild_hash_index.sh --dry-run # Statistics only, no disk writes
# ==============================================================================

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
pr()    { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
prok()  { echo -e "${GREEN}[OK]${NC} $*"; }
prskip(){ echo -e "${YELLOW}[SKIP]${NC} $*"; }

# Compute partial SHA1 content hash identical to the backup engines.
# (File size + first 512KB + last 512KB)
compute_hash() {
    local f="$1"
    local size; size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
    local head tail
    head=$(head -c 524288 "$f" | shasum | cut -d' ' -f1)
    tail=$(tail -c 524288 "$f" | shasum | cut -d' ' -f1)
    echo "${size}_${head}_${tail}"
}

# Scan and rebuild index for a designated target media directory.
# Arguments:
#   $1 - Human-readable label (e.g., 'Photo' or 'Video')
#   $2 - Root directory path to scan
#   $3 - Destination hash database file path
#   $4 - Dry run flag (true/false)
rebuild_target() {
    local label="$1"
    local root_dir="$2"
    local hash_file="$3"
    local dry_run="$4"

    echo ""
    pr "==== ${label} Hash Index Rebuild ===="
    if [[ ! -d "$root_dir" ]]; then
        echo "${label} root directory does not exist (is disk mounted?): $root_dir"
        return 1
    fi
    $dry_run && pr "(DRY-RUN Mode: statistics only, no writes)"
    pr "Scanning Directory: $root_dir"
    pr "Index Database: $hash_file"
    echo ""

    touch "$hash_file"

    local total=0 added=0 already=0 skipped=0
    total=$(find "$root_dir" -type f ! -name ".DS_Store" | wc -l | tr -d ' ')
    pr "Found $total file(s). Beginning scan..."
    echo ""

    local idx=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        ((idx++)) || true
        local bn; bn=$(basename "$f")

        # Skip system and history metadata files
        [[ "$bn" == .DS_Store || "$bn" == *.sqlite3* || "$bn" == *.csv ]] && { ((skipped++)) || true; continue; }

        (( idx % 50 == 0 )) && pr "  Progress: ${idx}/${total}..."

        local h; h=$(compute_hash "$f")

        if grep -qxF "$h" "$hash_file" 2>/dev/null; then
            ((already++)) || true
        else
            if ! $dry_run; then
                echo "$h" >> "$hash_file"
            fi
            ((added++)) || true
            prok "Indexed: $f"
        fi
    done < <(find "$root_dir" -type f ! -name ".DS_Store" 2>/dev/null | sort)

    echo ""
    echo "======================================================================"
    echo "                    ${label} Hash Index Rebuild Report"
    echo "======================================================================"
    printf "%-18s %s\n" "Scanned Root:" "$root_dir"
    printf "%-18s %s\n" "Database File:" "$hash_file"
    printf "%-18s %s\n" "Files Scanned:" "$total"
    printf "%-18s ${GREEN}%s${NC}\n" "Newly Indexed:" "$added"
    printf "%-18s ${YELLOW}%s${NC}\n" "Already Indexed:" "$already"
    printf "%-18s %s\n" "Skipped (System):" "$skipped"
    echo "======================================================================"
    echo ""
}

# Main CLI entry point.
main() {
    local dry_run=false
    local do_photos=false
    local do_videos=false

    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=true ;;
            --photos)  do_photos=true ;;
            --videos)  do_videos=true ;;
            --all)     do_photos=true; do_videos=true ;;
        esac
    done

    # Default to photos if neither explicitly set
    if ! $do_photos && ! $do_videos; then
        do_photos=true
    fi

    if config_has_placeholders; then
        echo "config.sh still contains YourExternalDrive placeholder. Edit config.sh first."
        exit 1
    fi

    if $do_photos; then
        rebuild_target "Photo" "$PHOTO_BACKUP_ROOT" "$HOME/.iphone_photo_backup_v3.hashes" "$dry_run"
    fi
    if $do_videos; then
        rebuild_target "Video" "$BACKUP_ROOT" "$HOME/.iphone_video_backup_v3.hashes" "$dry_run"
    fi

    if $dry_run; then
        echo "DRY-RUN Complete: No changes were written. Re-run without --dry-run to commit."
    else
        echo "Complete. Subsequent iPhone connections will skip these media items."
    fi
}

main "$@"
