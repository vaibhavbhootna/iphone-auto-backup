# Security Audit & Vulnerability Assessment
**Author**: Vaibhav Bhootna  
**Repository**: [https://github.com/vbv611/iphone-auto-backup](https://github.com/vbv611/iphone-auto-backup)

## 1. Executive Summary

A comprehensive source code security assessment was performed on the `iphone-auto-backup` repository. The codebase consists of Bash shell scripts executed with user privileges and scheduled via macOS `launchd`.

While the scripts avoid high-risk constructs such as `eval` and properly quote most filesystem operations, the audit identified **several security vulnerabilities and architectural design weaknesses**, ranging from **Information Disclosure** of personal media to **AppleScript injection** and **insecure temporary file handling** on multi-user systems.

### Summary of Findings

| ID | Vulnerability / Issue | Severity | CWE | Impact |
| :--- | :--- | :--- | :--- | :--- |
| **SEC-01** | Insecure World-Readable Staging Directory in `/tmp` | **High** | CWE-377, CWE-379, CWE-200 | Local multi-user leakage of private photos & videos; potential symlink attack |
| **SEC-02** | Unsanitized Variable Interpolation in `osascript` | **Medium** | CWE-78, CWE-88 | AppleScript escape / command execution if strings contain unescaped backslashes |
| **SEC-03** | Insecure Lock Handling & Symlink Attack in `backup_safe.sh` | **Medium** | CWE-377, CWE-59 | Arbitrary file creation/timestamp manipulation via predictable `/tmp` lock |
| **SEC-04** | Delimiter Collisions in Pipe-Delimited Path Parsing | **Low** | CWE-20 | Data corruption or skip when filenames contain pipe (`\|`) characters |
| **SEC-05** | Predictable Global IPC Triggers in Shared `/tmp` | **Low** | CWE-377 | Unprivileged local users can trigger or disrupt backup cycles |
| **SEC-06** | Unrestricted Default File Permissions (Umask Exposure) | **Low** | CWE-276 | Backup files and hash indexes inherit default user umask (often world-readable) |

---

## 2. In-Depth Vulnerability Analysis

---

### SEC-01: Insecure World-Readable Staging Directory in `/tmp`
* **Vulnerability Type**: Insecure Temporary File Creation & Information Disclosure
* **Severity**: **High**
* **CWE**: CWE-377 (Insecure Temporary File), CWE-379 (Creation of Temporary File in Directory with Incorrect Permissions), CWE-200 (Exposure of Sensitive Information)
* **Affected Files**:
  * `backup_videos_v3.sh` (Lines 35, 189)
  * `backup_photos_v3.sh` (Lines 25, 179)
  * `backup_safe.sh` (Lines 9, 41)

#### Description & Mechanics
In `backup_videos_v3.sh` and `backup_photos_v3.sh`, temporary staging directories are hardcoded in the shared system temporary directory `/tmp`:
```bash
TMP_DIR="/tmp/iphone_video_backup_v3_tmp"
...
touch_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    mkdir -p "$TMP_DIR"
    ...
}
```
On macOS, `/tmp` is a symlink to `/private/tmp`, which has standard POSIX permissions `drwxrwxrwt` (1777, world-writable with sticky bit).

When `mkdir -p "$TMP_DIR"` executes:
1. It creates the directory using the current shell's default `umask` (typically `022`).
2. The resulting directory mode is `drwxr-xr-x` (0755), making it **readable by every local user and process running on the Mac**.
3. Every private photograph and video downloaded from the user's unlocked iPhone is placed unencrypted into this public directory before being hashed and moved.
4. **Pre-creation Hijacking**: Any other local user or background process can pre-create `/tmp/iphone_video_backup_v3_tmp` with custom permissions or place symlinks inside it before the backup begins.

#### Remediation
1. Use `mktemp -d` with a restricted template, or enforce explicit permissions `0700` (`chmod 700`) immediately upon creation.
2. Store staging files inside the user's private directory (e.g. `~/Library/Caches/iphone-auto-backup/` or a `.tmp` folder on the destination external drive itself):
```bash
# Recommended fix
TMP_DIR="$(mktemp -d -t iphone_backup_tmp_XXXXXX)"
trap 'restore_sleep; rm -rf "$LOCKDIR" "$TMP_DIR"' EXIT
```

---

### SEC-02: Unsanitized Variable Interpolation in `osascript` (AppleScript Injection)
* **Vulnerability Type**: Improper Input Validation / Command Injection
* **Severity**: **Medium**
* **CWE**: CWE-78 (OS Command Injection), CWE-88 (Argument Injection)
* **Affected Files**:
  * `iphone_backup_monitor.sh` (Lines 15–21)
  * `backup_videos_v3.sh` (Lines 63–70)
  * `backup_photos_v3.sh` (Lines 53–60)

#### Description & Mechanics
The `notify()` function in all three scripts issues macOS user notifications via `osascript`:
```bash
notify() {
    local title="$1"; local msg="$2"
    command -v osascript >/dev/null 2>&1 || return 0
    local safe_title safe_msg
    safe_title=$(printf "%s" "$title" | sed 's/"/\\"/g')
    safe_msg=$(printf "%s" "$msg" | sed 's/"/\\"/g')
    osascript -e "display notification \"$safe_msg\" with title \"$safe_title\"" 2>/dev/null || true
}
```
The sanitization logic attempts to escape double quotes with `sed 's/"/\\"/g'`. However:
1. It does **not** escape backslashes (`\`).
2. If `msg` or `title` contains a trailing backslash (e.g. `foo\`), the result becomes `foo\"`, which escapes the quote inside AppleScript syntax, breaking the string literal.
3. If dynamic input (such as volume names, disk mount errors, or failure strings) contains special characters, an attacker who controls the mount name or directory structure can inject arbitrary AppleScript code executed within the context of the user session.

#### Remediation
Never interpolate variables into an inline `-e` AppleScript string. Instead, use AppleScript's native `run` handler and pass variables via positional arguments (`argv`):
```bash
# Secure implementation
notify() {
    local title="$1" msg="$2"
    command -v osascript >/dev/null 2>&1 || return 0
    osascript - "$title" "$msg" <<'APPLESCRIPT' 2>/dev/null || true
on run argv
    set theTitle to item 1 of argv
    set theMsg to item 2 of argv
    display notification theMsg with title theTitle
end run
APPLESCRIPT
}
```

---

### SEC-03: Insecure Lock Handling & Symlink Vulnerability in `backup_safe.sh`
* **Vulnerability Type**: Insecure Temporary File / Arbitrary File Manipulation
* **Severity**: **Medium**
* **CWE**: CWE-377 (Insecure Temporary File), CWE-59 (Improper Link Resolution Before File Access)
* **Affected File**: `backup_safe.sh` (Lines 24–27)

#### Description & Mechanics
`backup_safe.sh` uses a simple `touch` against a fixed `/tmp` filename:
```bash
LOCKFILE="/tmp/iphone_safe_backup.lock"
if [[ -f "$LOCKFILE" ]]; then echo "[INFO] Already running, exiting"; exit 0; fi
trap 'rm -f "$LOCKFILE"' EXIT
touch "$LOCKFILE"
```
1. `touch "$LOCKFILE"` follows symlinks. If a malicious local user creates `/tmp/iphone_safe_backup.lock` as a symlink pointing to another user file (e.g. `~/.zshrc`), running `backup_safe.sh` modifies the target file's access/modification timestamp.
2. A Time-of-Check to Time-of-Use (TOCTOU) race condition exists between `[[ -f "$LOCKFILE" ]]` and `touch "$LOCKFILE"`.
3. Unlike `backup_videos_v3.sh` and `backup_photos_v3.sh` (which use `mkdir` for atomic locking), `backup_safe.sh` retains this legacy vulnerability.

#### Remediation
Replace `touch` with an atomic directory lock (`mkdir`) or remove `backup_safe.sh` entirely in favor of the v3 scripts.

---

### SEC-04: Delimiter Collisions in Pipe-Delimited Path Parsing
* **Vulnerability Type**: Improper Input Handling
* **Severity**: **Low**
* **CWE**: CWE-20 (Improper Input Validation)
* **Affected Files**:
  * `backup_videos_v3.sh` (Lines 383, 403)
  * `backup_photos_v3.sh` (Lines 508, 528)

#### Description & Mechanics
Files discovered via `afcclient list` are stored in an array separated by a vertical bar (`|`):
```bash
iphone_videos+=("/DCIM/$dir/$f|$f")
...
IFS='|' read -r src_path fname <<< "$entry"
```
If an iPhone contains a photo or video filename with a pipe character (e.g. `vacation|beach.mov` or crafted filenames synced from third-party apps):
1. `IFS='|' read -r src_path fname` splits on the first pipe inside the filename.
2. `src_path` becomes truncated (e.g. `/DCIM/100APPLE/vacation`), and `fname` becomes corrupted.
3. This leads to download failures or unintended path resolution.

#### Remediation
Store the full source path and filename in separate indexed array elements, or use a null byte (`\0`) delimiter:
```bash
# Recommended fix using parallel arrays or null-delimited pairs
iphone_src_paths+=("/DCIM/$dir/$f")
iphone_fnames+=("$f")
```

---

### SEC-05: Predictable Global IPC Triggers in Shared `/tmp`
* **Vulnerability Type**: Insecure Temporary File / Denial of Service
* **Severity**: **Low**
* **CWE**: CWE-377
* **Affected Files**:
  * `iphone_backup_monitor.sh` (Lines 94, 126)
  * `backup_videos_v3.sh` (Line 78)
  * `backup_photos_v3.sh` (Line 68)

#### Description & Mechanics
The scripts communicate control events via static paths in `/tmp`:
* `TRIGGER_FILE="/tmp/iphone_backup_manual.trigger"`
* `pending_flag="/tmp/iphone_media_index.pending"`
* `STATUS_FILE="/tmp/iphone_backup_monitor.status"`

Any local unprivileged process can write or touch `/tmp/iphone_backup_manual.trigger` continuously, forcing `iphone_backup_monitor.sh` to trigger unneeded backup cycles, causing battery drain, USB bus contention, and excessive log growth.

#### Remediation
Relocate all IPC and trigger files to a user-private directory under `$TMPDIR` (macOS per-user temporary directory `/var/folders/...`) or `$HOME/.cache/iphone-backup/`.

---

### SEC-06: Unrestricted Default File Permissions (Umask Exposure)
* **Vulnerability Type**: Insecure Default Permissions
* **Severity**: **Low**
* **CWE**: CWE-276 (Incorrect Default Permissions)
* **Affected Files**:
  * `backup_videos_v3.sh`
  * `backup_photos_v3.sh`

#### Description & Mechanics
Neither worker script sets an explicit `umask`. When files are created in `$HOME` (`.iphone_video_backup_v3.hashes`, `.device_seen`, `.state`), or when target directories are created via `mkdir -p "$target_dir"`, they inherit the default user umask (`022`).
Consequently:
* The hash indexes and state logs are world-readable (`-rw-r--r--`).
* Destination photo and video archives on external drives formatted with POSIX permissions may also be world-readable.

#### Remediation
Enforce `umask 077` at the entry point of all scripts to guarantee that created files and directories are accessible exclusively by the invoking user.

---

## 3. Hardening Recommendations

1. **Enforce `umask 077`**: Add `umask 077` at line 2 of all executable scripts.
2. **Move Staging to Private Storage**: Replace `/tmp` staging directories with `mktemp -d -t iphone_backup_XXXXXX` and register cleanup traps.
3. **Adopt Secure AppleScript Invocation**: Pass arguments to `osascript` via `run argv` rather than string substitution.
4. **Deprecate or Remove `backup_safe.sh`**: The v1 safe backup script contains unpatched symlink risks and should not be distributed.
5. **UDID-Scoped Namespaces**: Namespace all state files, hash indexes, and cache directories by device UDID to eliminate multi-device cross-talk.

