# Violet Rescue module: restore a damaged NTFS boot sector from its backup copy.
# For a Windows drive that shows as RAW / "file system Unknown" while its data is still there.
# NTFS keeps a second copy of the boot sector at the very end of the volume. This lists every big
# partition with what its first sector holds, looks for a valid copy in its last sectors, and only
# repairs a partition that Windows itself reports as having no file system.
#
#   rescue.ps1 ntfs-bootsector [-Option <disk number>] [-Yes]
#
# With more than one candidate it prefers the disk that also holds an EFI System partition (the boot disk).
# -Option 0 forces disk 0. NOT YET RUN ON A REAL RAW DRIVE: Windows may refuse the raw write, in which
# case it stops and changes nothing.
# ASCII only on purpose (PowerShell 5.1 reads a file without a BOM as ANSI).

function Read-RawSector([int]$disk, [int64]$offset, [int]$ss) {
  $fs = $null
  try {
    $fs = New-Object System.IO.FileStream("\\.\PhysicalDrive$disk", [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite, 1)
    [void]$fs.Seek($offset, [System.IO.SeekOrigin]::Begin)
    $b = New-Object byte[] $ss
    $n = $fs.Read($b, 0, $ss)
    if ($n -ne $ss) { return $null }
    return , $b
  } catch { return $null } finally { if ($fs) { $fs.Dispose() } }
}

function Test-NtfsSector($b) {
  if (-not $b -or $b.Length -lt 512) { return $false }
  $sig = [System.Text.Encoding]::ASCII.GetString($b, 3, 8)
  return ($sig -eq 'NTFS    ' -and $b[510] -eq 0x55 -and $b[511] -eq 0xAA)
}

function Show-SectorInfo($b) {
  if (-not $b) { return 'unreadable' }
  $hex = ($b[0..15] | ForEach-Object { $_.ToString('X2') }) -join ' '
  $id  = ([System.Text.Encoding]::ASCII.GetString($b, 3, 8)) -replace '[^\x20-\x7E]', '.'
  $a54 = ([System.Text.Encoding]::ASCII.GetString($b, 54, 3)) -replace '[^\x20-\x7E]', '.'
  $a82 = ([System.Text.Encoding]::ASCII.GetString($b, 82, 3)) -replace '[^\x20-\x7E]', '.'
  return ("bytes0-15 [{0}] id='{1}' at54='{2}' at82='{3}' end55AA={4}" -f $hex, $id, $a54, $a82, (($b[510] -eq 0x55) -and ($b[511] -eq 0xAA)))
}

function Get-PartitionFsName($p) {
  # The file system Windows itself reports for this partition. Empty means RAW / unreadable.
  try {
    $q = "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($p.DeviceID)'} WHERE AssocClass=Win32_LogicalDiskToPartition"
    $ld = @(Get-CimInstance -Query $q -ErrorAction Stop)
    if ($ld.Count -eq 0) { return '(no drive letter)' }
    $fsn = "$($ld[0].FileSystem)"
    if ($fsn) { return $fsn } else { return '' }
  } catch { return '(unknown)' }
}

function Cmd-NtfsBootSector {
  Head 'Look for an unreadable Windows (NTFS) drive'
  $drives = @{}
  foreach ($d in (Get-CimInstance Win32_DiskDrive)) { $drives[[int]$d.Index] = $d }
  $all   = @(Get-CimInstance Win32_DiskPartition)
  $espOn = @($all | Where-Object { $_.Type -match 'System' } | ForEach-Object { [int]$_.DiskIndex })
  $found = @()
  foreach ($p in ($all | Where-Object { $_.Size -gt 20GB })) {
    $di = [int]$p.DiskIndex
    $ss = 512
    if ($drives.ContainsKey($di) -and $drives[$di].BytesPerSector) { $ss = [int]$drives[$di].BytesPerSector }
    $start = [int64]$p.StartingOffset
    $size  = [int64]$p.Size
    $gb    = [math]::Round($size / 1GB, 1)
    $first = Read-RawSector $di $start $ss
    $fsName = Get-PartitionFsName $p
    Say ("Disk {0}, {1} GB, Windows says file system: '{2}'" -f $di, $gb, $fsName)
    Say ("   first sector: " + (Show-SectorInfo $first))
    if (-not $first) { Say '   could not read the first sector. Skipped.'; continue }
    if (Test-NtfsSector $first) { Say '   NTFS boot sector is fine.'; continue }
    $copy = $null
    for ($i = 1; $i -le 16; $i++) {
      $b = Read-RawSector $di ($start + $size - ($i * $ss)) $ss
      if (Test-NtfsSector $b) { $copy = $b; break }
    }
    if (-not $copy) { Say '   no NTFS backup boot sector near the end. Not repairable here.'; continue }
    Say '   a valid NTFS backup boot sector exists near the end of this partition.'
    if ($fsName -ne '' -and $fsName -ne '(no drive letter)' -and $fsName -ne '(unknown)') {
      Say "   but Windows reads this as a working '$fsName' drive. Left alone."
      continue
    }
    $found += [pscustomobject]@{ Disk = $di; Start = $start; SS = $ss; Gb = $gb; Copy = $copy; Old = $first }
  }
  if ($found.Count -eq 0) { Say 'Nothing to repair. No change made.'; return }
  if ($Option -match '^\d+$') { $found = @($found | Where-Object { $_.Disk -eq [int]$Option }) }
  elseif ($found.Count -gt 1) {
    $boot = @($found | Where-Object { $espOn -contains $_.Disk })
    if ($boot.Count -eq 1) { Say "More than one candidate. Choosing disk $($boot[0].Disk), the one with the EFI System partition."; $found = $boot }
  }
  if ($found.Count -ne 1) { Say "Found $($found.Count) candidates. Nothing was changed. Send a photo of this log."; return }
  $c = $found[0]
  if (-not (Confirm-Action ("Restore the NTFS boot sector of the {0} GB partition on disk {1} from its backup copy?" -f $c.Gb, $c.Disk))) { Say 'Cancelled.'; return }
  # Keep the old first sector. Prefer a drive that survives the restart; fall back to the stick's own folder.
  $keepName = "ntfs-bootsector-disk{0}-{1}.bin" -f $c.Disk, (Get-Date -Format 'yyyyMMdd-HHmmss')
  $saved = $false
  foreach ($dir in @($(if ($Target) { "$($Target.TrimEnd(':', '\')):\" }), $Root)) {
    if (-not $dir) { continue }
    try { [System.IO.File]::WriteAllBytes((Join-Path $dir $keepName), $c.Old); Say "Saved the old sector to $(Join-Path $dir $keepName)"; $saved = $true; break } catch {}
  }
  if (-not $saved) { Say 'Could not save the old sector anywhere. Stopping, nothing was written.'; return }
  $fs = $null
  try {
    $fs = New-Object System.IO.FileStream("\\.\PhysicalDrive$($c.Disk)", [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite, 1)
    [void]$fs.Seek($c.Start, [System.IO.SeekOrigin]::Begin)
    $fs.Write($c.Copy, 0, $c.SS)
    $fs.Flush()
  } catch {
    Say "Windows refused the write: $($_.Exception.Message)"
    Say 'Nothing was changed. The volume is probably locked by Windows. Use TestDisk (Boot, Backup BS) from a working PC instead.'
    return
  } finally { if ($fs) { $fs.Dispose() } }
  $after = Read-RawSector $c.Disk $c.Start $c.SS
  if ($after -and (Test-NtfsSector $after) -and ([Convert]::ToBase64String($after) -eq [Convert]::ToBase64String($c.Copy))) {
    Say 'Done. The NTFS boot sector was restored and reads back correctly.'
    Say 'Next: run Check disk (read only), then copy your files off with "Copy my files", then "Fix the boot files".'
  } else {
    Say 'The write finished but the read back does not match. Stop and send a photo of this log.'
  }
}
