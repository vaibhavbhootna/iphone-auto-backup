# Hard Drive Storage & Backup Rules for AI Agents
**Target Volume:** `/Volumes/My Passport`  
**Applicability:** All AI Agents copying, ingesting, migrating, or indexing media to this external drive.

---

## 1. Golden Rule: Always Ask the User First

> [!IMPORTANT]
> **MANDATORY USER INTERACTION:**
> Before copying, moving, or indexing any data to `/Volumes/My Passport`, the agent **MUST ALWAYS ask the user** what type of media they are backing up.
>
> **Required Prompt Questions:**
> 1. What category does this media belong to?
>    - **Phone Dump** (daily phone photos & videos)
>    - **Trip / Vlog Project** (vacations, travel footage, YouTube projects)
>    - **Milestone Event / Wedding** (weddings, birthdays, shoots, family functions)
>    - **Spiritual / Mandir** (temple recordings, satsang, bhandara)
>    - **Family Archive / Old Scans** (scanned prints, old digital camera dumps)
> 2. Is this folder already sorted by project/trip?
>    - If **Yes**: Keep files in place; perform **in-place indexing only** (`--index-only`).
>    - If **No**: Organize into the standardized date/device hierarchy (`--copy` or `--move`).

---

## 2. Hard Drive Folder Architecture (The 5 Pillars)

Agents must **never** create arbitrary root-level folders. All media must route into one of the 5 designated pillars on `/Volumes/My Passport`:

```
/Volumes/My Passport/
│
├── 📁 01_Phone_Backups/
│   ├── iPhone_Videos/                 (Date-based: YYYY-MM-DD/HHMMSS_Device_Name.mov)
│   └── iPhone_Photos/                 (Type & Date: Photos/YYYY-MM-DD/, Screenshots/, Saved_Images/)
│
├── 📁 02_Vlogs_and_Trips/
│   ├── Vlog_Raw_Data/                 (Yearly raw footage: 2021-2025, Drone)
│   ├── Maldives_Trip/                 (Travel raw footage preserved intact)
│   ├── Finished_Vlogs/                (Edited final vlogs: 2022-2025)
│   └── Reels/                         (Social media short-form video cuts)
│
├── 📁 03_Events_and_Weddings/
│   ├── Vaibhav_Wedding/               (Main wedding photo & video archive)
│   ├── Sampda_x_Praneeth/             (Ceremony & photoshoot archive)
│   ├── Atharv/                        (Gender Reveal, Inst360, Maternity Studio, Marina Barrage)
│   ├── Bali_Trip_and_Wedding/         (Ceremony & invite assets)
│   ├── Mummy_Retirement/              (Retirement function photo album)
│   └── Sugandha_Marriage/             (MPEG ceremony recordings)
│
├── 📁 04_Spiritual_and_Mandir/
│   ├── Mandir_Archives/               (Event subfolders from /Mandir)
│   ├── Mandir_Videos/                 (Master video clips from /Mandir Videos)
│   └── Mandir_2018/                   (Footage from /2018/mandir)
│
└── 📁 05_Family_Archives/
    ├── Akshu_Archive/                 (Birthday and festive family photo albums)
    └── 2018_Mac_Photos/               (Traditional albums, Nikon SG trip, pre-wedding)
```

---

## 3. Storage & Ingestion Policies

### Policy 1: Pre-Sorted Trip & Vlog Footage (In-Place Indexing)
- If the media is already organized by trip, vacation, or vlog episode:
  - **DO NOT MOVE OR RENAME FILES.**
  - Register files in-place using: `bash import_image_capture.sh --index-only "<path>"`
  - This records content hashes in `~/.iphone_*_backup_v3.hashes` so connected iPhones will never re-download them, logs metadata into SQLite, and updates `editor_manifest.csv`.

### Policy 2: Unsorted / Phone Backups (Standard Ingestion)
- Files must be categorized into:
  - **Videos**: Destination is `iPhone_Videos/YYYY-MM-DD/`
  - **Photos**: Destination is `iPhone_Photos/{Photos|Screenshots|Saved_Images}/YYYY-MM-DD/`
- Standard naming format:
  `${compact_ts}_${file_dev}_${clean_original_filename}`
  Example: `20210203_235830_iPhone_11_Pro_IMG_6480.HEIC`
- Extract EXIF `DateTimeOriginal` / `CreateDate` and preserve capture timestamp via `touch -t`.
- Extract camera model from EXIF (`iPhone 11 Pro`, `Sony A7 III`, `Nikon D5200`, `OnePlus`, etc.).

### Policy 3: Zero-Data-Loss & Duplicate Safety
- Compute partial SHA-1 content hash for every file:
  `${size}_${head_sha1}_${tail_sha1}` (524,288 bytes head & tail).
- Check against `~/.iphone_video_backup_v3.hashes` and `~/.iphone_photo_backup_v3.hashes`.
- **Never silently delete files.** Any duplicates must be staged in `<source_folder>/_already_backed_up/`.
- Verify 100% of staged duplicates against hash databases before purging source stubs.

### Policy 4: Audit & Tracking
- Log every ingestion in `/Volumes/My Passport/.iphone_backup_history.sqlite3`.
- Always refresh editor manifests upon completing a batch:
  - `/Volumes/My Passport/iPhone_Videos/editor_manifest.csv`
  - `/Volumes/My Passport/iPhone_Photos/editor_manifest.csv`

### Policy 5: Clean Up
- Only remove a source directory if **all** media files have been moved and zero unindexed files remain.
- Companion `.AAE` edit sidecars must be moved alongside their parent photos.
- Purge orphaned macOS `._*` AppleDouble stubs after moving source files.
