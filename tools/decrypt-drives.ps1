# Turns BitLocker off (decrypts) for the drives you name, default C: and D:. Run once, in Windows,
# from an administrator PowerShell:
#   powershell -ExecutionPolicy Bypass -File decrypt-drives.ps1
#   powershell -ExecutionPolicy Bypass -File decrypt-drives.ps1 -Drives C,D,E
# Decrypting takes hours on a big drive and the PC works normally meanwhile. It is safe to restart.
# A locked drive cannot be decrypted until it is unlocked with its recovery key (the script says so).
param([string[]]$Drives = @('C', 'D'))

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host 'Run this from an ADMINISTRATOR PowerShell (right-click PowerShell, Run as administrator).'
  exit 1
}

foreach ($d in $Drives) {
  $l = "$d".Trim().TrimEnd(':').ToUpper()
  Write-Host ''
  Write-Host "=== $($l): ==="
  if (-not (Test-Path "$($l):\")) { Write-Host "  $($l): is not there right now. Skipped."; continue }
  $st = (& manage-bde.exe -status "$($l):" 2>&1) -join "`n"
  if ($st -match 'Fully Decrypted' -or $st -match 'Conversion Status:\s+Fully Decrypted') { Write-Host '  Already decrypted. Nothing to do.'; continue }
  if ($st -match 'Lock Status:\s+Locked') {
    Write-Host '  This drive is LOCKED. Unlock it first with its recovery key, then run this again:'
    Write-Host "  manage-bde -unlock $($l): -RecoveryPassword <your 48 digit key>"
    continue
  }
  Write-Host '  Starting decryption. Your files stay in place.'
  & manage-bde.exe -off "$($l):"
}

Write-Host ''
Write-Host 'Check progress any time with:  manage-bde -status'
Write-Host 'A drive is done when it says "Fully Decrypted" and Percentage Encrypted 0.0%.'
