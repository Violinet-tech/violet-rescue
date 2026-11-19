# Violet Rescue module: BitLocker check / unlock / remove, plus disk list and disk erase.
# Called by the BitLocker page of the window and by the classic window. Works in the rescue image
# (it carries manage-bde) and in full Windows as administrator.
#
#   rescue.ps1 bitlocker-check  [-Option C]          lists drives; prints "BL|C|state" lines for the window
#   rescue.ps1 bitlocker-unlock -Option "D|123456-...-888888"   unlock one drive with a recovery key
#   rescue.ps1 bitlocker-unlock -Option file          try every key in unlock-keys.txt on each locked drive
#   rescue.ps1 bitlocker-off    -Option D             turn encryption off for an unlocked drive
#   rescue.ps1 list-disks                             disk numbers, models, sizes, letters
#   rescue.ps1 format-disk      -Option 3             ERASE disk 3 and make one NTFS drive
#
# A recovery key is never printed or logged. ASCII only on purpose (PowerShell 5.1 reads a file without
# a BOM as ANSI).

$script:KeyPattern = '^\d{6}(-\d{6}){7}$'

function Get-BlInfo([string]$l) {
  $t = (& manage-bde.exe -status "$($l):" 2>&1) -join "`n"
  if ($t -notmatch 'Conversion Status|Lock Status|Protection Status') { return $null }
  $g = { param($re) if ($t -match $re) { $Matches[1].Trim() } else { '' } }
  [pscustomobject]@{
    Letter = $l
    Conv   = (& $g 'Conversion Status:\s+(.+)')
    Lock   = (& $g 'Lock Status:\s+(.+)')
    Prot   = (& $g 'Protection Status:\s+(.+)')
    Size   = (& $g 'Size:\s+(.+)')
  }
}

function Test-BlLocked($info) { return ($info -and $info.Lock -match '^Locked') }

function Cmd-BitlockerCheck {
  Head 'BitLocker check'
  $letters = if ($Option -match '^[A-Za-z]$') { @($Option.ToUpper()) } else { [char[]](67..90) | Where-Object { $_ -ne 'X' } | ForEach-Object { "$_" } }
  $any = $false
  foreach ($l in $letters) {
    $i = Get-BlInfo $l
    if (-not $i) { continue }
    $any = $true
    $parts = @()
    if ($i.Lock) { $parts += $i.Lock }
    if ($i.Conv) { $parts += $i.Conv }
    if ($i.Prot) { $parts += "protection $($i.Prot)" }
    if ($i.Size) { $parts += $i.Size }
    $state = $parts -join ', '
    Say ("  {0}:  {1}" -f $l, $state)
    Say ("BL|{0}|{1}" -f $l, ($state -replace '\|', '/'))
  }
  if (-not $any) { Say 'No drive answered. Plug the drive in, then press Check BitLocker again.' }
  Say 'Locked = needs its 48-digit recovery key (account.microsoft.com/devices/recoverykey).'
}

function Get-KeysFromFile {
  $keys = @()
  foreach ($c in [char[]](67..90)) {
    $f = "$($c):\unlock-keys.txt"
    if (Test-Path $f) {
      Say "  keys file found on $($c):"
      foreach ($m in (Select-String -Path $f -Pattern '\d{6}(-\d{6}){7}' -AllMatches -ErrorAction SilentlyContinue)) {
        foreach ($x in $m.Matches) { $keys += $x.Value }
      }
    }
  }
  return @($keys | Select-Object -Unique)
}

function Unlock-Drive([string]$l, [string]$key) {
  & manage-bde.exe -unlock "$($l):" -RecoveryPassword $key 2>&1 | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function Cmd-BitlockerUnlock {
  Head 'BitLocker unlock'
  if ($Option -eq 'file') {
    $keys = Get-KeysFromFile
    if ($keys.Count -eq 0) { Say 'No unlock-keys.txt with 48-digit keys was found on any drive.'; return }
    Say "  $($keys.Count) key(s) read. They are not shown."
    $tried = $false
    foreach ($c in [char[]](67..90)) {
      $l = "$c"
      if ($l -eq 'X') { continue }
      $i = Get-BlInfo $l
      if (-not (Test-BlLocked $i)) { continue }
      $tried = $true
      $ok = $false
      foreach ($k in $keys) { if (Unlock-Drive $l $k) { $ok = $true; break } }
      if ($ok) { Say "  $($l): UNLOCKED" } else { Say "  $($l): none of the keys fit this drive." }
    }
    if (-not $tried) { Say 'No locked drive was found.' }
    Say 'Delete unlock-keys.txt from the stick when you are done. The unlock lasts until the next restart.'
    return
  }
  $p = "$Option".Split('|', 2)
  if ($p.Count -ne 2 -or $p[0] -notmatch '^[A-Za-z]$') { Say 'Pick a drive and type the key first.'; return }
  $l = $p[0].ToUpper()
  $key = $p[1].Trim()
  if ($key -notmatch $script:KeyPattern) { Say 'That is not a 48-digit recovery key (8 groups of 6 digits).'; return }
  $i = Get-BlInfo $l
  if (-not $i) { Say "$($l): did not answer. Press Check BitLocker and pick a listed drive."; return }
  if (-not (Test-BlLocked $i)) { Say "$($l): is not locked. Nothing to do."; return }
  if (Unlock-Drive $l $key) {
    Say "$($l): UNLOCKED. It stays unlocked until the next restart."
    Say 'Press Refresh drives on the Drives page. Windows should be found now.'
  } else {
    Say "$($l): that key did not unlock it. Check the Key ID against your Microsoft account and try the other key."
  }
}

function Cmd-BitlockerOff {
  Head 'Remove BitLocker'
  if ($Option -notmatch '^[A-Za-z]$') { Say 'Pick a drive first.'; return }
  $l = $Option.ToUpper()
  $i = Get-BlInfo $l
  if (-not $i) { Say "$($l): did not answer."; return }
  if (Test-BlLocked $i) { Say "$($l): is locked. Unlock it first, then remove BitLocker."; return }
  if ($i.Conv -match 'Fully Decrypted') { Say "$($l): is already decrypted."; return }
  Say "Turning encryption off for $($l): ..."
  & manage-bde.exe -off "$($l):"
  Say 'Decryption runs in the background and can take hours. Your files stay in place.'
  Say "Check progress with:  manage-bde -status $($l):   (done when it says Fully Decrypted)"
  Say 'Best done from inside Windows, so a restart does not interrupt it.'
}

function Cmd-ListDisks {
  Head 'Disks'
  try {
    Get-Disk | Sort-Object Number | ForEach-Object {
      $letters = (Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { "$($_.DriveLetter):" }) -join ' '
      Say ("  Disk {0}   {1}   {2} GB   {3}   letters: {4}" -f $_.Number, $_.FriendlyName, [math]::Round($_.Size / 1GB, 1), $_.BusType, $letters)
    }
    Say 'Use the disk NUMBER with "Erase and format a disk". The rescue stick and the Windows disk are refused.'
  } catch {
    Say 'Get-Disk is not available here. Falling back to diskpart:'
    "list disk" | & diskpart.exe
  }
}

function Cmd-FormatDisk {
  Head 'Erase and format a disk'
  if ($Option -notmatch '^\d+$') { Say 'Type the disk number in the Option box first (see List disks).'; return }
  $n = [int]$Option
  $disk = Get-Disk -Number $n -ErrorAction SilentlyContinue
  if (-not $disk) { Say "There is no disk $n."; return }
  $parts = @(Get-Partition -DiskNumber $n -ErrorAction SilentlyContinue)
  $letters = @($parts | Where-Object DriveLetter | ForEach-Object { "$($_.DriveLetter)" })
  if ($disk.IsBoot -or $disk.IsSystem) { Say "Disk $n is the disk this PC runs from. Refused."; return }
  if ($Drive -and ($letters -contains $Drive.TrimEnd(':').ToUpper())) { Say "Disk $n holds the Windows drive ($Drive). Refused."; return }
  if ($letters -contains 'C') { Say "Disk $n holds C:. Refused."; return }
  if ($disk.BusType -eq 'USB') { Say "Disk $n is a USB drive (maybe the rescue stick). Refused here. Use the Windows script tools\format-disk.ps1 instead."; return }
  Say ("Disk {0}: {1}, {2} GB, {3}, drive letters: {4}" -f $n, $disk.FriendlyName, [math]::Round($disk.Size / 1GB, 1), $disk.BusType, ($letters -join ' '))
  if (-not (Confirm-Action "EVERYTHING on disk $n will be erased and cannot be recovered.")) { Say 'Cancelled.'; return }
  Say 'Erasing ...'
  Clear-Disk -Number $n -RemoveData -RemoveOEM -Confirm:$false
  Initialize-Disk -Number $n -PartitionStyle GPT
  $np = New-Partition -DiskNumber $n -UseMaximumSize -AssignDriveLetter
  Format-Volume -Partition $np -FileSystem NTFS -NewFileSystemLabel 'Data' -Confirm:$false | Out-Null
  Say "Done. Disk $n is now one NTFS drive named Data as $($np.DriveLetter):"
}
