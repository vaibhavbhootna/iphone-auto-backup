# Operations, Maintenance & Troubleshooting Manual
**Author**: Vaibhav Bhootna  
**Repository**: [https://github.com/vbv611/iphone-auto-backup](https://github.com/vbv611/iphone-auto-backup)

## 1. Prerequisites & System Setup

### Hardware & OS Requirements
* **Operating System**: macOS 12 (Monterey), 13 (Ventura), 14 (Sonoma), 15 (Sequoia), or later.
* **Architecture**: Apple Silicon (`arm64`) or Intel (`x86_64`).
* **Connection**: Physical USB-to-Lightning or USB-to-Type-C cable connected directly to the Mac (USB hubs without dedicated power may drop connections during large media transfers).
* **Storage**: Formatted external drive (APFS or exFAT recommended).

### Dependency Installation
The system requires `libimobiledevice` (for Apple File Conduit communication) and `exiftool` (for metadata reading).

```bash
# 1. Install Homebrew (if not already installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. Install required packages
brew install libimobiledevice exiftool
```

---

## 2. Configuration (`config.sh`)

Before installing or running any backup scripts, customize `config.sh`:

```bash
# Open config.sh in an editor
nano config.sh
```

### Essential Settings

```bash
# Destination path for video archives
BACKUP_ROOT="/Volumes/MyExternalDrive/iPhone_Videos"

# Destination path for photo archives
PHOTO_BACKUP_ROOT="/Volumes/MyExternalDrive/iPhone_Photos"

# Formats to back up (Include DNG for ProRAW support)
VIDEO_EXTENSIONS="MOV MP4 M4V 3GP AVI MKV"
PHOTO_EXTENSIONS="JPG JPEG HEIC PNG GIF DNG"

# Set to 1 if you have a custom post-processing indexer script
AUTO_REFRESH_INDEX=0
```

> [!IMPORTANT]
> The installation script will explicitly refuse to register `launchd` if `BACKUP_ROOT` or `PHOTO_BACKUP_ROOT` still contains the default placeholder `YourExternalDrive`.

---

## 3. Installation & Daemon Management

### One-Click Installation
```bash
bash install.sh
```
`install.sh` performs the following automated steps:
1. Verifies that `config.sh` points to valid non-placeholder paths.
2. Checks for Homebrew and installs `libimobiledevice` and `exiftool` if missing.
3. Grants execution permissions (`chmod +x`) to all `.sh` scripts.
4. Generates `~/Library/LaunchAgents/com.user.iphone-backup-monitor.plist` with dynamic path interpolation.
5. Registers and activates the daemon via `launchctl bootstrap`.

### Daemon Control Commands

```bash
# Check daemon execution status in launchd
launchctl list | grep iphone

# Inspect active monitor status
cat /tmp/iphone_backup_monitor.status

# Unload / Stop the daemon
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.user.iphone-backup-monitor.plist

# Reload / Start the daemon
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.user.iphone-backup-monitor.plist
```

### Complete Uninstallation
```bash
bash uninstall.sh
```
* Unregisters all launchd agents.
* Leaves backup files, scripts, and hash databases completely untouched.

---

## 4. Manual Execution & CLI Usage

If you prefer running backups manually or want to verify functionality before enabling automated background execution:

```bash
# Test video backup manually
bash backup_videos_v3.sh

# Test photo backup manually
bash backup_photos_v3.sh

# Trigger an immediate run via the background daemon without replugging USB
touch /tmp/iphone_backup_manual.trigger
```

---

## 5. Monitoring & Log Inspection

Logs are continuously emitted to `/tmp/`:

| Log Target | Description |
| :--- | :--- |
| `cat /tmp/iphone_backup_monitor.status` | Current state machine status (`watching`, `running`, `done`, `failed`) |
| `tail -f /tmp/iphone_backup_monitor_stdout.log` | Monitor daemon event log |
| `tail -f /tmp/iphone_backup_stdout.log` | Video backup stdout log |
| `tail -f /tmp/iphone_backup_stderr.log` | Video backup error log |
| `tail -f /tmp/iphone_photo_backup_stdout.log` | Photo backup stdout log |
| `tail -f /tmp/iphone_photo_backup_stderr.log` | Photo backup error log |

---

## 6. Troubleshooting & Recovery Runbook

### Issue 1: Device Untrusted ("iPhone not connected or not trusted")
* **Symptom**: Script exits or status stays at `waiting_trust`.
* **Remedy**:
  1. Unlock your iPhone with your passcode or Face ID.
  2. Tap **"Trust This Computer"** on the popup dialogue.
  3. Validate pairing from terminal:
     ```bash
     idevicepair validate
     ```
  4. If validation fails, force re-pairing:
     ```bash
     idevicepair pair
     ```

### Issue 2: External Drive Not Mounted
* **Symptom**: Script outputs `Backup volume not mounted or missing: /Volumes/...` and exits.
* **Remedy**: Connect and mount your external disk. The scripts intentionally prevent creating pseudo-folders on the Mac's internal root partition when external media is absent.

### Issue 3: Stale Locks / "Backup already running"
* **Symptom**: Backups fail to start because a previous interrupted run left a lock.
* **Remedy**:
  ```bash
  # Check if a backup process is actually running
  pgrep -fl "backup_.*\.sh"

  # If no process is running, clear stale lock directories:
  rm -rf /tmp/iphone_backup_monitor.lockdir
  rm -rf /tmp/iphone_video_backup_v3.lockdir
  rm -rf /tmp/iphone_photo_backup_v3.lockdir
  ```

### Issue 4: Resetting Deduplication Indexes
If you need to force a re-evaluation of all files or rebuild the hash database:
```bash
# 1. Wipe incremental pre-filter caches (forces re-evaluation without deleting backups):
rm -f ~/.iphone_video_backup_v3.device_seen
rm -f ~/.iphone_photo_backup_v3.device_seen

# 2. Rebuild photo hash index from already backed-up files on your external disk:
bash rebuild_hash_index.sh

# 3. Dry-run test before committing rebuilt hash indexes:
bash rebuild_hash_index.sh --dry-run
```

### Issue 5: Photos Stored in iCloud ("Optimize iPhone Storage")
* **Symptom**: Media files are skipped or flagged as corrupted (`< 1KB`).
* **Root Cause**: The physical file is offloaded to iCloud and only a thumbnail is stored on the phone flash.
* **Solution**:
  1. Go to iPhone **Settings $\to$ Photos**.
  2. Select **"Download and Keep Originals"** instead of "Optimize iPhone Storage".
  3. Connect the phone to Wi-Fi and power until all original assets are downloaded locally to the device.

---

## 7. Migrating & Importing Media from Image Capture or External Folders

If you have already copied media from your iPhone using macOS **Image Capture**, Finder, or another tool onto an external hard drive, that folder may be flat (e.g. `IMG_0001.JPG`, `IMG_0002.MOV`, `IMG_0003.DNG`), unorganized, or outside the utility's directory structure.

Because this media is already on your external hard drive AND still on your iPhone, connecting your iPhone would normally attempt to download everything again if the hashes aren't registered.

The `import_image_capture.sh` script solves this completely.

### Workflow A: Organize Flat Dumps into Date Folders & Index (Recommended)

This takes a flat directory of Image Capture files, organizes them into your configured `BACKUP_ROOT` and `PHOTO_BACKUP_ROOT` (categorized by shoot date: `YYYY-MM-DD/001.heic`, etc.), copies accompanying Apple `.AAE` edit sidecars, and computes content hashes so the iPhone will never re-download them:

```bash
# 1. Preview changes safely without modifying anything:
bash import_image_capture.sh --dry-run /Volumes/MyExternalDrive/Old_Image_Capture_Dump

# 2. Copy and organize into standardized date hierarchy:
bash import_image_capture.sh /Volumes/MyExternalDrive/Old_Image_Capture_Dump

# Or to move files (saving external drive space):
bash import_image_capture.sh --move /Volumes/MyExternalDrive/Old_Image_Capture_Dump
```

### Workflow B: Index-Only (Keep Your Existing Folder Structure Untouched)

If you have already organized your external drive folder in your own custom layout and **do not want files moved or renamed**, you can run in `--index-only` mode:

```bash
# Register all photos & videos into ~/.iphone_*_backup_v3.hashes without moving or copying any files:
bash import_image_capture.sh --index-only /Volumes/MyExternalDrive/My_Existing_Photos_Folder
```

**How it works**:
1. Recursively scans the target folder for supported video and photo formats.
2. Computes the identical partial SHA1 content hash used by `backup_videos_v3.sh` and `backup_photos_v3.sh`.
3. Appends the hash to `~/.iphone_video_backup_v3.hashes` and `~/.iphone_photo_backup_v3.hashes`.
4. When your iPhone is plugged in, the backup daemon detects that the content hashes are already present in the database and **skips them instantly**, avoiding duplicate transfers and saving bandwidth and disk space.


