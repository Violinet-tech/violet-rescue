# Writes the already built Violet Rescue image to a USB stick without MakeWinPEMedia.
# Run as administrator, after build-media.cmd has built the image (it leaves it in %TEMP%).
# The stick is ERASED. It is found by name and must be a USB disk under 64 GB.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File write-usb-manual.ps1 [-DiskName 'Verbatim STORE N GO']
#
# UEFI boot only: this copies the files but writes no legacy BIOS boot sector.
param([string]$DiskName = 'Verbatim STORE N GO')
$ErrorActionPreference = 'Stop'
try { Start-Transcript -Path (Join-Path $env:USERPROFILE 'write-usb-manual.log') -Force | Out-Null } catch { }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this in an administrator window.' }

$work = Join-Path $env:TEMP 'violet-rescue-build\media'
$wim = Join-Path $work 'sources\boot.wim'
if (-not (Test-Path $wim)) { throw "No built image in $work. Run build-media.cmd first." }

$disks = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.FriendlyName -eq $DiskName })
if ($disks.Count -ne 1) { throw "Expected exactly one USB disk named '$DiskName', found $($disks.Count). Nothing was changed." }
$disk = $disks[0]
if ($disk.Size -gt 64GB) { throw 'That disk is larger than 64 GB. Not touching it.' }

Write-Host ('Erasing disk {0} ({1}, {2} GB)' -f $disk.Number, $disk.FriendlyName, [math]::Round($disk.Size / 1GB, 1))
Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM -Confirm:$false
$n = $disk.Number
# The disk drops off the bus for a moment after it is cleared; wait for it to come back.
$d2 = $null
for ($i = 0; $i -lt 30 -and -not $d2; $i++) {
  Start-Sleep -Seconds 1
  Update-HostStorageCache
  $d2 = Get-Disk -Number $n -ErrorAction SilentlyContinue
}
if (-not $d2) { throw "Disk $n did not come back after it was cleared. Unplug the stick, plug it in again and run this again." }
if ($d2.PartitionStyle -eq 'RAW') { Initialize-Disk -Number $n -PartitionStyle MBR }
$part = New-Partition -DiskNumber $n -UseMaximumSize -IsActive -AssignDriveLetter
Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel WINPE -Confirm:$false | Out-Null
$drive = "$($part.DriveLetter):"

Write-Host "Copying the image to $drive (about 1 GB, a few minutes)..."
robocopy $work "$drive\" /E /R:2 /W:2 /NFL /NDL /NJH /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with code $LASTEXITCODE" }

$src = (Get-Item $wim).Length
$dst = (Get-Item "$drive\sources\boot.wim").Length
if ($src -ne $dst) { throw "boot.wim size differs after the copy ($src vs $dst)." }
Write-Host "Done. $drive holds Violet Rescue ($dst bytes in boot.wim). UEFI boot only."
