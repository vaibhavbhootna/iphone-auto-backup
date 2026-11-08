#!/bin/bash
# ==============================================================================
# iPhone Auto Backup - Editor Handover & History Manifest Tool
# Author: Vaibhav Bhootna
# Repository: https://github.com/vbv611/iphone-auto-backup
#
# Generates collision-proof CSV manifests from the SQLite backup history
# database for video editors, DITs, and media archives.
#
# Usage:
#   bash export_editor_manifest.sh [options] [output_file.csv]
#
# Options:
#   --db <path>          Path to .backup_history.sqlite3 (auto-detected if omitted)
#   --videos             Export only video assets
#   --photos             Export only photo assets
#   --device <name>      Filter by device name (case-insensitive substring)
#   --date <YYYY-MM>     Filter by capture date (e.g. 2026-11)
#   --search <query>     Search by original filename or path
#   --stats              Print summary statistics of backed-up media
#   --stdout             Output CSV to standard output instead of a file
#   --help, -h           Show this help message
# ==============================================================================

set -eu
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; }

show_help() {
    cat <<EOF
iPhone Auto Backup - Editor Handover & Manifest Tool

Usage:
  bash export_editor_manifest.sh [options] [output_file.csv]

Options:
  --db <path>          Path to SQLite history database
  --videos             Export only video records
  --photos             Export only photo records
  --device <name>      Filter by device name (e.g. "Gunjan's iPhone")
  --date <YYYY-MM>     Filter by capture date (e.g. "2026-11")
  --search <query>     Search by original filename (e.g. "IMG_4521")
  --stats              Display media statistics without exporting CSV
  --stdout             Print CSV directly to terminal/stdout
  --help, -h           Show this help message

Examples:
  # Export full manifest for editor to external drive root:
  bash export_editor_manifest.sh /Volumes/MyExternalDrive/editor_manifest.csv

  # Export only videos shot in November 2026:
  bash export_editor_manifest.sh --videos --date 2026-11 videos_nov_2026.csv

  # Search which backup file corresponds to IMG_4521.MOV:
  bash export_editor_manifest.sh --search IMG_4521
EOF
}

main() {
    local db_path=""
    local out_csv=""
    local filter_type=""
    local filter_device=""
    local filter_date=""
    local search_query=""
    local show_stats=false
    local use_stdout=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --db)         shift; db_path="${1:-}"; shift ;;
            --videos)     filter_type="video"; shift ;;
            --photos)     filter_type="photo"; shift ;;
            --device)     shift; filter_device="${1:-}"; shift ;;
            --date)       shift; filter_date="${1:-}"; shift ;;
            --search)     shift; search_query="${1:-}"; shift ;;
            --stats)      show_stats=true; shift ;;
            --stdout)     use_stdout=true; shift ;;
            --help|-h)    show_help; exit 0 ;;
            *)
                if [[ -z "$out_csv" ]]; then
                    out_csv="$1"
                else
                    err "Unexpected argument: $1"
                    show_help; exit 1
                fi
                shift
                ;;
        esac
    done

    # Resolve database path if not provided explicitly
    if [[ -z "$db_path" ]]; then
        db_path=$(resolve_history_db "$BACKUP_ROOT")
    fi

    if [[ ! -f "$db_path" ]]; then
        err "History database not found: $db_path"
        echo "  Run a backup or import first to generate the history database."
        exit 1
    fi

    # Build SQL WHERE clause
    local -a where_clauses=()
    if [[ -n "$filter_type" ]]; then
        where_clauses+=("media_type = '$filter_type'")
    fi
    if [[ -n "$filter_device" ]]; then
        local safe_dev_filter="${filter_device//\'/\'\'}"
        where_clauses+=("device_name LIKE '%$safe_dev_filter%'")
    fi
    if [[ -n "$filter_date" ]]; then
        local safe_date="${filter_date//\'/\'\'}"
        where_clauses+=("capture_timestamp LIKE '$safe_date%'")
    fi
    if [[ -n "$search_query" ]]; then
        local safe_search="${search_query//\'/\'\'}"
        where_clauses+=("(original_filename LIKE '%$safe_search%' OR backup_path LIKE '%$safe_search%')")
    fi

    local where_sql=""
    if [[ ${#where_clauses[@]} -gt 0 ]]; then
        local joined
        joined=$(IFS=" AND "; echo "${where_clauses[*]}")
        where_sql="WHERE $joined"
    fi

    # Mode: Statistics
    if $show_stats; then
        echo ""
        echo "======================================================================"
        echo "                 iPhone Backup History Statistics"
        echo "======================================================================"
        echo "Database: $db_path"
        echo ""
        "$SQLITE3" -header -column "$db_path" <<SQL
SELECT
    media_type AS "Type",
    category AS "Category",
    COUNT(*) AS "Total Files",
    round(SUM(file_size) / (1024.0 * 1024.0 * 1024.0), 2) AS "Total (GB)",
    min(capture_timestamp) AS "Earliest Shot",
    max(capture_timestamp) AS "Latest Shot"
FROM backup_history
$where_sql
GROUP BY media_type, category;
SQL
        echo ""
        echo "Devices in database:"
        "$SQLITE3" -column "$db_path" <<SQL
SELECT '  - ' || device_name || ' (' || device_model || '): ' || COUNT(*) || ' files'
FROM backup_history
$where_sql
GROUP BY device_name, device_model;
SQL
        echo "======================================================================"
        echo ""
        exit 0
    fi

    # Default CSV output destination
    if [[ -z "$out_csv" ]] && ! $use_stdout; then
        local parent_dir
        parent_dir="$(dirname "$db_path")"
        out_csv="$parent_dir/editor_manifest.csv"
    fi

    local query="
SELECT
    backup_path AS \"Backup Path\",
    original_filename AS \"Original Filename\",
    media_type AS \"Media Type\",
    category AS \"Category\",
    device_name AS \"Device Name\",
    device_model AS \"Device Model\",
    capture_timestamp AS \"Capture Timestamp\",
    round(file_size / (1024.0 * 1024.0), 2) AS \"File Size (MB)\",
    content_hash AS \"Content Hash\",
    backed_up_at AS \"Backed Up At\"
FROM backup_history
$where_sql
ORDER BY capture_timestamp ASC;
"

    if $use_stdout; then
        "$SQLITE3" -header -csv "$db_path" <<< "$query"
    else
        mkdir -p "$(dirname "$out_csv")"
        "$SQLITE3" -header -csv "$db_path" <<< "$query" > "$out_csv"
        info "Exported manifest successfully: $out_csv"
        local rows; rows=$(wc -l < "$out_csv" | tr -d ' ')
        rows=$(( rows > 0 ? rows - 1 : 0 ))
        echo "  Contains $rows media records ready for editor handover."
    fi
}

main "$@"

