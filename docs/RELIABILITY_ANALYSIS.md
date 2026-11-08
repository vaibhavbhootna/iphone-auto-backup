# Reliability & Edge-Case Engineering Analysis
**Author**: Vaibhav Bhootna  
**Repository**: [https://github.com/vbv611/iphone-auto-backup](https://github.com/vbv611/iphone-auto-backup)

## 1. Reliability Assessment Summary

**Overall Verdict: Partially Reliable for Basic Single-Device Setups; Unreliable for Advanced/Multi-Device Production Use.**

The `iphone-auto-backup` tool successfully solves the basic problem of backing up standard photos and videos from an iPhone to an external drive without cloud lock-in. It includes thoughtful features such as Mac sleep prevention (`caffeinate`), post-download size verification, and EXIF timestamp preservation.

However, a technical audit reveals **critical architectural edge-case flaws and reliability failure points** that can cause **silent data loss, broken Live Photos, excessive CPU thrashing, and complete backup lockouts**.

---

## 2. Critical Reliability Issues & Failure Modes

---

### REL-01: Silent Data Loss in Multi-Device / Device Reset Scenarios
* **Severity**: **Critical (Silent Data Loss)**
* **Component**: `device_seen` pre-filtering in `backup_videos_v3.sh` and `backup_photos_v3.sh`

#### Mechanism
To avoid re-downloading thousands of files on every connection, the scripts record processed files into `~/.iphone_photo_backup_v3.device_seen`:
```bash
if [[ -n "$dev_size" ]] && device_seen "${src_path}|${dev_size}"; then
    ((skipped++)) || true
    clear_bar
    continue
fi
```
The key consists solely of `${src_path}|${dev_size}`, for example:
`/DCIM/100APPLE/IMG_0001.JPG|2451820`

#### Why This Causes Data Loss
1. **Multiple Devices**: If two iPhones (e.g. personal and work, or two family members) are plugged into the same Mac, both will have files located at `/DCIM/100APPLE/IMG_0001.JPG`. If a photo on Phone B happens to match the byte size of Phone A's photo, **Phone B's photo will be skipped permanently without downloading or hashing**.
2. **Device Replacement / Factory Reset**: When a user upgrades their iPhone or factory resets it, iOS restarts numbering at `IMG_0001.JPG`. Any photo on the new device matching the path and size of an older photo will never be backed up.
3. **Rolled Over Numbers**: iOS wraps camera roll numbers after 9,999 photos.

#### Recommended Fix
Include the hardware Unique Device Identifier (UDID) in the cache key or maintain separate index files per UDID:
```bash
# Recommended key structure
device_seen "${CURRENT_UDID}|${src_path}|${dev_size}"
# Or separate cache files per device:
DEVICE_SEEN="$HOME/.iphone_backup_${CURRENT_UDID}.device_seen"
```

---

### REL-02: Concurrency Collisions & Bus Contention over USB
* **Severity**: **High (Backup Failure / Intermittent Aborts)**
* **Component**: `iphone_backup_monitor.sh` (Lines 47–53)

#### Mechanism
When an iPhone is detected, `iphone_backup_monitor.sh` spawns video and photo backup processes simultaneously in parallel background jobs:
```bash
IPHONE_BACKUP_QUIET_NO_DEVICE=1 bash "$SCRIPT_DIR/backup_videos_v3.sh" &
local video_pid=$!
IPHONE_BACKUP_QUIET_NO_DEVICE=1 bash "$SCRIPT_DIR/backup_photos_v3.sh" &
local photo_pid=$!

wait "$video_pid"; local video_rc=$?
wait "$photo_pid"; local photo_rc=$?
```

#### Why This Is Unreliable
1. **AFC Protocol Contention**: Both processes communicate with the same physical iOS device through `usbmuxd` and the `com.apple.afc` daemon. Heavy parallel read operations over a single USB pipe frequently trigger AFC session timeouts, socket disconnections, and truncated downloads.
2. **Contradiction with Plist Throttling**: The repository's launchd plists originally delayed photo backups by 5 seconds (`ThrottleInterval 15` vs `10`) specifically to avoid concurrent USB initialization.
3. **Resource Starvation**: Running two `exiftool`, `afcclient`, and `shasum` pipelines simultaneously thrashes the external drive I/O and USB controller.

#### Recommended Fix
Execute backups sequentially rather than concurrently:
```bash
# Sequential execution ensures maximum USB stability
bash "$SCRIPT_DIR/backup_videos_v3.sh"
video_rc=$?
bash "$SCRIPT_DIR/backup_photos_v3.sh"
photo_rc=$?
```

---

### REL-03: Performance Degradation: $O(N^2)$ Subshell Spawning during Sequential Renaming
* **Severity**: **High (Extreme Sluggishness / System Freeze)**
* **Component**: Archiving loop in `backup_videos_v3.sh` (Lines 485–491) and `backup_photos_v3.sh` (Lines 618–624)

#### Mechanism
For **every single file** transferred, the script searches the target date directory to compute the next sequential integer:
```bash
local max_seq=0 _f _bn _num
while IFS= read -r _f; do
    _bn=$(basename "$_f")
    _num=$(echo "$_bn" | grep -oE '^[0-9]+' | head -1)
    _num=${_num:-0}
    (( 10#$_num > max_seq )) && max_seq=$((10#$_num)) || true
done < <(find "$target_dir" -maxdepth 1 -type f 2>/dev/null || true)
```

#### Why This Is Unreliable
* If a user took 500 photos in a single day:
  * File #1 scans 0 existing files.
  * File #2 scans 1 existing file.
  * ...
  * File #500 scans 499 existing files.
* Total files inspected: $\frac{500 \times 499}{2} \approx 125,000$ iterations.
* In each iteration, `basename`, `echo`, `grep`, and `head` are spawned as subshell processes. That results in **over 500,000 process forks** in Bash on macOS for just one day's photos.
* On macOS, fork overhead is non-trivial; backing up large camera rolls will cause the script to crawl and consume 100% CPU.

#### Recommended Fix
Track `max_seq` in-memory using a Bash associative array indexed by directory path:
```bash
declare -A MAX_SEQS
if [[ -z "${MAX_SEQS[$target_dir]:-}" ]]; then
    # Scan max sequence once per folder
    MAX_SEQS[$target_dir]=$(find "$target_dir" -maxdepth 1 -type f -name '[0-9]*' | \
        sed -E 's/.*\/0*([0-9]+)\..*/\1/' | sort -n | tail -1)
    MAX_SEQS[$target_dir]=${MAX_SEQS[$target_dir]:-0}
fi
(( MAX_SEQS[$target_dir]++ ))
seq="${MAX_SEQS[$target_dir]}"
```

---

### REL-04: Permanent Destruction of Live Photo Pairing
* **Severity**: **Medium (Data Integrity Degradation)**
* **Component**: File categorization and sequential renaming

#### Mechanism
On iOS, a Live Photo is saved as a pair:
* An image: `IMG_4523.HEIC`
* A short video: `IMG_4523.MOV`
Both share the exact same base filename (`IMG_4523`) and internal Apple asset identifier.

#### Why This Is Unreliable
1. `backup_videos_v3.sh` routes the `.MOV` file to `$BACKUP_ROOT/<Date>/001.mov`.
2. `backup_photos_v3.sh` routes the `.HEIC` file to `$PHOTO_BACKUP_ROOT/Photos/<Date>/005.heic`.
3. Because sequence counters differ between photo and video directories, the matching pairs receive completely different names and live in different directory roots.
4. Neither Apple Photos, Google Photos, nor any media player can re-associate the two components as a Live Photo.

#### Recommended Fix
Preserve the original filename stem (e.g. `2026-04-09_IMG_4523.heic` and `2026-04-09_IMG_4523.mov`) or store paired Live Photo clips alongside their corresponding still images.

---

### REL-05: iCloud "Optimize iPhone Storage" Incompatibility
* **Severity**: **High (Incomplete Backups)**
* **Component**: iOS Storage Configuration Interaction

#### Mechanism
If "Optimize iPhone Storage" is active on the iPhone, original high-resolution media files are stored on iCloud servers, leaving only low-resolution thumbnails locally on the device flash memory.

#### Why This Is Unreliable
* AFC (Apple File Conduit) operates strictly on the local iOS filesystem (`/DCIM`).
* AFC **cannot** issue an on-demand download request to iCloud over the USB interface.
* Consequently, any offloaded media is either completely absent from `/DCIM` or downloaded as a miniature cached thumbnail (< 1KB), which the script flags as corrupt:
  ```
  fail_reasons+=("File corrupted (${fsize}B < 1KB)")
  ```
* Users may falsely assume their full camera roll is safely backed up when in reality cloud-stored media has been skipped.

---

### REL-06: Unhandled Apple ProRAW (`.DNG`) and Edit Sidecars (`.AAE`)
* **Severity**: **Medium (Missing Data)**
* **Component**: `config.sh` (`PHOTO_EXTENSIONS`)

#### Mechanism
* `PHOTO_EXTENSIONS` is configured as:
  ```bash
  PHOTO_EXTENSIONS="JPG JPEG HEIC PNG GIF"
  ```
* Pro models (iPhone 12 Pro through iPhone 16 Pro) capture raw photos in Apple ProRAW format with the `.DNG` extension.
* ProRAW `.DNG` files are **completely ignored** by `is_photo()` and will never be backed up.
* Furthermore, iOS edits (crops, filters, rotation) are saved as `.AAE` sidecar files; these are also ignored, meaning all photo edits are discarded.

#### Recommended Fix
Add `DNG` to `PHOTO_EXTENSIONS` in `config.sh`, and implement sidecar syncing for `.AAE` files.

---

### REL-07: Multi-Device Lockout (`-u <UDID>` Missing)
* **Severity**: **Medium (Operational Failure)**
* **Component**: `config.sh` tool invocation

#### Mechanism
When multiple Apple devices are connected to the Mac simultaneously (e.g., an iPhone and an iPad, or an iPhone and an Apple Watch on a charging puck):
1. `idevice_id -l` returns multiple lines.
2. `devices()` in `iphone_backup_monitor.sh` condenses them into a space-separated string (`UDID1 UDID2`).
3. Later calls to `idevicepair validate` and `afcclient list /DCIM` are invoked without the `-u <UDID>` flag.
4. `libimobiledevice` CLI tools abort when multiple devices are detected if `-u` is not specified.

#### Recommended Fix
Pass the specific UDID being processed into all tool calls:
```bash
"$AFCCLIENT" -u "$UDID" list /DCIM
```

---

### REL-08: PID Recycling Deadlock in Lock Management
* **Severity**: **Low to Medium (Daemon Stagnation)**
* **Component**: `LOCKDIR` handling in worker scripts

#### Mechanism
```bash
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    _lock_pid=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "")
    if [[ -n "$_lock_pid" ]] && kill -0 "$_lock_pid" 2>/dev/null; then
        echo "[INFO] Video backup already running (PID $_lock_pid), exiting."
        exit 0
    fi
...
```
If the Mac crashes or loses power during a backup, the PID recorded in `/tmp/.../pid` remains on disk. If a new, completely unrelated process later starts and receives that same recycled PID, `kill -0 "$_lock_pid"` returns exit code 0.
The backup script will falsely assume an existing backup process is alive, permanently aborting future backup attempts until that unrelated process terminates.

---

## 3. Reliability Comparison Matrix

| Scenario | Anticipated Behavior | Actual Codebase Behavior | Severity |
| :--- | :--- | :--- | :--- |
| **Two iPhones Backed Up on Same Mac** | Both backed up independently | Photos with matching size & path on 2nd phone are permanently skipped | **Critical** |
| **Live Photo Capture** | Photo and video remain linked | Video and photo split into separate trees and assigned unrelated numbers | **High** |
| **Apple ProRAW (.DNG)** | Backed up to external drive | Completely ignored; never backed up | **High** |
| **iCloud Optimized Photos** | Full photos downloaded | Skipped or rejected as corrupt (< 1KB thumbnail) | **High** |
| **1,000 Photos in Single Day** | Fast sequential transfer | Extreme slowdown due to $O(N^2)$ process forks | **Medium** |
| **Multiple Apple Devices Plugged In** | Backs up the primary phone | Fails with "multiple devices found" error | **Medium** |
| **Abrupt Power Loss / Reboot** | Auto-cleans lock and resumes | May freeze if recycled PID matches lock PID | **Low** |

