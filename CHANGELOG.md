# Changelog

## Unreleased (2026-11-13)

**Found on a real PC:** a PC that "would not start" and whose drive showed as unreadable was BitLocker-locked. Windows 11
had turned on device encryption by itself, and plugging in another drive made it ask for the recovery key. From a rescue
stick the locked drive looks like a broken one (file system Unknown, "not ready", no Windows found), so every repair
tried first could not work. Unlocking the drive with its recovery key and then running Fix the boot files started Windows.

### Added
- **BitLocker page** in the glass window: Check BitLocker (lists drives with their state), a hidden recovery-key box,
  Unlock the selected drive, Unlock with `unlock-keys.txt`, Remove BitLocker from the selected drive.
- CLI commands `bitlocker-check`, `bitlocker-unlock`, `bitlocker-off`, `list-disks`, `format-disk`
  (`cli/modules/bitlocker.ps1`), also listed in the classic window.
- `ntfs-bootsector`: restores a damaged NTFS boot sector from the backup copy at the end of the volume
  (`cli/modules/ntfsbs.ps1`). Prints what each big partition holds, and only touches a partition Windows reports as unreadable.
- `tools/decrypt-drives.ps1` and `tools/format-disk.ps1` for use inside Windows. `tools/` ships in the boot image.
- `build/unlock-bitlocker.cmd`: a command-prompt unlock script that reads keys from `unlock-keys.txt`.

### Changed
- `backup` now creates the `VioletRescueBackup` folder first. Before, robocopy could not open its log file, copied nothing
  and exited with code 16.
- Tabs: Fix it, Restore points, Repair tools, Drives, BitLocker, Log (keys 1 to 6).
- `unlock-keys.txt` is ignored by git. Recovery keys must never be committed.

### Not proven yet
- The BitLocker page, `bitlocker-off`, `ntfs-bootsector`, `format-disk` and the tools scripts have not been run inside WinRE.
  The Rust window with the BitLocker page has not been compiled at the time of writing.
- Fix Everything has not been run end to end.

## 0.1.0 (2026-11-11)
- First public release: glass window (Rust), classic window, CLI backend, boot-image build.
