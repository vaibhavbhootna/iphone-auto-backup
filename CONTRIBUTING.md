# Contributing to iPhone Auto Backup

Thanks for your interest in contributing! This is a small, focused tool, so the contribution process is lightweight.

## Ways to contribute

- **Bug reports** — open an issue with the log output and your macOS/iOS version
- **Feature ideas** — open an issue with the `enhancement` label
- **Code improvements** — submit a PR
- **Documentation** — fix typos, improve clarity, add examples
- **Compatibility** — test on Intel Macs, different iOS versions, and report results

## Before you submit a PR

1. Test your change on a real iPhone backup (not just dry-run)
2. Make sure existing functionality still works:
   ```bash
   bash backup_videos_v3.sh
   bash backup_photos_v3.sh
   ```
3. Keep changes focused — one feature/fix per PR

## Code style

- Pure bash, no external dependencies beyond `libimobiledevice` and `exiftool`
- Clear English comments and docstrings
- Functions should be self-contained and readable
- Test edge cases: empty DCIM, untrusted device, disconnected mid-backup

## Development setup

```bash
git clone https://github.com/vbv611/iphone-auto-backup.git
cd iphone-auto-backup
nano config.sh   # required: replace YourExternalDrive before install
bash install.sh  # Homebrew deps + launchd (macOS)
```

Before opening a PR:

```bash
bash -n *.sh
shellcheck --severity=warning --format=gcc *.sh
```

Linux CI cannot exercise USB / launchd / libimobiledevice. Prefer ShellCheck plus a real-Mac smoke test when you change backup behavior.

## Reporting bugs

Include in your issue:
- macOS version (`sw_vers`)
- iOS version
- Output of `cat /tmp/iphone_backup_monitor.status`
- Output of `cat /tmp/iphone_backup_stdout.log` or `cat /tmp/iphone_photo_backup_stdout.log`
- What you expected vs what happened

## License

By contributing, you agree that your contributions will be licensed under the MIT license.
