# iPhone Auto Backup Documentation Suite
**Author**: Vaibhav Bhootna  
**Repository**: [https://github.com/vbv611/iphone-auto-backup](https://github.com/vbv611/iphone-auto-backup)

Welcome to the technical documentation for `iphone-auto-backup`.

## Documentation Index

1. **[Architecture & Technical Design](ARCHITECTURE.md)**
   * End-to-end system topology and pipeline sequence.
   * Component breakdown (`config.sh`, `iphone_backup_monitor.sh`, `backup_videos_v3.sh`, `backup_photos_v3.sh`, `import_image_capture.sh`, `rebuild_hash_index.sh`).
   * IPC mechanisms, daemon lifecycle, and filesystem state storage.

2. **[Security Audit & Vulnerability Assessment](SECURITY_AUDIT.md)**
   * Threat modeling for macOS workstations.
   * Full vulnerability audit (Insecure `/tmp` staging, AppleScript command injection vectors, TOCTOU locks, pipe-delimiter bugs).
   * Defensive remediations and hardening guidance.

3. **[Reliability & Edge-Case Engineering Analysis](RELIABILITY_ANALYSIS.md)**
   * Critical reliability findings: Multi-device collision risks, Live Photo pairing severance, iCloud offload behavior, Apple ProRAW (`.DNG`) omissions.
   * Algorithmic bottleneck analysis: $O(N^2)$ process spawning during sequential renaming.
   * Comparative reliability matrix and recommended architectural fixes.

4. **[Operations, Maintenance & Troubleshooting Manual](OPERATIONS_GUIDE.md)**
   * Prerequisites and dependency installation (`libimobiledevice`, `exiftool`).
   * Setup instructions and configuration options.
   * `launchd` service administration and daemon control.
   * Migrating and importing media from Apple Image Capture dumps (`import_image_capture.sh`).
   * Step-by-step diagnostic runbook for device trust errors, stale locks, and index corruption.

