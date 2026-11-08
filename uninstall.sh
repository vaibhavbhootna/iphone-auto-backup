#!/bin/bash
# ==============================================================================
# iPhone Auto Backup - Uninstallation Script
# Author: Vaibhav Bhootna
# Repository: https://github.com/vbv611/iphone-auto-backup
#
# This script unregisters and removes the launchd background service.
# It does NOT remove your local scripts, backup data, or deduplication indexes.
# ==============================================================================

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }

LA="$HOME/Library/LaunchAgents"
AGENTS=(
    com.user.iphone-backup-monitor
    com.user.iphone-video-backup
    com.user.iphone-photo-backup
)

echo ""
echo "=================================================="
echo "   iPhone Auto Backup - Uninstaller"
echo "   Author: Vaibhav Bhootna"
echo "=================================================="
echo ""

removed=0
for name in "${AGENTS[@]}"; do
    plist="$LA/$name.plist"
    if [[ -f "$plist" ]]; then
        launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        info "Unregistered and removed: $name.plist"
        removed=$((removed + 1))
    fi
done

if [[ "$removed" -eq 0 ]]; then
    warn "No existing launchd configuration found (service may not be installed)."
fi

echo ""
echo "=================================================="
echo ""
info "Uninstallation Complete!"
echo ""
echo "  launchd Daemon: Removed."
echo "  Script Files: Preserved in $SCRIPT_DIR"
echo "  Backup Data: Preserved on disk:"
echo "    $BACKUP_ROOT"
echo "    $PHOTO_BACKUP_ROOT"
echo "  Deduplication / Hash Indexes: Preserved in ~/.iphone_*_backup_v3.*"
echo ""
echo "To permanently clear local deduplication caches (without deleting backups):"
echo "  rm -f ~/.iphone_video_backup_v3.hashes ~/.iphone_photo_backup_v3.hashes"
echo "  rm -f ~/.iphone_video_backup_v3.device_seen ~/.iphone_photo_backup_v3.device_seen"
echo "  rm -f ~/.iphone_video_backup_v3.state ~/.iphone_photo_backup_v3.state"
echo ""
echo "To remove backup data on your drive, verify paths before deleting:"
echo "  rm -rf \"$BACKUP_ROOT\" \"$PHOTO_BACKUP_ROOT\""
echo ""
