# Restore points that are there and work when they are needed. Dot-sourced by rescue.ps1.
#
# Two layers:
#  1. Windows System Restore, repaired and tested: services, policy, storage, VSS writers, a fresh restore point
#     that is opened to prove it holds the registry. Plus the RegBack registry backup Windows stopped making in 2018.
#  2. Violet snapshots: our own copy of the whole registry (system hives and every user's hives) in
#     <drive>:\VioletRescue\Snapshots. They need no shadow copy service, so they can be put back from the USB
#     even when System Restore itself fails (0x800700fe, 0x80070091, "System Restore did not complete").
#
# In a working Windows:
#   rp-check              what is there and whether it works (also from the USB)
#   rp-fix                switch System Restore on, repair what it needs, make a restore point and test it
#   rp-reset              delete the damaged restore points and start fresh (then rp-fix)
#   rp-auto [-Option N]   daily + at start: a restore point and a Violet snapshot, keep N snapshots (off = stop)
#   rp-make               make a restore point and a Violet snapshot now
# From the rescue USB:
#   restore-safe          System Restore with the usual failure causes fixed first (Option undo = put WindowsApps back)
#   rp-shadow-restore     put the registry back straight out of a restore point (Option = its number from rp-check)
#   snap-restore          put a Violet snapshot back (Option = its name from snap-list, default newest)
# Both:
#   snap-make, snap-list

$SnapHives = 'SYSTEM', 'SOFTWARE', 'SAM', 'SECURITY', 'DEFAULT', 'COMPONENTS'
$SrKey     = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$script:lastSnap = $null; $script:lastUndo = $null; $script:shadowOk = $false

function Test-LiveDrive($d) { $env:SystemDrive -ne 'X:' -and $env:SystemDrive.TrimEnd(':') -eq $d }
function Get-SnapRoot($d)   { "$($d):\VioletRescue\Snapshots" }
function Assert-Live        { if ($env:SystemDrive -eq 'X:') { throw 'This one runs inside a working Windows. From the rescue USB use restore-safe, rp-shadow-restore or snap-restore.' } }
function Assert-Offline($d) { if (Test-LiveDrive $d) { throw "Windows on $($d): is running. This is done from the rescue USB, while that Windows is switched off." } }

function Get-WinBuild($d) { (Get-Item "$($d):\Windows\System32\ntoskrnl.exe").VersionInfo.ProductVersion }

# Restore points (shadow copies) of one drive. ok = $false when this boot image has no shadow copy service.
function Get-ShadowsFor($d) {
  try {
    $vol = Get-CimInstance Win32_Volume -Filter "DriveLetter='$($d):'" -ErrorAction Stop
    $list = @(Get-CimInstance Win32_ShadowCopy -ErrorAction Stop | Where-Object { $_.VolumeName -eq $vol.DeviceID } | Sort-Object InstallDate -Descending)
    return @{ ok = $true; list = $list }
  } catch { }
  # No shadow copy service (WinRE). The volsnap driver still exposes existing restore points as
  # \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopyN, which is how System Restore itself reads them here.
  try {
    $bat = Join-Path $env:TEMP 'violet-probe.cmd'
    $line = 'for /l %%i in (1,1,64) do if exist "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy%%i\Windows\System32\config\SOFTWARE" for %%f in ("\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy%%i\Windows\System32\config\SOFTWARE") do echo %%i %%~tf'
    Set-Content -Path $bat -Value @('@echo off', $line) -Encoding ASCII
    $out = @(& cmd.exe /c $bat 2>$null)
    $list = @()
    foreach ($o in $out) {
      if ("$o" -match '^\s*(\d+)\s+(.*)$') {
        $n = [int]$Matches[1]; $dt = [datetime]::MinValue
        [void][datetime]::TryParse($Matches[2].Trim(), [ref]$dt)
        $list += [pscustomobject]@{ DeviceObject = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy$n"; InstallDate = $dt; Index = $n }
      }
    }
    if ($list.Count) { return @{ ok = $true; list = @($list | Sort-Object Index -Descending); probed = $true } }
  } catch { }
  return @{ ok = $false; list = @() }
}

# Run a few cmd lines from a batch file (avoids quoting trouble) and return its exit code.
function Invoke-ShadowBat([string[]]$lines) {
  $bat = Join-Path $env:TEMP 'violet-shadow.cmd'
  Set-Content -Path $bat -Value (@('@echo off') + $lines) -Encoding ASCII
  & cmd.exe /c $bat *> $null
  return $LASTEXITCODE
}

# Link a shadow copy to a folder. Start-Process keeps the trailing backslash away from cmd's quote parsing.
function New-ShadowLink($device, $link) {
  if (Test-Path $link) { Remove-ShadowLink $link }
  Start-Process cmd.exe -ArgumentList "/c mklink /d `"$link`" $device\" -Wait -NoNewWindow
}
function Remove-ShadowLink($link) { Start-Process cmd.exe -ArgumentList "/c rmdir `"$link`"" -Wait -NoNewWindow }

function Get-SrSettings($d) {
  $read = {
    param($soft)
    $sr  = Get-ItemProperty "$soft\Microsoft\Windows NT\CurrentVersion\SystemRestore" -ErrorAction SilentlyContinue
    $pol = Get-ItemProperty "$soft\Policies\Microsoft\Windows NT\SystemRestore" -ErrorAction SilentlyContinue
    [pscustomobject]@{
      Off       = ($sr.DisableSR -eq 1 -or $sr.RPSessionInterval -eq 0)
      PolicyOff = ($pol.DisableSR -eq 1 -or $pol.DisableConfig -eq 1)
    }
  }
  if (Test-LiveDrive $d) { & $read 'HKLM:\SOFTWARE' }
  else { Use-Hive "$($d):\Windows\System32\config\SOFTWARE" 'SRSOFT' $read }
}

# User profiles (S-1-5-21-*) whose folder exists on this drive. Rel = path without the drive letter.
function Get-Profiles($d) {
  $read = {
    param($soft)
    Get-ChildItem "$soft\Microsoft\Windows NT\CurrentVersion\ProfileList" | Where-Object { $_.PSChildName -like 'S-1-5-21-*' } | ForEach-Object {
      $p = (Get-ItemProperty $_.PSPath).ProfileImagePath
      [pscustomobject]@{ Sid = $_.PSChildName; Rel = ($p -replace '^[A-Za-z]:', '') }
    }
  }
  $list = if (Test-LiveDrive $d) { & $read 'HKLM:\SOFTWARE' } else { Use-Hive "$($d):\Windows\System32\config\SOFTWARE" 'PROFSOFT' $read }
  foreach ($p in $list) { if (Test-Path "$($d):$($p.Rel)") { $p | Add-Member -NotePropertyName Path -NotePropertyValue "$($d):$($p.Rel)" -PassThru } }
}

function Get-Snapshots($d) {
  Get-ChildItem (Get-SnapRoot $d) -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') } |
    Sort-Object { (Get-Item (Join-Path $_.FullName 'manifest.json')).LastWriteTime } -Descending
}

# ---------------------------------------------------------------- Violet snapshots

# Saves the whole registry of Windows on $d. Sets $script:lastSnap (functions here never return values,
# because Say writes to the same output).
function Save-Snapshot($d, $why, $prefix = '') {
  $script:lastSnap = $null
  $dir  = Join-Path (Get-SnapRoot $d) ($prefix + (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
  $cfg  = "$($d):\Windows\System32\config"
  $live = Test-LiveDrive $d
  New-Item -ItemType Directory -Force (Join-Path $dir 'users') | Out-Null
  Say "Saving the registry to $dir ..."
  $saved = @()
  foreach ($h in $SnapHives) {
    $out = Join-Path $dir $h
    if ($live) {
      # reg save writes a clean, consistent copy of a hive that is in use.
      if ($h -eq 'COMPONENTS' -and -not (Test-Path 'HKLM:\COMPONENTS')) { Copy-Item "$cfg\COMPONENTS" $out -ErrorAction SilentlyContinue }
      else {
        $key = if ($h -eq 'DEFAULT') { 'HKU\.DEFAULT' } else { "HKLM\$h" }
        & reg.exe save $key $out /y 2>&1 | Out-Null
      }
    } else {
      # Offline the hive files are not locked. Their transaction logs go with them, so the pair stays consistent.
      foreach ($n in $h, "$h.LOG1", "$h.LOG2") { if (Test-Path "$cfg\$n") { Copy-Item "$cfg\$n" $dir -Force } }
    }
    if (Test-Path $out) { $saved += $h } else { Say "  could not save $h" }
  }
  $users = @()
  # If SOFTWARE is already damaged, the user list cannot be read: still save the system hives (that is what matters).
  $plist = @()
  try { $plist = @(Get-Profiles $d) } catch { Say "  could not read the user list ($($_.Exception.Message)); user registry files are left out of this snapshot" }
  foreach ($p in $plist) {
    $udir = Join-Path $dir "users\$($p.Sid)"
    New-Item -ItemType Directory -Force $udir | Out-Null
    $pairs = @(
      @('NTUSER.DAT',   "$($p.Path)\NTUSER.DAT",                                  "HKEY_USERS\$($p.Sid)",          "HKU\$($p.Sid)"),
      @('UsrClass.dat', "$($p.Path)\AppData\Local\Microsoft\Windows\UsrClass.dat", "HKEY_USERS\$($p.Sid)_Classes", "HKU\$($p.Sid)_Classes")
    )
    foreach ($x in $pairs) {
      if ($live -and (Test-Path "Registry::$($x[2])")) { & reg.exe save $x[3] (Join-Path $udir $x[0]) /y 2>&1 | Out-Null }
      elseif (Test-Path $x[1]) {
        Copy-Item $x[1] (Join-Path $udir $x[0]) -Force -ErrorAction SilentlyContinue
        foreach ($l in '.LOG1', '.LOG2') { if (Test-Path "$($x[1])$l") { Copy-Item "$($x[1])$l" (Join-Path $udir "$($x[0])$l") -Force -ErrorAction SilentlyContinue } }
      }
    }
    $users += [pscustomobject]@{ sid = $p.Sid; path = $p.Rel }
  }
  if ($saved -notcontains 'SYSTEM' -or $saved -notcontains 'SOFTWARE') {
    Say 'FAILED: SYSTEM or SOFTWARE could not be saved, so this snapshot would not be usable. It was deleted.'
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    return
  }
  if ($live) { & pnputil.exe /enum-drivers > (Join-Path $dir 'drivers.txt') 2>&1 }
  [pscustomobject]@{ made = (Get-Date).ToString('s'); why = $why; live = $live; build = (Get-WinBuild $d); hives = $saved; users = $users } |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'manifest.json') -Encoding UTF8
  Say "Snapshot saved: $(Split-Path $dir -Leaf) ($(Format-Bytes (Get-FolderBytes $dir)), $($saved.Count) system hives, $($users.Count) users)"
  $script:lastSnap = $dir
}

function Remove-OldSnapshots($d, [int]$keep) {
  $all = @(Get-ChildItem (Get-SnapRoot $d) -Directory -ErrorAction SilentlyContinue)
  $old  = @($all | Where-Object { $_.Name -match '^\d{4}-\d\d-\d\d_\d{6}$' } | Sort-Object Name -Descending | Select-Object -Skip $keep)
  $old += @($all | Where-Object { $_.Name -match '^(before-restore|from-restore-point)_' } | Sort-Object { $_.Name.Split('_', 2)[1] } -Descending | Select-Object -Skip 3)
  foreach ($o in $old) { Remove-Item $o.FullName -Recurse -Force -ErrorAction SilentlyContinue; Say "  removed old snapshot $($o.Name)" }
}

# Put one hive file in place. The old transaction logs belong to the newer hive and could be replayed onto the
# restored one, so they are removed (they are in the before-restore snapshot already).
function Set-HiveFile($srcFile, $dstDir, $name) {
  foreach ($l in '.LOG1', '.LOG2') {
    $p = Join-Path $dstDir "$name$l"
    if (Test-Path $p) { Remove-Item $p -Force }
  }
  Copy-Item $srcFile (Join-Path $dstDir $name) -Force
  foreach ($l in '.LOG1', '.LOG2') { if (Test-Path "$srcFile$l") { Copy-Item "$srcFile$l" (Join-Path $dstDir "$name$l") -Force } }
  Say "  put back $name"
}

# Put a snapshot-shaped folder back onto the offline Windows on $d, after saving the current state.
function Restore-Hives($src, $d, $label) {
  Assert-Offline $d
  Save-Snapshot $d "before $label" 'before-restore_'
  if (-not $script:lastSnap) { throw 'Could not save the current registry first, so nothing was changed.' }
  $script:lastUndo = $script:lastSnap
  $cfg = "$($d):\Windows\System32\config"
  foreach ($h in $SnapHives) { $f = Join-Path $src $h; if (Test-Path $f) { Set-HiveFile $f $cfg $h } }
  $m = Get-Content (Join-Path $src 'manifest.json') -Raw | ConvertFrom-Json
  foreach ($u in @($m.users)) {
    if (-not $u) { continue }
    $prof = "$($d):$($u.path)"
    if (-not (Test-Path $prof)) { Say "  skipped user $($u.path) (folder is gone)"; continue }
    $ud = Join-Path $src "users\$($u.sid)"
    if (Test-Path "$ud\NTUSER.DAT")   { Set-HiveFile "$ud\NTUSER.DAT" $prof 'NTUSER.DAT' }
    if (Test-Path "$ud\UsrClass.dat") { Set-HiveFile "$ud\UsrClass.dat" "$prof\AppData\Local\Microsoft\Windows" 'UsrClass.dat' }
  }
}

function Cmd-SnapMake {
  $d = Resolve-Drive
  Head "Violet snapshot of $($d):"
  Save-Snapshot $d 'made by hand'
  Remove-OldSnapshots $d $(if ($Option -match '^\d+$') { [int]$Option } else { 5 })
}

function Cmd-SnapList {
  $d = Resolve-Drive
  Head "Violet snapshots on $($d):"
  $snaps = @(Get-Snapshots $d)
  if (-not $snaps.Count) { Say 'None yet. Make one with snap-make, or rp-auto in Windows for one every day.' }
  foreach ($s in $snaps) {
    $m = Get-Content (Join-Path $s.FullName 'manifest.json') -Raw | ConvertFrom-Json
    Say ('SNAP|{0}|{1}|{2}|{3}|{4}' -f $s.Name, $m.made, $m.why, $m.build, (Format-Bytes (Get-FolderBytes $s.FullName)))
  }
  Say 'END'
}

function Cmd-SnapRestore {
  $d = Resolve-Drive
  Assert-Offline $d
  $snaps = @(Get-Snapshots $d)
  if (-not $snaps.Count) { throw "No Violet snapshots on $($d):." }
  $s = if ($Option) { $snaps | Where-Object { $_.Name -eq $Option.Trim() } | Select-Object -First 1 }
       else { $snaps | Where-Object { $_.Name -match '^\d{4}-' } | Select-Object -First 1 }
  if (-not $s) { throw "No snapshot called '$Option'. snap-list shows them." }
  $m = Get-Content (Join-Path $s.FullName 'manifest.json') -Raw | ConvertFrom-Json
  Head "Put back snapshot $($s.Name)  ($($m.why), Windows $($m.build))"
  $now = Get-WinBuild $d
  if ($m.build -and $m.build -ne '?' -and $now -ne $m.build) {
    Say "Windows is build $now now; the snapshot is from build $($m.build)."
    Say 'Remove the updates installed since then first (rollback or remove-update), then put the snapshot back.'
  }
  Say 'This puts the whole registry back, system and every user, as it was then. Programs and drivers installed'
  Say 'since then stay on disk but Windows forgets them (reinstall them). Passwords go back to what they were then.'
  if (-not (Confirm-Action 'Put this snapshot back?')) { Say 'Cancelled.'; return }
  Restore-Hives $s.FullName $d "snapshot $($s.Name)"
  Say ''
  Say "Done. Restart into Windows. To undo it: snap-restore -Option $(Split-Path $script:lastUndo -Leaf)"
}

# ---------------------------------------------------------------- Windows System Restore

$WriterServices = @{
  'System Writer' = 'CryptSvc'; 'WMI Writer' = 'Winmgmt'; 'BITS Writer' = 'BITS'; 'MSSearch Service Writer' = 'WSearch'
  'Registry Writer' = 'VSS'; 'COM+ REGDB Writer' = 'VSS'; 'Shadow Copy Optimization Writer' = 'VSS'; 'ASR Writer' = 'VSS'
}

function Get-BadWriters {
  $name = $null; $bad = @()
  foreach ($l in (& vssadmin.exe list writers 2>&1)) {
    if ($l -match "Writer name: '(.+)'") { $name = $Matches[1]; continue }
    $failed = ($l -match 'State: \[(\d+)\]' -and $Matches[1] -notin '1', '5') -or ($l -match 'Last error: (.+)' -and $Matches[1].Trim() -ne 'No error')
    if ($failed -and $name -and $bad -notcontains $name) { $bad += $name }
  }
  return , $bad
}

function Repair-Writers {
  $bad = Get-BadWriters
  if (-not $bad.Count) { Say '   all shadow copy writers OK'; return }
  Say "   failing: $($bad -join ', ')"
  foreach ($s in @($bad | ForEach-Object { if ($WriterServices[$_]) { $WriterServices[$_] } else { 'VSS' } } | Select-Object -Unique)) {
    Restart-Service $s -Force -ErrorAction SilentlyContinue; Say "   restarted $s"
  }
  $bad = Get-BadWriters
  if ($bad.Count) { Say "   still failing: $($bad -join ', '). Restarting Windows usually clears these; then run rp-fix again." }
  else { Say '   writers OK now' }
}

function New-WinRestorePoint($desc) {
  New-ItemProperty $SrKey -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force | Out-Null   # allow more than one a day
  $before = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue).Count
  try { Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS -ErrorAction Stop }
  catch { Say "   Windows restore point failed: $($_.Exception.Message)"; return }
  $after = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue).Count
  if ($after -gt $before) { Say '   Windows restore point made.' }
  else { Say '   Windows added no restore point (System Restore off, or no shadow storage). rp-fix repairs that.' }
}

# Opens the newest restore point and checks the registry is inside, which is what System Restore needs.
function Test-NewestShadow($d) {
  $script:shadowOk = $false
  $sh = Get-ShadowsFor $d
  if (-not $sh.ok -or -not $sh.list.Count) { Say '   no restore point to test'; return }
  $link = Join-Path $env:TEMP 'violet-shadow-test'
  New-ShadowLink $sh.list[0].DeviceObject $link
  try {
    $script:shadowOk = Test-Path "$link\Windows\System32\config\SOFTWARE"
    if ($script:shadowOk) { Say "   newest restore point ($($sh.list[0].InstallDate)) opens and holds the registry: usable." }
    else { Say '   newest restore point does not open: it is damaged.' }
  } finally { Remove-ShadowLink $link }
}

function Repair-RestorePoints($d, [int]$pct = 10) {
  Say '1. Services'
  foreach ($s in 'VSS', 'swprv') {
    Set-Service $s -StartupType Manual -ErrorAction SilentlyContinue
    Start-Service $s -ErrorAction SilentlyContinue
    Say "   $($s): $((Get-Service $s).Status)"
  }
  Say '2. Policies'
  $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'
  $p = Get-ItemProperty $pol -ErrorAction SilentlyContinue
  $hit = $false
  foreach ($v in 'DisableSR', 'DisableConfig') { if ($p.$v) { Remove-ItemProperty $pol $v; Say "   removed policy $v (a work PC may set it again)"; $hit = $true } }
  if (-not $hit) { Say '   none blocking' }
  Say "3. Switch System Restore on for $($d):"
  try { Enable-ComputerRestore -Drive "$($d):\" -ErrorAction Stop; Say '   on' } catch { Say "   failed: $($_.Exception.Message)" }
  Say "4. Space for restore points ($pct% of the drive)"
  $o = & vssadmin.exe resize shadowstorage "/for=$($d):" "/on=$($d):" "/maxsize=$pct%" 2>&1
  Say ('   ' + ((@($o) | Where-Object { "$_".Trim() } | Select-Object -Last 1)))
  Say '5. Shadow copy writers'
  Repair-Writers
  Say '6. Registry backup (RegBack), which Windows stopped making in 2018'
  New-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Configuration Manager' -Name EnablePeriodicBackup -Value 1 -PropertyType DWord -Force | Out-Null
  try { Start-ScheduledTask -TaskPath '\Microsoft\Windows\Registry\' -TaskName 'RegIdleBackup' -ErrorAction Stop; Say '   on, first backup started' }
  catch { Say '   on (Windows runs it when the PC is idle)' }
  Say '7. Make a restore point and test it'
  New-WinRestorePoint 'Violet Rescue repair'
  Test-NewestShadow $d
  Say ''
  if ($script:shadowOk) { Say 'System Restore works: a fresh restore point was made and opened.' }
  else { Say 'Restore points still do not work. rp-reset deletes the old, damaged ones and starts fresh.' }
}

function Cmd-RpCheck {
  $d = Resolve-Drive
  Head "Restore points for Windows on $($d):"
  $s = Get-SrSettings $d
  if ($s.PolicyOff) { Say 'System Restore: switched off by a policy (rp-fix removes it).' }
  elseif ($s.Off)   { Say 'System Restore: looks switched off.' }
  else              { Say 'System Restore: switched on.' }
  $sh = Get-ShadowsFor $d
  if (-not $sh.ok) { Say 'Restore points: this boot image cannot read them (no shadow copy service). A WinRE-based USB or Windows can.' }
  elseif (-not $sh.list.Count) { Say 'Restore points: none on this drive.' }
  else {
    Say "Restore points: $($sh.list.Count)"
    $i = 0; foreach ($x in $sh.list) { $i++; Say ('  [{0}] {1}' -f $i, $x.InstallDate) }
  }
  if (Test-LiveDrive $d) {
    foreach ($r in @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object SequenceNumber -Descending)) {
      Say ('  #{0}  {1}  {2}' -f $r.SequenceNumber, $r.ConvertToDateTime($r.CreationTime), $r.Description)
    }
    Test-NewestShadow $d
  }
  $rb = @(Get-ChildItem "$($d):\Windows\System32\config\RegBack" -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 })
  if ($rb.Count) { Say "Registry backup (RegBack): $($rb.Count) hives, last made $(($rb | Sort-Object LastWriteTime -Descending)[0].LastWriteTime)" }
  else { Say 'Registry backup (RegBack): empty (Windows stopped filling it in 2018; rp-fix switches it back on).' }
  $snaps = @(Get-Snapshots $d)
  if ($snaps.Count) { Say "Violet snapshots: $($snaps.Count), newest $($snaps[0].Name)" }
  else { Say 'Violet snapshots: none yet (snap-make, or rp-auto in Windows for one every day).' }
  Say ''
  Say 'If System Restore fails, from the rescue USB:'
  Say '  restore-safe        System Restore with the usual causes of 0x800700fe / 0x80070091 fixed first'
  Say '  rp-shadow-restore   the registry straight out of a restore point, without System Restore'
  Say '  snap-restore        a Violet snapshot, which needs no restore point at all'
}

function Cmd-RpFix {
  Assert-Live
  $d = $env:SystemDrive.TrimEnd(':')
  Head "Repair System Restore on $($d):"
  if (-not (Confirm-Action 'Switch System Restore on and repair what it needs?')) { Say 'Cancelled.'; return }
  Repair-RestorePoints $d $(if ($Option -match '^\d+$') { [int]$Option } else { 10 })
}

function Cmd-RpReset {
  Assert-Live
  $d = $env:SystemDrive.TrimEnd(':')
  Head "Start System Restore fresh on $($d):"
  Say 'This deletes every restore point on this drive (they are the damaged part), then switches System Restore'
  Say 'back on and makes a new one. A Violet snapshot of the registry is saved first.'
  if (-not (Confirm-Action 'Delete all restore points and start fresh?')) { Say 'Cancelled.'; return }
  Save-Snapshot $d 'before restore point reset'
  & vssadmin.exe delete shadows "/for=$($d):" /all /quiet
  Disable-ComputerRestore -Drive "$($d):\" -ErrorAction SilentlyContinue
  Repair-RestorePoints $d
}

function Cmd-RpMake {
  Assert-Live
  $d = $env:SystemDrive.TrimEnd(':')
  Head "Restore point and Violet snapshot of $($d):"
  New-WinRestorePoint 'Violet Rescue'
  Save-Snapshot $d 'automatic'
  Remove-OldSnapshots $d $(if ($Option -match '^\d+$') { [int]$Option } else { 5 })
}

function Cmd-RpAuto {
  Assert-Live
  $task = 'Violet Rescue restore points'
  if ($Option -eq 'off') { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue; Say 'Automatic restore points switched off.'; return }
  $keep = if ($Option -match '^\d+$') { [int]$Option } else { 5 }
  # The task must not depend on the USB, so it runs a copy of the app on the Windows drive.
  $app = $Root
  if (-not $Root.StartsWith($env:SystemDrive, [StringComparison]::OrdinalIgnoreCase)) {
    $app = "$env:SystemDrive\VioletRescue\app"
    & robocopy.exe $Root $app /E /NFL /NDL /NJH /NJS /NP | Out-Null
    Say "App copied to $app, so this keeps working without the USB."
  }
  $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$app\cli\rescue.ps1`" rp-make -Option $keep -Yes"
  $daily = New-ScheduledTaskTrigger -Daily -At '12:00'
  $boot  = New-ScheduledTaskTrigger -AtStartup; $boot.Delay = 'PT10M'
  $set   = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
  $who   = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $task -Action $act -Trigger $daily, $boot -Settings $set -Principal $who -Force | Out-Null
  Say "Set: every day at 12:00 (or as soon as the PC is on after that) and 10 minutes after each start,"
  Say "a Windows restore point plus a Violet snapshot. The newest $keep snapshots are kept (a few hundred MB each)."
  Say 'Making the first one now...'
  Cmd-RpMake
}

# ---------------------------------------------------------------- from the rescue USB

# System Restore with its usual failure causes fixed first:
#  0x800700fe (extended attributes inconsistent) is file-system damage that check disk repairs;
#  0x80070091 / 0x800700fe on Program Files\WindowsApps is the Store apps folder, which is moved aside.
function Cmd-RestoreSafe {
  $d = Resolve-Drive
  Assert-Offline $d
  $apps  = "$($d):\Program Files\WindowsApps"
  $moved = "$($d):\Program Files\WindowsApps.violet"
  $acl   = "$($d):\VioletRescue\WindowsApps.acl"
  if ($Option -eq 'undo') {
    if (-not (Test-Path $moved)) { Say 'Nothing to put back.'; return }
    if (Test-Path $apps) { Say "Both WindowsApps and WindowsApps.violet exist. Windows uses WindowsApps; delete WindowsApps.violet once Store apps work."; return }
    Rename-Item $moved 'WindowsApps'
    if (Test-Path $acl) { & icacls.exe "$($d):\Program Files" /restore $acl | Out-Null; Remove-Item $acl }
    Say 'WindowsApps put back.'
    return
  }
  $exe = Join-Path $env:SystemRoot 'System32\rstrui.exe'
  if (-not (Test-Path $exe)) { throw 'System Restore (rstrui.exe) is not in this boot image. Use rp-shadow-restore or snap-restore, or build the media from winre.wim.' }
  if (Test-Path $moved) { throw 'WindowsApps.violet is still there from an earlier run. Run restore-safe -Option undo first.' }
  Head "Safer System Restore on $($d):"
  Say 'Before System Restore opens, this:'
  Say '  1. saves a Violet snapshot of the registry, so it can be undone'
  Say '  2. runs check disk, which repairs the file damage behind 0x800700fe'
  Say '  3. moves the Store apps folder (WindowsApps) aside, the folder restores most often fail on'
  if (-not (Confirm-Action 'Go ahead?')) { Say 'Cancelled.'; return }
  Save-Snapshot $d 'before System Restore' 'before-restore_'
  if (-not $script:lastSnap) { throw 'Could not save the registry first, so nothing was changed.' }
  Head 'Check disk'
  & chkdsk.exe "$($d):" /f /x
  if (Test-Path $apps) {
    try { Rename-Item $apps 'WindowsApps.violet' -ErrorAction Stop }
    catch {
      # Keep the folder's permissions so they can be put back exactly.
      New-Item -ItemType Directory -Force (Split-Path $acl) | Out-Null
      & icacls.exe $apps /save $acl | Out-Null
      & takeown.exe /f $apps /a | Out-Null
      & icacls.exe $apps /grant 'Administrators:F' | Out-Null
      Rename-Item $apps 'WindowsApps.violet' -ErrorAction Stop
    }
    Say 'WindowsApps moved aside.'
  }
  Head 'System Restore'
  Say 'Pick a restore point in the window. When it finishes, or you close it, this carries on.'
  Start-Process $exe -ArgumentList "/offline:$($d):\Windows" -Wait
  if ((Test-Path $moved) -and -not (Test-Path $apps)) {
    Rename-Item $moved 'WindowsApps'
    if (Test-Path $acl) { & icacls.exe "$($d):\Program Files" /restore $acl | Out-Null; Remove-Item $acl }
    Say 'WindowsApps put back.'
  } elseif (Test-Path $moved) {
    Say 'The restore made a new WindowsApps. The old one is kept as WindowsApps.violet. If Store apps (Photos,'
    Say 'Calculator...) do not open after Windows starts, reinstall them from the Store, then delete WindowsApps.violet.'
  }
  Say ''
  Say 'If System Restore still failed: rp-shadow-restore puts the registry back from a restore point without it,'
  Say "and snap-restore -Option $(Split-Path $script:lastSnap -Leaf) undoes anything done here."
}

# Windows only starts if SYSTEM and SOFTWARE load. Try loading the copies BEFORE they replace the working ones,
# so a copy that is broken (as the live hive files taken from a shadow copy were) changes nothing.
function Assert-HivesLoad($dir) {
  foreach ($h in 'SYSTEM', 'SOFTWARE') {
    $ok = $false
    try { Use-Hive (Join-Path $dir $h) "CHK$h" { param($p) }; $ok = $true } catch { }
    if (-not $ok) {
      Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
      throw "The $h file from that restore point will not load, so Windows would not start with it. Nothing was changed. Try another number."
    }
    Say "  checked: $h loads"
  }
}

# Every restore point keeps a clean, consistent copy of each registry hive in its own folder
# (System Volume Information\_restore{id}\RPn\snapshot). System Restore itself puts those back. They are safer
# than the live hive files inside the shadow copy, which were captured while Windows was writing to them.
function Get-RpSnapshotSets($d) {
  $svi = "$($d):\System Volume Information"
  $sets = @()
  foreach ($r in @(Get-ChildItem -LiteralPath $svi -Directory -Force -Filter '_restore*' -ErrorAction SilentlyContinue)) {
    foreach ($p in @(Get-ChildItem -LiteralPath $r.FullName -Directory -Force -Filter 'RP*' -ErrorAction SilentlyContinue)) {
      $snap = Join-Path $p.FullName 'snapshot'
      $sys = Join-Path $snap '_REGISTRY_MACHINE_SYSTEM'
      if ((Test-Path -LiteralPath $sys) -and (Test-Path -LiteralPath (Join-Path $snap '_REGISTRY_MACHINE_SOFTWARE'))) {
        $n = 0; [void][int]::TryParse(($p.Name -replace '^RP', ''), [ref]$n)
        $sets += [pscustomobject]@{ Name = $p.Name; Dir = $snap; N = $n; When = (Get-Item -LiteralPath $sys -Force).LastWriteTime }
      }
    }
  }
  return @($sets | Sort-Object N -Descending)
}

# The registry straight out of a restore point, for when System Restore itself will not finish.
function Cmd-RpShadowRestore {
  $d = Resolve-Drive
  Assert-Offline $d
  $sets = @(Get-RpSnapshotSets $d)
  if ($sets.Count) {
    Head "Restore points with clean registry copies on $($d):"
    $k = 0; foreach ($x in $sets) { $k++; Say ('  [{0}] {1}   {2}' -f $k, $x.Name, $x.When) }
    $i = if ($Option -match '^\d+$') { [int]$Option } else { 1 }
    if ($i -lt 1 -or $i -gt $sets.Count) { throw "Pick 1 to $($sets.Count) (1 = newest)." }
    $s = $sets[$i - 1]
    Say ''
    Say "Using [$i] $($s.Name) from $($s.When). This is the same registry copy System Restore puts back,"
    Say 'without the WindowsApps step that fails. User settings and files stay as they are now.'
    if (-not (Confirm-Action 'Put it back?')) { Say 'Cancelled.'; return }
    $copy = Join-Path (Get-SnapRoot $d) ('from-restore-point_' + (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
    New-Item -ItemType Directory -Force $copy | Out-Null
    $map = [ordered]@{ SYSTEM = '_REGISTRY_MACHINE_SYSTEM'; SOFTWARE = '_REGISTRY_MACHINE_SOFTWARE'; SAM = '_REGISTRY_MACHINE_SAM'
                       SECURITY = '_REGISTRY_MACHINE_SECURITY'; DEFAULT = '_REGISTRY_USER_.DEFAULT'; COMPONENTS = '_REGISTRY_MACHINE_COMPONENTS' }
    foreach ($h in $map.Keys) {
      $f = Join-Path $s.Dir $map[$h]
      if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f (Join-Path $copy $h) -Force; Say "  read $h" }
      else { Say "  $h is not in this restore point, left as it is" }
    }
    Assert-HivesLoad $copy
    [pscustomobject]@{ made = $s.When.ToString('s'); why = "clean copy from restore point $($s.Name)"; build = '?'; hives = @($map.Keys); users = @() } |
      ConvertTo-Json | Set-Content (Join-Path $copy 'manifest.json') -Encoding UTF8
    Restore-Hives $copy $d "restore point $($s.Name)"
    Say ''
    Say "Done. Shut down, take the USB out, start Windows. To undo it: snap-restore -Option $(Split-Path $script:lastUndo -Leaf)"
    return
  }
  Say 'No clean registry copies in the restore point folders. Reading the hive files out of the shadow copy instead.'
  $sh = Get-ShadowsFor $d
  if (-not $sh.ok) { throw 'No restore point could be opened from this boot image (no shadow copy service, and none found by direct probe). Use snap-restore.' }
  if (-not $sh.list.Count) { throw "No restore points on $($d):." }
  $i = if ($Option -match '^\d+$') { [int]$Option } else { 1 }
  if ($i -lt 1 -or $i -gt $sh.list.Count) { throw "Pick 1 to $($sh.list.Count) (rp-check lists them, 1 = newest)." }
  $sc = $sh.list[$i - 1]
  # No symbolic link: the rescue drive X: cannot hold one ("The device does not support symbolic links").
  # cmd reads the shadow copy device path directly.
  $dev = $sc.DeviceObject
  $cfg = 'Windows\System32\config'
  if ((Invoke-ShadowBat @("if exist `"$dev\$cfg\SOFTWARE`" (exit /b 0) else (exit /b 1)")) -ne 0) { throw 'That restore point does not open (damaged). Try another number.' }
  Head "System registry from the restore point of $($sc.InstallDate)"
  Say 'This puts back the system registry from that restore point, the part System Restore fails on.'
  Say 'User settings and files stay as they are now. Passwords go back to what they were then.'
  if (-not (Confirm-Action 'Put it back?')) { Say 'Cancelled.'; return }
  $copy = Join-Path (Get-SnapRoot $d) ('from-restore-point_' + (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
  New-Item -ItemType Directory -Force $copy | Out-Null
  foreach ($h in $SnapHives) {
    foreach ($n in $h, "$h.LOG1", "$h.LOG2") {
      $rc = Invoke-ShadowBat @("copy /y `"$dev\$cfg\$n`" `"$copy\$n`" >nul 2>&1", 'exit /b %errorlevel%')
      if ($rc -ne 0 -and $n -eq $h) { throw "Could not read $h from that restore point. Nothing was changed. Try another number." }
    }
  }
  Assert-HivesLoad $copy
  [pscustomobject]@{ made = ([datetime]$sc.InstallDate).ToString('s'); why = 'copied from a Windows restore point'; build = '?'; hives = $SnapHives; users = @() } |
    ConvertTo-Json | Set-Content (Join-Path $copy 'manifest.json') -Encoding UTF8
  Restore-Hives $copy $d "restore point $i"
  Say ''
  Say "Done. Restart into Windows. To undo it: snap-restore -Option $(Split-Path $script:lastUndo -Leaf)"
}
