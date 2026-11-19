# Erases ONE disk and sets it up fresh (GPT, one NTFS partition). Run in Windows from an
# administrator PowerShell:
#   powershell -ExecutionPolicy Bypass -File format-disk.ps1
# It lists every disk, you type the disk NUMBER, it shows what is on it, and it only goes ahead if
# you type ERASE and the number again. It refuses the disk Windows runs from, any disk holding C:,
# and (unless -AllowUsb) USB drives. Everything on the chosen disk is lost. Nothing can undo it.
param([string]$Label = 'Data', [switch]$AllowUsb)

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host 'Run this from an ADMINISTRATOR PowerShell (right-click PowerShell, Run as administrator).'
  exit 1
}

Write-Host ''
Write-Host 'Disks in this PC:'
Get-Disk | Sort-Object Number | ForEach-Object {
  $letters = (Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { "$($_.DriveLetter):" }) -join ' '
  '  Disk {0}  {1}  {2} GB  {3}  {4}  letters: {5}  boot={6} system={7}' -f $_.Number, $_.FriendlyName, [math]::Round($_.Size / 1GB, 1), $_.BusType, $_.PartitionStyle, $letters, $_.IsBoot, $_.IsSystem
}
Write-Host ''
$n = Read-Host 'Type the NUMBER of the disk to ERASE (or press Enter to quit)'
if ($n -notmatch '^\d+$') { Write-Host 'Nothing erased.'; exit 0 }
$disk = Get-Disk -Number ([int]$n) -ErrorAction SilentlyContinue
if (-not $disk) { Write-Host "No disk $n. Nothing erased."; exit 1 }

$parts = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue)
if ($disk.IsBoot -or $disk.IsSystem) { Write-Host "Disk $n is the disk Windows runs from. Refused."; exit 1 }
if ($parts | Where-Object { $_.DriveLetter -eq 'C' }) { Write-Host "Disk $n holds C:. Refused."; exit 1 }
if ($disk.BusType -eq 'USB' -and -not $AllowUsb) { Write-Host "Disk $n is a USB drive. Refused. Add -AllowUsb if you really mean it."; exit 1 }

Write-Host ''
Write-Host "Disk $n : $($disk.FriendlyName), $([math]::Round($disk.Size / 1GB, 1)) GB, $($disk.BusType)"
foreach ($p in $parts) {
  $v = Get-Volume -Partition $p -ErrorAction SilentlyContinue
  '   partition {0}: {1} GB  type {2}  letter {3}  label ''{4}''  fs {5}' -f $p.PartitionNumber, [math]::Round($p.Size / 1GB, 1), $p.Type, $p.DriveLetter, $v.FileSystemLabel, $v.FileSystem
}
Write-Host ''
Write-Host "EVERYTHING on disk $n will be erased and cannot be recovered." -ForegroundColor Yellow
$a = Read-Host 'To go ahead type ERASE'
if ($a -cne 'ERASE') { Write-Host 'Nothing erased.'; exit 0 }
$b = Read-Host "Type the disk number again ($n)"
if ($b -ne "$n") { Write-Host 'Numbers did not match. Nothing erased.'; exit 0 }

Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM -Confirm:$false
Initialize-Disk -Number $disk.Number -PartitionStyle GPT
$np = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $np -FileSystem NTFS -NewFileSystemLabel $Label -Confirm:$false | Out-Null
Write-Host "Done. Disk $n is now one NTFS drive named '$Label' as $($np.DriveLetter):"
