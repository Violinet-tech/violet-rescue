# Tests a USB stick for real: full (slow) format, then writes about 1 GB and reads it back.
# Run as administrator. The stick is ERASED. Result is printed and logged to
# %USERPROFILE%\test-stick.log
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test-stick.ps1 [-DiskName 'Verbatim STORE N GO']
#
# PASS means the stick can hold the rescue image. FAIL means use another stick.
param([string]$DiskName = 'Verbatim STORE N GO')
$ErrorActionPreference = 'Stop'
try { Start-Transcript -Path (Join-Path $env:USERPROFILE 'test-stick.log') -Force | Out-Null } catch { }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this in an administrator window.' }

$disks = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.FriendlyName -eq $DiskName })
if ($disks.Count -ne 1) { throw "Expected exactly one USB disk named '$DiskName', found $($disks.Count). Nothing was changed." }
$n = $disks[0].Number
if ($disks[0].Size -gt 64GB) { throw 'That disk is larger than 64 GB. Not touching it.' }

Write-Host "Step 1 of 4: erasing disk $n ($DiskName)"
Clear-Disk -Number $n -RemoveData -RemoveOEM -Confirm:$false
$d2 = $null
for ($i = 0; $i -lt 30 -and -not $d2; $i++) { Start-Sleep -Seconds 1; Update-HostStorageCache; $d2 = Get-Disk -Number $n -ErrorAction SilentlyContinue }
if (-not $d2) { throw 'Disk did not come back after clearing. Unplug it, plug it in again and re-run.' }
if ($d2.PartitionStyle -eq 'RAW') { Initialize-Disk -Number $n -PartitionStyle MBR }
$part = New-Partition -DiskNumber $n -UseMaximumSize -IsActive -AssignDriveLetter
Write-Host 'Step 2 of 4: quick format...'
Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel WINPE -Confirm:$false | Out-Null
$drive = "$($part.DriveLetter):"

$errBefore = @(Get-WinEvent -FilterHashtable @{LogName = 'System'; Id = 51; StartTime = (Get-Date).AddMinutes(-60)} -ErrorAction SilentlyContinue).Count
$test = Join-Path $drive 'testfile.bin'
$buf = New-Object byte[] (1MB)
(New-Object Random 42).NextBytes($buf)
Write-Host 'Step 3 of 4: writing 1000 MB...'
$fs = [IO.File]::Create($test)
for ($i = 0; $i -lt 1000; $i++) { $fs.Write($buf, 0, $buf.Length) }
$fs.Flush(); $fs.Dispose()
Write-Host 'Step 4 of 4: reading it back...'
$sha = [Security.Cryptography.SHA256]::Create()
$in = [IO.File]::OpenRead($test)
$h = [BitConverter]::ToString($sha.ComputeHash($in)); $in.Dispose()
$exp = New-Object IO.MemoryStream
for ($i = 0; $i -lt 1000; $i++) { $exp.Write($buf, 0, $buf.Length) }
$hExp = [BitConverter]::ToString($sha.ComputeHash($exp.ToArray()))
Remove-Item $test -Force
$errAfter = @(Get-WinEvent -FilterHashtable @{LogName = 'System'; Id = 51; StartTime = (Get-Date).AddMinutes(-60)} -ErrorAction SilentlyContinue).Count
$newErrs = $errAfter - $errBefore
if ($h -eq $hExp -and $newErrs -le 0) { Write-Host "PASS: $drive wrote and read back 1000 MB cleanly, no new disk errors." }
else { Write-Host "FAIL: read-back match = $($h -eq $hExp), new disk errors = $newErrs. Use another stick." }
Stop-Transcript | Out-Null
