# Copies the built Violet Rescue image to the USB stick found by name and checks every file.
# Used by fix-stick.cmd. Does not erase the stick; it only adds or replaces files.
# A file that fails to copy or verify is tried again up to 8 times.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File copy-to-stick.ps1 [-DiskName 'SanDisk']
param([Parameter(ValueFromRemainingArguments = $true)]$Ignored)
$DiskName = 'SanDisk'   # fixed on purpose: pasted text after the command can no longer change the target
$ErrorActionPreference = 'Stop'
try { Start-Transcript -Path (Join-Path $env:USERPROFILE 'copy-to-stick.log') -Force | Out-Null } catch { }

$work = Join-Path $env:TEMP 'violet-rescue-build\media'
if (-not (Test-Path (Join-Path $work 'sources\boot.wim'))) { throw "No built image in $work." }

$disks = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.FriendlyName -match $DiskName })
if ($disks.Count -ne 1) { throw "Expected exactly one USB disk matching '$DiskName', found $($disks.Count). Nothing was written." }
if ($disks[0].Size -gt 64GB) { throw 'That disk is larger than 64 GB. Not touching it.' }
$part = Get-Partition -DiskNumber $disks[0].Number | Where-Object DriveLetter | Select-Object -First 1
if (-not $part) { throw 'The stick has no drive letter. Unplug it, plug it in again and run this again.' }
$drive = "$($part.DriveLetter):"
Write-Host "Writing to $drive ($($disks[0].FriendlyName))"

$files = @(Get-ChildItem $work -Recurse -File)
$failed = @()
$n = 0
foreach ($f in $files) {
  $n++
  $rel = $f.FullName.Substring($work.Length).TrimStart('\')
  $dst = Join-Path "$drive\" $rel
  $ok = $false
  for ($try = 1; $try -le 8 -and -not $ok; $try++) {
    try {
      $match = $false
      if (Test-Path $dst) {
        $item = Get-Item $dst
        if ($item.Length -eq $f.Length) { $match = ((Get-FileHash $f.FullName -Algorithm SHA256).Hash -eq (Get-FileHash $dst -Algorithm SHA256).Hash) }
      }
      if ($match) { $ok = $true; break }
      New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
      Copy-Item $f.FullName $dst -Force
      Start-Sleep -Milliseconds 200
    } catch { Start-Sleep -Seconds 6 }
  }
  if (-not $ok) { $failed += $rel; Write-Host "FAILED $rel" }
  if ($n % 20 -eq 0 -or $f.Length -gt 100MB) { Write-Host "  $n of $($files.Count) files done" }
}
if ($failed.Count -eq 0) { Write-Host "PASS: all $($files.Count) files are on $drive and match." }
else { Write-Host "FAIL: $($failed.Count) file(s) did not copy. See above." }
try { Stop-Transcript | Out-Null } catch { }
