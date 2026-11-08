<div align="center">

# iPhone Auto Backup

Auto-backup iPhone photos & videos to an external drive on USB plug-in.<br>
EXIF date archiving, content-hash deduplication, zero cloud dependency.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)
![Language](https://img.shields.io/badge/language-Bash-green.svg)
![Dependencies](https://img.shields.io/badge/dependencies-libimobiledevice%20%2B%20exiftool-orange.svg)
![ShellCheck](https://img.shields.io/github/actions/workflow/status/vbv611/iphone-auto-backup/shellcheck.yml?label=shellcheck)
![Stars](https://img.shields.io/github/stars/vbv611/iphone-auto-backup?style=social)
![Forks](https://img.shields.io/github/forks/vbv611/iphone-auto-backup?style=social)
![Release](https://img.shields.io/github/v/release/vbv611/iphone-auto-backup)

**Maintained by Vaibhav Bhootna**

</div>

---

## Why this exists

Every time you plug in your iPhone, macOS wants to open Photos.app or Image Capture — but neither provides **automatic, deduplicated, date-sorted** backups to an external drive. Cloud storage charges recurring monthly fees and introduces vendor lock-in. Proprietary tools cost $40+. 

This tool provides a lightweight, automated, and secure local backup solution with zero cloud dependencies, powered entirely via macOS `launchd` and `libimobiledevice`.

### Who is this for?

- **Photographers** — Auto-archive camera shoots sorted by EXIF date without manual sorting.
- **Parents** — Plug in and back up family memories automatically every day.
- **Data Preservationists** — Partial SHA1 content hashing guarantees zero duplicate copies.
- **Privacy-Conscious Users** — Zero telemetry, zero cloud, files remain strictly on your local disk.
- **iPhone Owners** — Automated peace of mind whenever your phone connects to your Mac.

---

## Features

- **Auto-Trigger on USB Connection** — Background `launchd` daemon detects iPhone USB events automatically.
- **Content-Hash Deduplication** — Computes SHA1 of file size + first 512KB + last 512KB to prevent duplicate copies.
- **Collision-Proof Naming for Editors** — Formats media as `YYYYMMDD_HHMMSS_<Device>_<OriginalName>` to eliminate filename clashes in NLE editors (Premiere, DaVinci Resolve, Final Cut).
- **Persistent SQLite History & CSV Manifest** — Records every transfer to `.backup_history.sqlite3` and generates `editor_manifest.csv` for post-production handover.
- **macOS Extended Attributes (`xattr`)** — Stamps original filename and device name natively onto files with zero impact on media bytes.
- **EXIF Date Archiving** — Reads `DateTimeOriginal` / `CreateDate` tags and sorts files into `YYYY-MM-DD` directory trees.
- **Intelligent Classification** — Categorizes media into `Photos/`, `Screenshots/`, and `Saved_Images/` using Apple `sips`.
- **Apple ProRAW & Native Formats** — Full support for `.DNG`, `.HEIC`, `.MOV`, `.MP4`, `.PNG`, and `.JPG`.
- **Incremental Device-Side Pre-Filtering** — Fast-paths previously transferred media using UDID-isolated cache keys.
- **Integrity Verification** — Validates local file size against device-side `st_size` with automated single-retry on truncation.
- **Sleep Prevention** — Holds system awake during active transfers using macOS `caffeinate`.
- **Desktop Notifications** — Emits native macOS user notifications for start, completion, and error states.
- **Original Capture Timestamping** — Aligns local file access and modification times (`mtime`) with camera capture dates.
- **Image Capture & External Migration** — Ingest or index media previously copied via Apple Image Capture to prevent duplicate downloads.
- **Zero Cloud Dependency** — Direct Apple File Conduit (AFC) extraction directly to your external drive.

---

## How It Works

```
iPhone (USB)
    │
    ▼
┌─────────────────────────────┐
│  iphone_backup_monitor.sh   │  ← launchd daemon (KeepAlive)
│  Polls idevice_id every 10s │
└──────────┬──────────────────┘
           │ iPhone detected & trusted
           ▼
    ┌──────┴──────┐
    ▼             ▼ (Sequential Execution)
 backup_videos   backup_photos
    │             │
    │  ┌──────────┘
    ▼  ▼
 Scan DCIM via afcclient
    │
    ▼
 Device-side pre-filter ──── skip (UDID + path + size unchanged)
    │
    ▼
 Download via AFC to secure staging
    │
    ▼
 Size verify (auto-retry on truncation)
    │
    ▼
 Content hash dedup ──────── skip (hash already seen)
    │
    ▼
 Read EXIF date ──→ fallback: filename ──→ device mtime ──→ _unknown_date
    │
    ▼
 Classify (Photos / Screenshots / Saved Images)   ← photos only
    │
    ▼
 Archive → /Volumes/Drive/iPhone_Photos/Photos/2026-04-09/001.heic
    │
    ▼
 Set file mtime = EXIF timestamp
    │
    ▼
 macOS desktop notification ✅
```

---

## Quick Start

```bash
# 1. Clone repository
git clone https://github.com/vbv611/iphone-auto-backup.git
cd iphone-auto-backup

# 2. Edit configuration (set your drive paths)
nano config.sh
# Set BACKUP_ROOT and PHOTO_BACKUP_ROOT to your drive, e.g.:
#   BACKUP_ROOT="/Volumes/MyExternalDrive/iPhone_Videos"
#   PHOTO_BACKUP_ROOT="/Volumes/MyExternalDrive/iPhone_Photos"

# 3. Install dependencies and register launchd daemon
bash install.sh
```

### First Run Walkthrough

1. Mount the external drive configured in `config.sh`.
2. Connect your iPhone via USB, unlock it, and tap **"Trust This Computer"**.
3. Monitor status in real-time: `cat /tmp/iphone_backup_monitor.status`
4. Run an optional smoke test manually:
   ```bash
   bash backup_videos_v3.sh
   bash backup_photos_v3.sh
   ```

> [!NOTE]
> Backup scripts will never create dummy folders on your internal Mac boot drive if the external drive is unmounted; they notify and exit safely instead.

---

### Migrating from Apple Image Capture or External Folders

If you already copied photos and videos from your iPhone using Apple **Image Capture** or Finder to an external drive, you can integrate them seamlessly without downloading duplicates when connecting your phone:

```bash
# Option 1: Organize flat folder into date-based backup directories and index
bash import_image_capture.sh /Volumes/MyExternalDrive/Old_Image_Capture_Dump

# Option 2: Keep your existing folder untouched, but index all files so the iPhone won't duplicate them
bash import_image_capture.sh --index-only /Volumes/MyExternalDrive/My_Existing_Photos

# Option 3: Test what will happen without making any changes
bash import_image_capture.sh --dry-run /Volumes/MyExternalDrive/Old_Image_Capture_Dump
```

See the [Operations Guide](docs/OPERATIONS_GUIDE.md#7-migrating--importing-media-from-image-capture-or-external-folders) for detailed options.

---

### Upgrading Existing Backups to the Collision-Proof Format

If you have existing backups created with sequential names (`001.mov`, `001.heic`), you can upgrade them in-place to the new collision-proof format without re-downloading anything or losing deduplication indexes:

```bash
# 1. Preview what will be renamed (safe dry-run mode):
bash migrate_existing_data.sh --dry-run

# 2. Execute migration live:
bash migrate_existing_data.sh --run

# 3. Optional: supply an explicit device name instead of auto-detecting from EXIF:
bash migrate_existing_data.sh --run --device "Vaibhavs_iPhone"
```

* **Preserves Bit-for-Bit Integrity:** Media streams are unchanged; deduplication hashes remain 100% valid.
* **Pairs Companion Files:** `.aae` edit sidecars are automatically renamed to match their photo pair.
* **Generates Manifests:** Populates `.backup_history.sqlite3` and exports `editor_manifest.csv`.

---

## Terminal Demo

```
$ bash backup_videos_v3.sh

[14:23:01] ==== iPhone Video Backup v3 ====
[OK] iPhone connected
[14:23:01] Mac sleep prevented (caffeinate PID 48291)
[14:23:01] Scanning iPhone camera roll for videos...
[OK] Found 47 video(s)

  45% |████████████░░░░░░░░░░░░| 21/47  IMG_4523.MOV
[OK] IMG_4523.MOV -> 2026-04-07/001.mov
[SKIP] Duplicate content: IMG_4524.MOV
[OK] IMG_4525.MOV -> 2026-04-07/002.mov
  ...
[OK] IMG_4569.MOV -> 2026-04-09/003.mov

======================================================================
                    iPhone Video Backup Report
                    Author: Vaibhav Bhootna
======================================================================
Destination:  /Volumes/MyDrive/iPhone_Videos
Total:        482 video file(s)
New:          12 video(s)
Skipped:      35 (28 skipped instantly via pre-filter)
Failed:       0 video(s)
======================================================================
```

---

## Comparison

| Feature | iCloud Photos | Image Capture | iMazing | **This Tool** |
|---------|:---:|:---:|:---:|:---:|
| **Cost** | 5GB free limit | Free | $40+ | **Free & Open Source** |
| **Auto-trigger on USB** | No (Wi-Fi) | No (Manual) | Yes | **Yes (launchd)** |
| **Content-hash dedup** | No | No | No | **Yes (SHA1)** |
| **Sort by EXIF date** | No | No | Yes | **Yes** |
| **Photo classification** | No | No | No | **Yes (sips)** |
| **Incremental pre-filter** | N/A | No | Yes | **Yes (UDID-scoped)** |
| **No cloud dependency** | No | Yes | Yes | **Yes (100% Local)** |
| **File mtime = shoot date** | N/A | No | No | **Yes** |

---

## Backup Structure

```
/Volumes/YourDrive/
├── .backup_history.sqlite3                      # Complete queryable backup database
├── editor_manifest.csv                          # Handover manifest for video/photo editors
│
├── iPhone_Videos/
│   └── 2026-04-07/
│       ├── 20260407_143000_Vaibhavs_iPhone_IMG_0042.mov
│       └── 20260407_143512_Vaibhavs_iPhone_IMG_0043.mov
│
└── iPhone_Photos/
    ├── Photos/
    │   └── 2026-04-09/
    │       ├── 20260409_091522_Vaibhavs_iPhone_IMG_1021.heic
    │       ├── 20260409_091522_Vaibhavs_iPhone_IMG_1021.aae    # Companion edit sidecar
    │       └── 20260409_091804_Vaibhavs_iPhone_IMG_1022.dng
    ├── Screenshots/
    │   └── 2026-04-10/
    │       └── 20260410_182045_Vaibhavs_iPhone_IMG_1023.png
    └── Saved_Images/
        └── 2026-04-10/
            └── 20260410_200511_Vaibhavs_iPhone_IMG_1024.gif
```

---

## Editor Handover & Manifest Tool

Export clean CSV spreadsheets for editors or query backup history:

```bash
# Export full manifest for editor:
bash export_editor_manifest.sh /Volumes/YourDrive/editor_manifest.csv

# Export only videos shot in November 2026:
bash export_editor_manifest.sh --videos --date 2026-11 videos_nov_2026.csv

# Search which backed up file corresponds to IMG_4521.MOV:
bash export_editor_manifest.sh --search IMG_4521

# Display storage and camera statistics:
bash export_editor_manifest.sh --stats
```

---

## Configuration (`config.sh`)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `BACKUP_ROOT` | Target path for video backups | `/Volumes/YourExternalDrive/iPhone_Videos` |
| `PHOTO_BACKUP_ROOT` | Target path for photo backups | `/Volumes/YourExternalDrive/iPhone_Photos` |
| `VIDEO_EXTENSIONS` | Supported video formats | `MOV MP4 M4V 3GP AVI MKV` |
| `PHOTO_EXTENSIONS` | Supported photo formats | `JPG JPEG HEIC PNG GIF DNG` |
| `FILENAME_FORMAT` | Naming style (`timestamp_device_original`, `timestamp_original`, `device_original`, `original`, `sequential`) | `timestamp_device_original` |
| `BACKUP_HISTORY_DB` | Custom SQLite database path (defaults to root of backup volume) | `""` (auto-located) |
| `AUTO_EXPORT_MANIFEST` | Automatically generate/refresh `editor_manifest.csv` after backup | `1` (enabled) |
| `AUTO_REFRESH_INDEX` | Execute optional indexer post-backup | `0` (off) |

---

## Dependencies

| Tool | Purpose | Installation |
|------|---------|--------------|
| `libimobiledevice` | Native iOS USB protocol communication (`afcclient`, `idevicepair`) | `brew install libimobiledevice` |
| `exiftool` | Extracts EXIF dates and camera metadata | `brew install exiftool` |

---

## Documentation Suite

Comprehensive engineering documentation is available in [`docs/`](docs/README.md):
- [Architecture & Technical Design](docs/ARCHITECTURE.md)
- [Security Audit & Vulnerabilities](docs/SECURITY_AUDIT.md)
- [Reliability & Edge-Case Engineering Analysis](docs/RELIABILITY_ANALYSIS.md)
- [Operations, Maintenance & Troubleshooting Manual](docs/OPERATIONS_GUIDE.md)

---

## File Structure

```
iphone-auto-backup/
├── config.sh                             # Configuration (target paths, formats)
├── backup_videos_v3.sh                   # Video backup engine
├── backup_photos_v3.sh                   # Photo backup engine
├── backup_safe.sh                        # Safe copy utility (v1 legacy)
├── iphone_backup_monitor.sh              # USB connection watcher daemon
├── import_image_capture.sh               # Image Capture & external folder importer / indexer
├── rebuild_hash_index.sh                 # Hash index rebuild and maintenance tool
├── install.sh                            # One-click installer (Homebrew + launchd)
├── uninstall.sh                          # Uninstaller (removes launchd services)
├── com.user.iphone-backup-monitor.plist  # launchd configuration (monitor daemon)
├── com.user.iphone-video-backup.plist    # launchd configuration (legacy video)
├── com.user.iphone-photo-backup.plist    # launchd configuration (legacy photo)
└── docs/                                 # Engineering documentation
    ├── ARCHITECTURE.md                   # System design & sequence flows
    ├── SECURITY_AUDIT.md                 # Vulnerability report & hardening
    ├── RELIABILITY_ANALYSIS.md           # Failure points, edge cases & limits
    └── OPERATIONS_GUIDE.md               # User guide & operations manual
```

---

## FAQ

**Q: Backup doesn't auto-trigger when USB is plugged in?**  
A: Ensure your iPhone is unlocked and you tapped "Trust This Computer". Verify daemon status via `cat /tmp/iphone_backup_monitor.status`.

**Q: Same file backed up twice?**  
A: v3 uses partial SHA1 content-hash deduplication. The hash database resides in `~/.iphone_video_backup_v3.hashes` and `~/.iphone_photo_backup_v3.hashes`.

**Q: `install.sh` refuses to install due to placeholders?**  
A: Edit `config.sh` first. Replace `YourExternalDrive` with the name of your mounted external storage volume.

**Q: How do I uninstall the automatic background trigger?**  
A: Run `bash uninstall.sh`. Your scripts, backup files, and deduplication databases will remain completely intact.

---

## Uninstall & Maintenance

```bash
# Remove background launchd daemon
bash uninstall.sh

# Reset deduplication index caches (re-evaluates all files on next run)
rm -f ~/.iphone_video_backup_v3.hashes ~/.iphone_photo_backup_v3.hashes
rm -f ~/.iphone_video_backup_v3.device_seen ~/.iphone_photo_backup_v3.device_seen
rm -f ~/.iphone_video_backup_v3.state ~/.iphone_photo_backup_v3.state

# Rebuild hash index from existing backup drive
bash rebuild_hash_index.sh --all
```

---

## Contributing

Contributions and improvements are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md).

---

## License

[MIT](LICENSE) © 2026 Vaibhav Bhootna
