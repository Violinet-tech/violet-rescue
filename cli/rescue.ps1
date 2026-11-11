# Violet Rescue - CLI backend.
# Runs inside the Violet Rescue boot media (WinRE/WinPE with PowerShell) or in full Windows as admin.
# Every command works on an OFFLINE Windows install chosen with -Drive.
#
#   rescue.ps1 <command> [-Drive C] [-Target E] [-Option text] [-Yes]
#
# -Yes skips the "Type Y" prompt (the GUI asks first, then passes -Yes).
param(
  [Parameter(Position = 0)][string]$Command = 'help',
  [string]$Drive,
  [string]$Target,
  [string]$Option,
  [switch]$Yes
)

$ErrorActionPreference = 'Continue'
# A pasted name often carries a leading or trailing space, which made "No installed update matches ' Package...'".
$Option = "$Option".Trim(); $Drive = "$Drive".Trim(); $Target = "$Target".Trim()
$Root       = Split-Path -Parent $PSScriptRoot
$DbFile     = Join-Path $Root 'db\known-bad.json'
$SourceFile = Join-Path $Root 'db\source.json'
$DriversDir = Join-Path $Root 'drivers'
$EspGuid    = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$CliPath    = $PSCommandPath

function Say($t)  { Write-Output $t }
function Head($t) { Write-Output ''; Write-Output "=== $t ===" }

foreach ($m in 'common', 'wire', 'newwin', 'migrate', 'nvidia', 'peer', 'agent', 'devconfig', 'restorepoints') { . (Join-Path $PSScriptRoot "modules\$m.ps1") }

# ---------------------------------------------------------------- helpers

function Get-WindowsDrives {
  foreach ($c in [char[]](67..90)) {          # C..Z
    if ($c -eq 'X') { continue }              # X: is the rescue RAM disk itself
    if (Test-Path "$($c):\Windows\System32\config\SYSTEM") { "$c" }
  }
}

function Resolve-Drive {
  if ($Drive) { $d = $Drive.TrimEnd(':', '\').ToUpper() }
  else {
    $all = @(Get-WindowsDrives)
    if ($all.Count -eq 0) { throw 'No Windows install found on any drive.' }
    if ($all.Count -gt 1) { throw "More than one Windows found ($($all -join ', ')). Pick one with -Drive." }
    $d = $all[0]
  }
  if (-not (Test-Path "$($d):\Windows\System32\config\SYSTEM")) { throw "No Windows install on $($d):" }
  return $d
}

function Resolve-Target {
  if (-not $Target) { throw 'This command needs a target drive (-Target).' }
  $t = $Target.TrimEnd(':', '\').ToUpper()
  if (-not (Test-Path "$($t):\")) { throw "Target drive $($t): is not there." }
  return $t
}

function Confirm-Action($what) {
  Say $what
  if ($Yes) { return $true }
  $a = Read-Host 'Type Y and press Enter to continue'
  return ($a -eq 'Y' -or $a -eq 'y')
}

function Load-Db {
  if (Test-Path $DbFile) { return (Get-Content $DbFile -Raw | ConvertFrom-Json) }
  return [pscustomobject]@{ bad = @() }
}

# Load an offline registry hive, run $body with its PowerShell path, always unload.
function Use-Hive($file, $name, [scriptblock]$body) {
  $key = "HKLM\RESCUE_$name"
  & reg.exe load $key $file 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Could not load registry hive $file" }
  try { & $body "Registry::HKEY_LOCAL_MACHINE\RESCUE_$name" }
  finally {
    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
    & reg.exe unload $key 2>&1 | Out-Null
  }
}

function Get-Updates($d) {
  Get-WindowsPackage -Path "$($d):\" |
    Where-Object { $_.ReleaseType -match 'Update|Hotfix' -or $_.PackageName -match 'RollupFix|KB\d' } |
    Sort-Object InstallTime -Descending
}

function Remove-Update($d, $name) {
  $scratch = "$($d):\RescueScratch"
  New-Item -ItemType Directory -Force $scratch | Out-Null
  Say "Removing $name ..."
  try {
    Remove-WindowsPackage -Path "$($d):\" -PackageName $name -ScratchDirectory $scratch -NoRestart -ErrorAction Stop | Out-Null
    Say 'Removed (it may finish on the next boot as "Working on updates").'
    return $true
  } catch {
    Say "PowerShell removal failed: $($_.Exception.Message)"
    Say 'Trying dism.exe ...'
    & dism.exe "/image:$($d):\" "/scratchdir:$scratch" /remove-package "/packagename:$name"
    return ($LASTEXITCODE -eq 0)
  }
}

# ---------------------------------------------------------------- commands

function Cmd-Help {
  Say 'Violet Rescue commands:'
  Say '  drives                 List every drive and which hold Windows'
  Say '  updates                List installed updates, newest first, known-bad ones flagged'
  Say '  remove-update          Remove one update (Option = package name or KB; empty = newest)'
  Say '  revert-pending         Undo half-finished update steps'
  Say '  rollback               Remove updates AND drivers installed since a date (Option = yyyy-MM-dd)'
  Say '  restore                Open System Restore for the offline Windows'
  Say '  sfc                    Check system files offline'
  Say '  chkdsk                 Check and fix the Windows drive'
  Say '  restorehealth          DISM repair from install media (Option = install.wim/esd path, optional :index)'
  Say '  bootfix                Rebuild the EFI boot files and BCD'
  Say '  drivers                List third-party drivers (Option = filter text)'
  Say '  remove-nvidia          Remove NVIDIA display drivers (Option = all to remove every NVIDIA driver)'
  Say '  remove-driver          Remove drivers (Option = oemNN.inf, or Provider[,Class] e.g. Realtek,Net)'
  Say '  add-drivers            Install drivers (Option = nvidia, realtek, amd-chipset, or a folder path)'
  Say '  block-driver-updates   Stop Windows Update installing drivers'
  Say '  unblock-driver-updates Let Windows Update install drivers again'
  Say '  malware-scan           List startup entries and services, flag suspicious ones'
  Say '  disable-startup        Disable a startup entry by name (Option = name from malware-scan)'
  Say '  backup                 Copy user files to another drive (-Target; Option = other source folder)'
  Say '  net-up                 Start networking (loads drivers\realtek network drivers)'
  Say '  update-db              Download the latest known-bad-update list'
  Say '  new-windows            Fresh Windows on a new partition (Option = GB to take from -Drive, or -Target partition)'
  Say '  migrate-list           List folders that can be moved to the new Windows'
  Say '  migrate-pack           Pack chosen folders into one zip on -Target (Option = file listing the folders)'
  Say '  migrate-restore        In the new Windows: unzip and put every file back in place'
  Say '  nvidia-gpus            List every NVIDIA card, current and legacy (Option = filter)'
  Say '  nvidia-versions        List ALL driver versions for a card, legacy included (Option = "card|game|studio|all")'
  Say '  nvidia-driver          Download the newest, or a chosen version (Option = "card|game" or "card|studio|621.14")'
  Say '  cable-check            Is an Ethernet cable going to another computer, and is a helper there'
  Say '  cable-link             Link to the helper PC (Option = its 6-digit code)'
  Say '  support-bundle         Collect logs and lists for diagnosis'
  Say '  agent                  Start Claude Code with the rescue brief (where Claude Code is installed)'
  Say '  devconfig              Set up the fresh Windows with Microsoft Windows Developer Config (Option = list or a setup id)'
  Say ''
  Say ' Restore points'
  Say '  rp-check               What restore points and snapshots exist, and whether they work'
  Say '  rp-fix                 (in Windows) Switch System Restore on, repair it, make a restore point and test it'
  Say '  rp-reset               (in Windows) Delete the damaged restore points and start fresh'
  Say '  rp-auto                (in Windows) Daily restore point + Violet snapshot (Option = how many to keep, or off)'
  Say '  rp-make                (in Windows) Restore point + Violet snapshot now'
  Say '  restore-safe           (USB) System Restore with the usual failure causes fixed first (Option undo)'
  Say '  rp-shadow-restore      (USB) Registry straight out of a restore point (Option = number from rp-check)'
  Say '  snap-make / snap-list  Violet snapshot of the whole registry / list them'
  Say '  snap-restore           (USB) Put a Violet snapshot back (Option = name from snap-list, default newest)'
}

function Cmd-Drives {
  Head 'Drives'
  Get-CimInstance Win32_LogicalDisk | ForEach-Object {
    $win = ''
    if ($_.DeviceID -ne 'X:' -and (Test-Path "$($_.DeviceID)\Windows\System32\config\SYSTEM")) { $win = '<- Windows' }
    '{0}  {1,-16} {2,8:N1} GB free of {3,8:N1} GB  {4}' -f $_.DeviceID, $_.VolumeName, ([double]$_.FreeSpace / 1GB), ([double]$_.Size / 1GB), $win
  }
}

function Cmd-Updates {
  $d = Resolve-Drive
  Head "Updates on $($d):"
  $db = Load-Db
  foreach ($p in Get-Updates $d) {
    $flag = ''
    foreach ($b in $db.bad) { if ($p.PackageName -like "*$($b.match)*") { $flag = "   <-- KNOWN BAD: $($b.note)" } }
    '{0:yyyy-MM-dd HH:mm}  {1,-15} {2}{3}' -f $p.InstallTime, $p.ReleaseType, $p.PackageName, $flag
  }
  Say ''
  Say 'Newest at the top. To remove one, pick remove-update and put its name or KB in Option.'
}

function Cmd-RemoveUpdate {
  $d = Resolve-Drive
  $ups = @(Get-Updates $d)
  if ($Option) { $hit = @($ups | Where-Object { $_.PackageName -eq $Option -or $_.PackageName -like "*$Option*" }) }
  else         { $hit = @($ups | Select-Object -First 1) }
  if ($hit.Count -eq 0) { throw "No installed update matches '$Option'." }
  if ($hit.Count -gt 1) {
    Say 'More than one update matches. Put the full name in Option:'
    $hit | ForEach-Object { '  ' + $_.PackageName }
    return
  }
  $p = $hit[0]
  if (-not (Confirm-Action ("Remove {0} (installed {1:yyyy-MM-dd}) from {2}: ?" -f $p.PackageName, $p.InstallTime, $d))) { Say 'Cancelled.'; return }
  [void](Remove-Update $d $p.PackageName)
}

function Cmd-RemoveBadUpdate {
  $d = Resolve-Drive
  $db = Load-Db
  $ups = @(Get-Updates $d)
  $hit = @($ups | Where-Object { $p = $_; ($db.bad | Where-Object { $p.PackageName -like "*$($_.match)*" }) })
  if ($hit.Count -eq 0) { Say "None of the known-bad updates in the list is installed on $($d):. Nothing was removed."; return }
  foreach ($p in $hit) {
    if (-not (Confirm-Action ("Remove the known-bad update {0} (installed {1:yyyy-MM-dd}) from {2}: ?" -f $p.PackageName, $p.InstallTime, $d))) { Say 'Cancelled.'; return }
    if (Remove-Update $d $p.PackageName) { Say 'Done. Restart the PC without the USB stick.' } else { Say 'The removal failed. Try Undo pending updates, then System Restore.' }
  }
}

function Cmd-ClearPending {
  # For when DISM cannot undo a half-done update (its version is older than the Windows it repairs).
  # Everything it changes is copied to <drive>:\VioletRescue\PendingBackup\<time> first.
  $d = Resolve-Drive
  Head "Clear stuck update leftovers on $($d):"
  $px = "$($d):\Windows\WinSxS\pending.xml"
  $comp = "$($d):\Windows\System32\config\COMPONENTS"
  if (-not (Confirm-Action "Clear the stuck pending-update entries on $($d): ? What it changes is saved first.")) { Say 'Cancelled.'; return }
  $bk = "$($d):\VioletRescue\PendingBackup\" + (Get-Date -Format 'yyyyMMdd-HHmmss')
  New-Item -ItemType Directory -Force $bk | Out-Null
  Say "Backups go to $bk"
  if (Test-Path $px) {
    Copy-Item $px $bk -Force
    Rename-Item $px 'pending.xml.violet' -Force
    Say 'pending.xml set aside (renamed pending.xml.violet).'
  } else { Say 'No pending.xml found.' }
  if (Test-Path $comp) {
    Copy-Item $comp $bk -Force
    Use-Hive $comp 'COMP' {
      param($root)
      foreach ($v in 'PendingXmlIdentifier', 'NextQueueEntryIndex', 'AdvancedInstallersNeedResolving') {
        if (Get-ItemProperty -Path $root -Name $v -ErrorAction SilentlyContinue) {
          Remove-ItemProperty -Path $root -Name $v -Force -ErrorAction SilentlyContinue
          Say "Removed registry value $v"
        }
      }
    }
  } else { Say 'No COMPONENTS registry file found.' }
  Use-Hive "$($d):\Windows\System32\config\SYSTEM" 'SYS' {
    param($root)
    $se = (Get-ItemProperty -Path "$root\ControlSet001\Control\Session Manager" -Name SetupExecute -ErrorAction SilentlyContinue).SetupExecute
    if ($se) { Say ('SetupExecute is set (shown only, not changed): ' + ($se -join ' | ')) } else { Say 'SetupExecute is empty.' }
  }
  Say 'Done. Restart without the USB stick.'
}

function Cmd-RevertPending {
  $d = Resolve-Drive
  if (-not (Confirm-Action "Undo pending update actions on $($d): ?")) { Say 'Cancelled.'; return }
  # The rescue RAM disk (X:) is too small for DISM's scratch space; use the Windows drive.
  $scratch = "$($d):\RescueScratch"
  New-Item -ItemType Directory -Force $scratch | Out-Null
  & dism.exe "/image:$($d):\" "/scratchdir:$scratch" /cleanup-image /revertpendingactions
  $px = "$($d):\Windows\WinSxS\pending.xml"
  if (Test-Path $px) { Rename-Item $px 'pending.old' -Force; Say 'Renamed pending.xml to pending.old.' }
}

function Cmd-Rollback {
  $d = Resolve-Drive
  if (-not $Option) { throw 'Put the date things broke in Option, like 2026-11-02.' }
  $since = [datetime]::ParseExact($Option, 'yyyy-MM-dd', $null)
  Head "Installed on or after $($since.ToString('yyyy-MM-dd'))"
  $ups = @(Get-Updates $d | Where-Object { $_.InstallTime -ge $since })
  $drv = @(Get-WindowsDriver -Path "$($d):\" | Where-Object {
      $f = "$($d):\Windows\INF\$($_.Driver)"
      (Test-Path $f) -and ((Get-Item $f).CreationTime -ge $since) })
  Say 'Updates:'; if ($ups.Count) { $ups | ForEach-Object { '  ' + $_.PackageName } } else { Say '  none' }
  Say 'Drivers:'; if ($drv.Count) { $drv | ForEach-Object { '  {0}  {1}  {2}  {3}' -f $_.Driver, $_.ProviderName, $_.ClassName, $_.OriginalFileName } } else { Say '  none' }
  if (($ups.Count + $drv.Count) -eq 0) { return }
  if (-not (Confirm-Action 'Remove everything listed above? Windows falls back to its own built-in drivers.')) { Say 'Cancelled.'; return }
  foreach ($u in $ups) { [void](Remove-Update $d $u.PackageName) }
  foreach ($r in $drv) {
    Say "Removing driver $($r.Driver) ..."
    try { Remove-WindowsDriver -Path "$($d):\" -Driver $r.Driver -ErrorAction Stop | Out-Null }
    catch { Say "  failed: $($_.Exception.Message)" }
  }
  $scratch = "$($d):\RescueScratch"
  New-Item -ItemType Directory -Force $scratch | Out-Null
  & dism.exe "/image:$($d):\" "/scratchdir:$scratch" /cleanup-image /revertpendingactions
  Say 'Rollback done. Restart without the USB.'
}

function Cmd-Restore {
  $d = Resolve-Drive
  $exe = Join-Path $env:SystemRoot 'System32\rstrui.exe'
  if (-not (Test-Path $exe)) { throw 'System Restore (rstrui.exe) is not in this boot image. Build the media from winre.wim.' }
  Say 'Opening System Restore. Restore points are listed in its window.'
  Say 'If it fails (0x800700fe, 0x80070091), use restore-safe, which fixes the usual causes first,'
  Say 'or rp-shadow-restore / snap-restore, which do not need System Restore at all.'
  & $exe "/offline:$($d):\Windows"
}

function Cmd-Sfc {
  $d = Resolve-Drive
  Head "System file check on $($d): (several minutes)"
  & sfc.exe /scannow "/offbootdir=$($d):\" "/offwindir=$($d):\Windows" 2>&1 | ForEach-Object { ($_ -replace "`0", '') } | Where-Object { $_.Trim() }
}

function Cmd-Chkdsk {
  $d = Resolve-Drive
  if (-not (Confirm-Action "Check and fix $($d): (it is dismounted while it runs)?")) { Say 'Cancelled.'; return }
  & chkdsk.exe "$($d):" /f /x
}

function Cmd-RestoreHealth {
  $d = Resolve-Drive
  $src = $null; $idx = $null
  if ($Option) {
    if ($Option -match '^(.*\.(wim|esd)):(\d+)$') { $src = $Matches[1]; $idx = [int]$Matches[3] } else { $src = $Option }
  } else {
    foreach ($c in [char[]](67..90)) {
      foreach ($n in 'install.wim', 'install.esd') { if (-not $src -and (Test-Path "$($c):\sources\$n")) { $src = "$($c):\sources\$n" } }
    }
  }
  if (-not $src) { throw 'No install.wim or install.esd found. Plug in Windows install media or put the path in Option.' }
  if (-not $idx) {
    $edition = Use-Hive "$($d):\Windows\System32\config\SOFTWARE" 'SOFT' { param($r) (Get-ItemProperty "$r\Microsoft\Windows NT\CurrentVersion").EditionID }
    $idx = 1
    foreach ($img in Get-WindowsImage -ImagePath $src) {
      $full = Get-WindowsImage -ImagePath $src -Index $img.ImageIndex
      if ($full.EditionId -eq $edition) { $idx = $img.ImageIndex }
    }
    Say "Installed edition: $edition  ->  using index $idx of $src"
  }
  $kind = if ($src -like '*.esd') { 'ESD' } else { 'WIM' }
  $scratch = "$($d):\RescueScratch"; New-Item -ItemType Directory -Force $scratch | Out-Null
  & dism.exe "/image:$($d):\" "/scratchdir:$scratch" /cleanup-image /restorehealth "/source:$($kind):$($src):$idx" /limitaccess
  Say 'If it says the source files could not be found (0x800f0915/0x800f081f), the media is a different build than the installed Windows.'
}

function Cmd-BootFix {
  $d = Resolve-Drive
  $part = Get-Partition -DriveLetter $d
  $esp = Get-Partition -DiskNumber $part.DiskNumber | Where-Object { $_.GptType -eq $EspGuid } | Select-Object -First 1
  if (-not $esp) { throw "No EFI System partition on disk $($part.DiskNumber)." }
  Say ('EFI System partition: disk {0} partition {1}, {2:N0} MB' -f $esp.DiskNumber, $esp.PartitionNumber, ($esp.Size / 1MB))
  if (-not (Confirm-Action "Rebuild boot files for Windows on $($d): ?")) { Say 'Cancelled.'; return }
  if (-not $esp.DriveLetter -or $esp.DriveLetter -eq "`0") { $esp | Set-Partition -NewDriveLetter S; $L = 'S' } else { $L = "$($esp.DriveLetter)" }
  $vol = Get-Volume -DriveLetter $L
  if ($vol.FileSystem -ne 'FAT32') {
    if (-not (Confirm-Action "The EFI partition is $($vol.FileSystem), not FAT32, so it cannot boot. Format it FAT32? (only boot files live there)")) { Say 'Cancelled.'; return }
    Format-Volume -DriveLetter $L -FileSystem FAT32 -NewFileSystemLabel System -Confirm:$false | Out-Null
  }
  $bcd = "$($L):\EFI\Microsoft\Boot\BCD"
  if (Test-Path $bcd) {
    attrib -s -h -r $bcd
    # Never overwrite an earlier backup: the first one is the original, untouched boot file.
    $bak = "$bcd.bak"; $n = 1
    while (Test-Path $bak) { $n++; $bak = "$bcd.bak$n" }
    Copy-Item $bcd $bak -Force
    Remove-Item $bcd -Force
    Say ("Old BCD saved as {0}." -f (Split-Path $bak -Leaf))
  }
  & bcdboot.exe "$($d):\Windows" /s "$($L):" /f UEFI
  if (Test-Path $bcd) { Say 'Boot files rebuilt.'; & bcdedit.exe /store $bcd /enum '{default}' } else { Say 'bcdboot did not create a BCD.' }
}

function Cmd-Drivers {
  $d = Resolve-Drive
  Head "Third-party drivers on $($d):"
  Get-WindowsDriver -Path "$($d):\" |
    Where-Object { -not $Option -or ("$($_.ProviderName) $($_.ClassName) $($_.OriginalFileName)" -match [regex]::Escape($Option)) } |
    Sort-Object ProviderName, ClassName |
    ForEach-Object { '{0,-11} {1:yyyy-MM-dd} {2,-22} {3,-14} {4}' -f $_.Driver, $_.Date, $_.ProviderName, $_.ClassName, (Split-Path $_.OriginalFileName -Leaf) }
}

function Remove-Drivers($d, $list) {
  if (-not $list.Count) { Say 'No matching drivers.'; return }
  $list | ForEach-Object { '  {0}  {1}  {2}  {3}' -f $_.Driver, $_.ProviderName, $_.ClassName, (Split-Path $_.OriginalFileName -Leaf) }
  if (-not (Confirm-Action 'Remove the drivers above?')) { Say 'Cancelled.'; return }
  foreach ($r in $list) {
    Say "Removing $($r.Driver) ..."
    try { Remove-WindowsDriver -Path "$($d):\" -Driver $r.Driver -ErrorAction Stop | Out-Null; Say '  done' }
    catch { Say "  failed: $($_.Exception.Message)" }
  }
}

function Cmd-RemoveNvidia {
  $d = Resolve-Drive
  $all = Get-WindowsDriver -Path "$($d):\" | Where-Object { $_.ProviderName -match 'NVIDIA' }
  if ($Option -ne 'all') { $all = $all | Where-Object { $_.ClassName -eq 'Display' } }
  Remove-Drivers $d @($all)
  Say 'Windows uses its basic display driver until a new NVIDIA driver is installed.'
}

function Cmd-RemoveDriver {
  $d = Resolve-Drive
  if (-not $Option) { throw 'Put oemNN.inf or Provider[,Class] in Option (see the drivers command).' }
  $all = Get-WindowsDriver -Path "$($d):\"
  if ($Option -match '^oem\d+\.inf$') { $list = $all | Where-Object { $_.Driver -eq $Option } }
  else {
    $prov, $cls = $Option.Split(',', 2)
    $list = $all | Where-Object { $_.ProviderName -match [regex]::Escape($prov.Trim()) -and (-not $cls -or $_.ClassName -eq $cls.Trim()) }
  }
  Remove-Drivers $d @($list)
}

function Cmd-AddDrivers {
  $d = Resolve-Drive
  if (-not $Option) { throw 'Put nvidia, realtek, amd-chipset or a folder path in Option.' }
  $dir = if (Test-Path $Option) { $Option } else { Join-Path $DriversDir $Option }
  if (-not (Get-ChildItem $dir -Recurse -Filter *.inf -ErrorAction SilentlyContinue)) { throw "No .inf driver files in $dir (see drivers\README.md)." }
  if (-not (Confirm-Action "Install every driver in $dir into $($d): ?")) { Say 'Cancelled.'; return }
  Add-WindowsDriver -Path "$($d):\" -Driver $dir -Recurse | ForEach-Object { '  added ' + $_.Driver + '  ' + $_.OriginalFileName }
}

function Set-DriverBlock($block) {
  $d = Resolve-Drive
  $verb = if ($block) { 'Block' } else { 'Allow' }
  if (-not (Confirm-Action "$verb driver installs from Windows Update on $($d): ?")) { Say 'Cancelled.'; return }
  Use-Hive "$($d):\Windows\System32\config\SOFTWARE" 'SOFT' {
    param($r)
    $wu = "$r\Policies\Microsoft\Windows\WindowsUpdate"
    $ds = "$r\Microsoft\Windows\CurrentVersion\DriverSearching"
    New-Item $wu -Force | Out-Null
    New-Item $ds -Force | Out-Null
    if ($block) {
      Set-ItemProperty $wu ExcludeWUDriversInQualityUpdate 1 -Type DWord
      Set-ItemProperty $ds SearchOrderConfig 0 -Type DWord
    } else {
      Remove-ItemProperty $wu ExcludeWUDriversInQualityUpdate -ErrorAction SilentlyContinue
      Set-ItemProperty $ds SearchOrderConfig 1 -Type DWord
    }
  }
  Say "$verb set. Takes effect when Windows starts."
}

$RunKeys = 'Microsoft\Windows\CurrentVersion\Run', 'Microsoft\Windows\CurrentVersion\RunOnce', 'WOW6432Node\Microsoft\Windows\CurrentVersion\Run'

function Test-Suspicious($d, $cmd) {
  if (-not $cmd) { return '' }
  $why = @()
  if ($cmd -match '\\(AppData|Temp|ProgramData|Users\\Public)\\') { $why += 'runs from a user-writable folder' }
  if ($cmd -match 'powershell.*(-enc|-e |hidden)|mshta|wscript|cscript|rundll32.*,#') { $why += 'script/launcher trick' }
  if ($cmd -match '"?([A-Za-z]:\\[^"]+?\.(exe|dll))') {
    $f = $Matches[1] -replace '^[A-Za-z]:', "$($d):"
    if (-not (Test-Path $f)) { $why += 'file missing' }
    elseif ((Get-AuthenticodeSignature $f).Status -ne 'Valid') { $why += 'not signed' }
  }
  return ($why -join ', ')
}

function Get-StartupEntries($d) {
  $out = @()
  Use-Hive "$($d):\Windows\System32\config\SOFTWARE" 'SOFT' {
    param($r)
    foreach ($k in $RunKeys) {
      $p = Get-ItemProperty "$r\$k" -ErrorAction SilentlyContinue
      if ($p) { $p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $script:entries += [pscustomobject]@{ Where = "Machine $k"; Name = $_.Name; Cmd = "$($_.Value)" } } }
    }
  }
  foreach ($u in Get-ChildItem "$($d):\Users" -Directory -ErrorAction SilentlyContinue) {
    $nt = Join-Path $u.FullName 'NTUSER.DAT'
    if (-not (Test-Path $nt)) { continue }
    try {
      Use-Hive $nt "U_$($u.Name -replace '\W', '')" {
        param($r)
        foreach ($k in $RunKeys[0..1]) {
          $p = Get-ItemProperty "$r\Software\$k" -ErrorAction SilentlyContinue
          if ($p) { $p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $script:entries += [pscustomobject]@{ Where = "User $($u.Name)"; Name = $_.Name; Cmd = "$($_.Value)" } } }
        }
      }
    } catch { Say "  (could not read $($u.Name): $($_.Exception.Message))" }
  }
}

function Cmd-MalwareScan {
  $d = Resolve-Drive
  Head "Startup entries on $($d):"
  $script:entries = @()
  Get-StartupEntries $d
  foreach ($e in $script:entries) {
    $s = Test-Suspicious $d $e.Cmd
    $mark = if ($s) { "  <-- CHECK: $s" } else { '' }
    Say ("[{0}] {1}{2}" -f $e.Where, $e.Name, $mark)
    Say "      $($e.Cmd)"
  }
  Head 'Services that run from unusual places'
  Use-Hive "$($d):\Windows\System32\config\SYSTEM" 'SYS' {
    param($r)
    Get-ChildItem "$r\ControlSet001\Services" | ForEach-Object {
      $ip = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ImagePath
      if ($ip -and $ip -match '\\(AppData|Temp|ProgramData|Users)\\') { Say ("{0}`n      {1}" -f $_.PSChildName, $ip) }
    }
  }
  Say ''
  Say 'This is a startup check, not a full virus scan. To turn an entry off: disable-startup with its name in Option.'
  Say 'Once Windows boots, run a full offline scan from an admin PowerShell:  Start-MpWDOScan'
}

function Cmd-DisableStartup {
  $d = Resolve-Drive
  if (-not $Option) { throw 'Put the startup entry name (from malware-scan) in Option.' }
  if (-not (Confirm-Action "Disable startup entry '$Option' on $($d): ? (it is moved to a RescueDisabled key, not deleted)")) { Say 'Cancelled.'; return }
  $script:done = $false
  $move = {
    param($r, $keys)
    foreach ($k in $keys) {
      $p = Get-ItemProperty "$r\$k" -Name $Option -ErrorAction SilentlyContinue
      if ($p) {
        New-Item "$r\$k\RescueDisabled" -Force | Out-Null
        Set-ItemProperty "$r\$k\RescueDisabled" $Option $p.$Option
        Remove-ItemProperty "$r\$k" $Option
        Say "Disabled in $k"; $script:done = $true
      }
    }
  }
  Use-Hive "$($d):\Windows\System32\config\SOFTWARE" 'SOFT' { param($r) & $move $r $RunKeys }
  foreach ($u in Get-ChildItem "$($d):\Users" -Directory -ErrorAction SilentlyContinue) {
    $nt = Join-Path $u.FullName 'NTUSER.DAT'
    if (Test-Path $nt) { try { Use-Hive $nt "U_$($u.Name -replace '\W', '')" { param($r) & $move $r ($RunKeys[0..1] | ForEach-Object { "Software\$_" }) } } catch {} }
  }
  if (-not $script:done) { Say "No startup entry named '$Option' found." }
}

function Cmd-Backup {
  $d = Resolve-Drive
  $t = Resolve-Target
  if ($t -eq $d) { throw 'Target is the same drive as Windows. Pick another drive.' }
  $src = if ($Option) { $Option } else { "$($d):\Users" }
  if (-not (Test-Path $src)) { throw "Source $src not found." }
  $dest = "$($t):\VioletRescueBackup\$(Get-Date -Format 'yyyy-MM-dd_HHmm')\$(Split-Path $src -Leaf)"
  $free = (Get-PSDrive $t).Free
  Say ('Copying {0}  ->  {1}   ({2:N1} GB free on {3}:)' -f $src, $dest, ($free / 1GB), $t)
  if (-not (Confirm-Action 'Start the backup? Nothing is deleted from the source.')) { Say 'Cancelled.'; return }
  & robocopy.exe $src $dest /E /XJ /R:1 /W:1 /MT:16 /NP /NDL /XD 'AppData\Local\Temp' 'INetCache' 'Temporary Internet Files' /XF 'NTUSER.DAT*' 'UsrClass.dat*' /LOG+:"$($t):\VioletRescueBackup\backup-log.txt" /TEE
  if ($LASTEXITCODE -lt 8) { Say 'Backup finished.' } else { Say "Backup finished with errors (robocopy code $LASTEXITCODE). See backup-log.txt." }
}

function Cmd-NetUp {
  Head 'Starting network'
  $net = Join-Path $DriversDir 'realtek'
  Get-ChildItem $net -Recurse -Filter *.inf -ErrorAction SilentlyContinue | ForEach-Object { Say "Loading $($_.Name)"; & drvload.exe $_.FullName }
  & wpeutil.exe InitializeNetwork
  Start-Sleep 5
  & ipconfig.exe
  Say 'Wired Ethernet only. Wi-Fi dongles usually do not work in a rescue environment.'
}

function Cmd-UpdateDb {
  $cfg = Get-Content $SourceFile -Raw | ConvertFrom-Json
  if (-not $cfg.url) { throw 'No update source is set in db\source.json yet.' }
  Say "Downloading $($cfg.url)"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $tmp = "$DbFile.new"
  Invoke-WebRequest $cfg.url -OutFile $tmp -UseBasicParsing
  $new = Get-Content $tmp -Raw | ConvertFrom-Json   # throws if it is not valid JSON
  Move-Item $tmp $DbFile -Force
  Say "Updated: $($new.bad.Count) known-bad updates, list dated $($new.updated)."
}

# ---------------------------------------------------------------- dispatch

try {
  switch ($Command.ToLower()) {
    'help'                   { Cmd-Help }
    'drives'                 { Cmd-Drives }
    'updates'                { Cmd-Updates }
    'remove-update'          { Cmd-RemoveUpdate }
    'remove-bad-update'      { Cmd-RemoveBadUpdate }
    'clear-pending'          { Cmd-ClearPending }
    'revert-pending'         { Cmd-RevertPending }
    'rollback'               { Cmd-Rollback }
    'restore'                { Cmd-Restore }
    'sfc'                    { Cmd-Sfc }
    'chkdsk'                 { Cmd-Chkdsk }
    'restorehealth'          { Cmd-RestoreHealth }
    'bootfix'                { Cmd-BootFix }
    'drivers'                { Cmd-Drivers }
    'remove-nvidia'          { Cmd-RemoveNvidia }
    'remove-driver'          { Cmd-RemoveDriver }
    'add-drivers'            { Cmd-AddDrivers }
    'block-driver-updates'   { Set-DriverBlock $true }
    'unblock-driver-updates' { Set-DriverBlock $false }
    'malware-scan'           { Cmd-MalwareScan }
    'disable-startup'        { Cmd-DisableStartup }
    'backup'                 { Cmd-Backup }
    'net-up'                 { Cmd-NetUp }
    'update-db'              { Cmd-UpdateDb }
    'new-windows'            { Cmd-NewWindows }
    'migrate-list'           { Cmd-MigrateList }
    'migrate-pack'           { Cmd-MigratePack }
    'migrate-restore'        { Cmd-MigrateRestore }
    'nvidia-gpus'            { Cmd-NvidiaGpus }
    'nvidia-driver'          { Cmd-NvidiaDriver }
    'nvidia-versions'        { Cmd-NvidiaVersions }
    'cable-check'            { Cmd-CableCheck }
    'cable-link'             { Cmd-CableLink }
    'support-bundle'         { Cmd-SupportBundle }
    'agent'                  { Cmd-Agent }
    'devconfig'              { Cmd-DevConfig }
    'rp-check'               { Cmd-RpCheck }
    'rp-fix'                 { Cmd-RpFix }
    'rp-reset'               { Cmd-RpReset }
    'rp-auto'                { Cmd-RpAuto }
    'rp-make'                { Cmd-RpMake }
    'restore-safe'           { Cmd-RestoreSafe }
    'rp-shadow-restore'      { Cmd-RpShadowRestore }
    'snap-make'              { Cmd-SnapMake }
    'snap-list'              { Cmd-SnapList }
    'snap-restore'           { Cmd-SnapRestore }
    default                  { Say "Unknown command '$Command'."; Cmd-Help; exit 2 }
  }
} catch {
  Say ''
  Say "ERROR: $($_.Exception.Message)"
  exit 1
}
