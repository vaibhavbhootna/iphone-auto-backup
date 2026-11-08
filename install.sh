#!/bin/bash
# ==============================================================================
# iPhone Auto Backup - Installer
# Author: Vaibhav Bhootna
# Repository: https://github.com/vbv611/iphone-auto-backup
#
# This script installs required dependencies (libimobiledevice, exiftool) via
# Homebrew, ensures executable permissions on all project scripts, and registers
# the background monitor daemon with macOS launchd.
# ==============================================================================

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

# ---------- Terminal Formatting Helpers ----------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; }

# Locate Homebrew executable across Apple Silicon and Intel Mac architectures.
find_brew() {
    if [[ -x /opt/homebrew/bin/brew ]]; then
        BREW="/opt/homebrew/bin/brew"
    elif [[ -x /usr/local/bin/brew ]]; then
        BREW="/usr/local/bin/brew"
    elif command -v brew >/dev/null 2>&1; then
        BREW="$(command -v brew)"
    else
        BREW=""
    fi
}

# Verify configuration before proceeding. Rejects unedited template placeholders.
check_config() {
    echo ""
    echo "Checking configuration..."
    if config_has_placeholders; then
        err "config.sh still contains the placeholder 'YourExternalDrive'."
        echo "  Please edit config.sh before installing:"
        echo "    nano $SCRIPT_DIR/config.sh"
        echo "  Set BACKUP_ROOT and PHOTO_BACKUP_ROOT to your mounted external drive path."
        exit 1
    fi
    info "Video Backup Destination: $BACKUP_ROOT"
    info "Photo Backup Destination: $PHOTO_BACKUP_ROOT"
}

# Verify that Homebrew package manager is installed on the system.
check_homebrew() {
    echo ""
    echo "Checking Homebrew package manager..."
    find_brew
    if [[ -z "$BREW" ]]; then
        err "Homebrew was not found. Please install Homebrew first:"
        echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 1
    fi
    info "Homebrew found ($("$BREW" --version | head -n 1))"
}

# Check if a specific binary tool is installed and executable.
tool_installed() {
    local name="$1"
    [[ -x "/opt/homebrew/bin/$name" || -x "/usr/local/bin/$name" ]] || command -v "$name" >/dev/null 2>&1
}

# Ensure libimobiledevice and exiftool are installed.
check_deps() {
    echo ""
    echo "Checking required dependencies..."

    if ! tool_installed idevice_id; then
        warn "libimobiledevice not found. Installing via Homebrew..."
        "$BREW" install libimobiledevice
    else
        info "libimobiledevice is installed"
    fi

    if ! tool_installed exiftool; then
        warn "exiftool not found. Installing via Homebrew..."
        "$BREW" install exiftool
    else
        info "ExifTool is installed"
    fi

    local prefix
    prefix="$("$BREW" --prefix)"
    if [[ ! -x "$prefix/bin/idevice_id" ]] && ! command -v idevice_id >/dev/null 2>&1; then
        err "Could not locate idevice_id after installation ($prefix/bin/idevice_id)"
        exit 1
    fi
    if [[ ! -x "$prefix/bin/exiftool" ]] && ! command -v exiftool >/dev/null 2>&1; then
        err "Could not locate exiftool after installation ($prefix/bin/exiftool)"
        exit 1
    fi
}

# Grant execution permissions (chmod +x) to all project shell scripts.
set_perms() {
    echo ""
    echo "Configuring script permissions..."
    local f
    for f in backup_videos_v3.sh backup_photos_v3.sh iphone_backup_monitor.sh \
             install.sh uninstall.sh rebuild_hash_index.sh backup_safe.sh \
             import_image_capture.sh export_editor_manifest.sh; do
        chmod +x "$SCRIPT_DIR/$f"
    done
    info "Executable permissions applied"
}

# Install and bootstrap a launchd service agent.
install_plist() {
    local plist_name="$1"
    local plist_src="$SCRIPT_DIR/$plist_name"
    local plist_dest="$HOME/Library/LaunchAgents/$plist_name"

    if [[ ! -f "$plist_src" ]]; then
        err "Template file not found: $plist_src"
        return 1
    fi

    mkdir -p "$HOME/Library/LaunchAgents"

    # Unload existing agent if present
    launchctl bootout "gui/$(id -u)" "$plist_dest" 2>/dev/null || true
    launchctl unload "$plist_dest" 2>/dev/null || true

    # Substitute script directory placeholder with actual directory path
    sed "s|__SCRIPT_DIR__|$SCRIPT_DIR|g" "$plist_src" > "$plist_dest"
    launchctl bootstrap "gui/$(id -u)" "$plist_dest" 2>/dev/null || launchctl load "$plist_dest"
    info "launchd agent loaded: $plist_name"
}

# Unload deprecated launchd agents and install the unified monitor service.
install_launchd() {
    echo ""
    echo "Registering launchd background daemon..."
    local old old_dest
    for old in com.user.iphone-video-backup.plist com.user.iphone-photo-backup.plist; do
        old_dest="$HOME/Library/LaunchAgents/$old"
        launchctl bootout "gui/$(id -u)" "$old_dest" 2>/dev/null || true
        launchctl unload "$old_dest" 2>/dev/null || true
        rm -f "$old_dest"
    done
    install_plist "com.user.iphone-backup-monitor.plist"
}

# List currently mounted non-system external volumes under /Volumes.
list_external_volumes() {
    local vol base found=0
    for vol in /Volumes/*; do
        [[ -e "$vol" ]] || continue
        base="$(basename "$vol")"
        [[ "$base" == "Macintosh HD" ]] && continue
        printf '%s ' "$base"
        found=1
    done
    if [[ "$found" -eq 0 ]]; then
        printf '%s' "(No external drive currently detected)"
    fi
}

# Display post-installation verification and usage instructions.
prompt_config() {
    echo ""
    echo "=================================================="
    echo ""
    info "Installation Complete!"
    echo ""
    echo "  Configured Backup Paths:"
    echo "    BACKUP_ROOT=$BACKUP_ROOT"
    echo "    PHOTO_BACKUP_ROOT=$PHOTO_BACKUP_ROOT"
    echo ""
    echo "  Detected External Drives:"
    echo "    $(list_external_volumes)"
    echo ""
    echo "  Background Daemon: Active and listening for trusted iPhone USB connections."
    echo ""
    echo "Getting Started:"
    echo "  1. Connect your iPhone via USB, unlock it, and tap 'Trust This Computer'."
    echo "  2. Ensure your designated external drive is connected and mounted."
    echo "  3. Check daemon status: cat /tmp/iphone_backup_monitor.status"
    echo ""
    echo "Manual Test Commands:"
    echo "  bash $SCRIPT_DIR/backup_videos_v3.sh"
    echo "  bash $SCRIPT_DIR/backup_photos_v3.sh"
    echo "  bash $SCRIPT_DIR/import_image_capture.sh --help"
    echo ""
    echo "Log Files:"
    echo "  cat /tmp/iphone_backup_monitor.status"
    echo "  cat /tmp/iphone_backup_stdout.log"
    echo "  cat /tmp/iphone_photo_backup_stdout.log"
    echo ""
    echo "Uninstall: bash $SCRIPT_DIR/uninstall.sh"
    echo ""
}

# Main installer entry point.
main() {
    echo ""
    echo "=================================================="
    echo "   iPhone Auto Backup - Installer"
    echo "   Author: Vaibhav Bhootna"
    echo "=================================================="

    check_config
    check_homebrew
    check_deps
    set_perms
    install_launchd
    prompt_config
}

main "$@"
