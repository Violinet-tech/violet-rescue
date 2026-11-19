# Fix Everything: the whole repair chain in one run, for a Windows that will not start.
# Dot-sourced by rescue.ps1. Needs restorepoints.ps1 (Save-Snapshot, Restore-Hives, Cmd-RestoreSafe) loaded first.
#
#   rescue.ps1 fix-everything -Drive C [-Option no-restore] -Yes
#
# In order. When a step fails the run goes on to the next one, and the summary says which failed.
#   1. Snapshot the current state: every registry hive (Save-Snapshot) and the boot configuration (BCD).
#   2. Rebuild the boot files with bcdboot. bootrec is used for BIOS/MBR disks (/fixmbr, /fixboot), and as a
#      last resort (/rebuildbcd) when bcdboot makes no BCD. bootrec /scanos then checks the result (read only).
#   3. DISM repair (needs Windows install media: install.wim or install.esd), then SFC, both offline.
#      DISM goes first because SFC takes its good copies from the component store DISM repairs.
#   4. Asked first when a person runs it at a keyboard (the GUIs ask in their own dialog and run it as a second
#      call with Option restore-only). System Restore (the restore-safe route; a window opens and the user picks the point). If it could not
#      run, or left the registry as it was, the newest good Violet snapshot is put back instead.
#      "Good" = made inside a working Windows, same Windows build, and its SYSTEM and SOFTWARE files load.
#
# Nothing here deletes user files. Option no-restore stops after step 3; Option restore-only runs step 4 alone.
# The registry can be put back to how it was before step 1 with: snap-restore -Option <snapshot named at the end>.

$script:fx = @(); $script:fxSnap = $null; $script:fxBcdSaved = $false
$script:fxPick = $null; $script:fxWhy = @(); $script:fxLoadOk = $false

function Add-FxResult([int]$n, [string]$name, [string]$status, [string]$note) {
  $script:fx += [pscustomobject]@{ N = $n; Name = $name; Status = $status; Note = $note }
  Say ('  -> {0}: {1}' -f $status.ToUpper(), $note)
}

function Show-FxSummary([string]$title) {
  Head $title
  foreach ($r in $script:fx) { Say ('  {0}. {1,-20} {2,-8} {3}' -f $r.N, $r.Name, $r.Status.ToUpper(), $r.Note) }
}

# The partition that holds the boot files: the EFI System partition on a GPT disk, the active partition on MBR.
# Gets a temporary drive letter when it has none (closed again by Close-FxBootTarget).
function Get-FxBootTarget($d) {
  $part  = Get-Partition -DriveLetter $d -ErrorAction Stop
  $style = (Get-Disk -Number $part.DiskNumber -ErrorAction Stop).PartitionStyle
  if ($style -eq 'GPT') {
    $p = Get-Partition -DiskNumber $part.DiskNumber | Where-Object { $_.GptType -eq $EspGuid } | Select-Object -First 1
    if (-not $p) { throw "No EFI System partition on disk $($part.DiskNumber)." }
    $kind = 'UEFI'
  } else {
    $p = Get-Partition -DiskNumber $part.DiskNumber | Where-Object { $_.IsActive } | Select-Object -First 1
    if (-not $p) { throw "No active boot partition on disk $($part.DiskNumber)." }
    $kind = 'BIOS'
  }
  $L = "$($p.DriveLetter)"; $assigned = $false
  if (-not $L -or $L -eq "`0") {
    $free = $null
    foreach ($c in 'S', 'T', 'U', 'V', 'W', 'Y', 'Z') { if (-not $free -and -not (Test-Path "$($c):\")) { $free = $c } }
    if (-not $free) { throw 'No free drive letter to open the boot partition.' }
    $p | Set-Partition -NewDriveLetter $free -ErrorAction Stop
    $L = "$free"; $assigned = $true
  }
  $bcd = if ($kind -eq 'UEFI') { "$($L):\EFI\Microsoft\Boot\BCD" } else { "$($L):\Boot\BCD" }
  [pscustomobject]@{ Kind = $kind; Letter = $L; Assigned = $assigned; Disk = $p.DiskNumber; Part = $p.PartitionNumber; Bcd = $bcd }
}

function Close-FxBootTarget($bt) {
  if ($bt -and $bt.Assigned) {
    Remove-PartitionAccessPath -DiskNumber $bt.Disk -PartitionNumber $bt.Part -AccessPath "$($bt.Letter):\" -ErrorAction SilentlyContinue
  }
}

function Save-FxBcd($bt, $snapDir) {
  $script:fxBcdSaved = $false
  if (-not (Test-Path -LiteralPath $bt.Bcd)) { Say "  no BCD at $($bt.Bcd), so there is nothing to save (step 2 makes a new one)"; return }
  $dst = Join-Path $snapDir 'bcd'
  New-Item -ItemType Directory -Force $dst | Out-Null
  foreach ($n in 'BCD', 'BCD.LOG', 'BCD.LOG1', 'BCD.LOG2') {
    $f = Join-Path (Split-Path $bt.Bcd) $n
    if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f $dst -Force -ErrorAction SilentlyContinue }
  }
  if (Test-Path -LiteralPath (Join-Path $dst 'BCD')) { Say "  boot configuration (BCD) saved to $dst"; $script:fxBcdSaved = $true }
  else { Say '  could not copy the BCD' }
}

function Invoke-FxBoot($d, $bt) {
  $L = $bt.Letter
  $bootrec = [bool](Get-Command bootrec.exe -ErrorAction SilentlyContinue)
  if ($bt.Kind -eq 'UEFI') {
    $fs = (Get-Volume -DriveLetter $L -ErrorAction Stop).FileSystem
    if ($fs -ne 'FAT32') {
      Add-FxResult 2 'Boot files' 'skipped' "the EFI partition is $fs, not FAT32. Use Fix the boot files; it offers to format it."
      return
    }
  } elseif ($bootrec) {
    Say 'bootrec /fixmbr';  & bootrec.exe /fixmbr
    Say 'bootrec /fixboot'; & bootrec.exe /fixboot
  } else { Say 'bootrec.exe is not in this boot image, so /fixmbr and /fixboot are skipped.' }
  $bcd = $bt.Bcd
  if (Test-Path -LiteralPath $bcd) {
    attrib -s -h -r $bcd
    # Never overwrite an earlier backup: the first one is the original, untouched boot file.
    $bak = "$bcd.bak"; $n = 1
    while (Test-Path -LiteralPath $bak) { $n++; $bak = "$bcd.bak$n" }
    Copy-Item -LiteralPath $bcd $bak -Force
    Remove-Item -LiteralPath $bcd -Force
    Say ('Old BCD saved as {0}.' -f (Split-Path $bak -Leaf))
  }
  $fw = if ($bt.Kind -eq 'UEFI') { 'UEFI' } else { 'BIOS' }
  & bcdboot.exe "$($d):\Windows" /s "$($L):" /f $fw
  $how = 'bcdboot'
  if (-not (Test-Path -LiteralPath $bcd) -and $bootrec) {
    Say 'bcdboot made no BCD. Trying bootrec /rebuildbcd.'
    'A' | & bootrec.exe /rebuildbcd
    $how = 'bootrec /rebuildbcd'
  }
  if (Test-Path -LiteralPath $bcd) {
    & bcdedit.exe /store $bcd /enum '{default}'
    if ($bootrec) { Say 'bootrec /scanos (read only check):'; & bootrec.exe /scanos }
    Add-FxResult 2 'Boot files' 'ok' "rebuilt with $how ($($bt.Kind), $($L):)"
  } else { Add-FxResult 2 'Boot files' 'failed' 'no BCD was created' }
}

# What sfc said, in the words it uses. Anything else is reported as unclear rather than guessed.
function Get-FxSfcVerdict($lines) {
  $t = (@($lines) -join ' ')
  if     ($t -match 'did not find any integrity violations')        { $s = 'ok';     $n = 'no damaged system files' }
  elseif ($t -match 'successfully repaired')                        { $s = 'ok';     $n = 'damaged system files were repaired' }
  elseif ($t -match 'unable to fix')                                { $s = 'failed'; $n = 'damaged files it could not fix (details in Windows\Logs\CBS\CBS.log on the Windows drive)' }
  elseif ($t -match 'could not perform the requested operation|could not start the repair service|repair pending') { $s = 'failed'; $n = 'sfc could not run offline (a pending repair, or the repair service). Run Undo pending updates first.' }
  else                                                              { $s = 'failed'; $n = 'unclear result, read the sfc lines above' }
  [pscustomobject]@{ Status = $s; Note = $n }
}

# Size and write time of SYSTEM and SOFTWARE. A restore that took effect replaces both files.
function Get-FxHiveStamp($d) {
  (@('SYSTEM', 'SOFTWARE') | ForEach-Object {
    $f = Get-Item -LiteralPath "$($d):\Windows\System32\config\$_" -Force
    '{0}:{1}:{2}' -f $_, $f.Length, $f.LastWriteTimeUtc.Ticks
  }) -join '|'
}

# Loads copies of SYSTEM and SOFTWARE (loading a hive can change the file, so never the snapshot itself).
# Sets $script:fxLoadOk.
function Test-FxSnapshotLoads($src, $d) {
  $script:fxLoadOk = $false
  $tmp = "$($d):\VioletRescue\check-tmp"
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force $tmp | Out-Null
  $ok = $true
  try {
    foreach ($h in 'SYSTEM', 'SOFTWARE') {
      if (-not (Test-Path -LiteralPath (Join-Path $src $h))) { $ok = $false; continue }
      foreach ($n in $h, "$h.LOG1", "$h.LOG2") {
        if (Test-Path -LiteralPath (Join-Path $src $n)) { Copy-Item -LiteralPath (Join-Path $src $n) $tmp -Force }
      }
      try { Use-Hive (Join-Path $tmp $h) "FX$h" { param($p) } } catch { $ok = $false }
    }
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  $script:fxLoadOk = $ok
}

# Newest good snapshot into $script:fxPick; the reasons the others were passed over into $script:fxWhy.
function Select-FxSnapshot($d) {
  $script:fxPick = $null; $script:fxWhy = @()
  $now = $null
  try { $now = Get-WinBuild $d } catch { }
  foreach ($s in @(Get-Snapshots $d)) {
    if ($s.Name -notmatch '^\d{4}-\d\d-\d\d_\d{6}$') { continue }   # not the before-restore and from-restore-point copies
    $m = Get-Content (Join-Path $s.FullName 'manifest.json') -Raw | ConvertFrom-Json
    if (-not $m.live) { $script:fxWhy += "$($s.Name): made from the USB, not inside a working Windows"; continue }
    if ($now -and $m.build -and $m.build -ne '?' -and $m.build -ne $now) { $script:fxWhy += "$($s.Name): Windows build $($m.build), this one is $now"; continue }
    Test-FxSnapshotLoads $s.FullName $d
    if (-not $script:fxLoadOk) { $script:fxWhy += "$($s.Name): its registry files do not load"; continue }
    $script:fxPick = $s
    return
  }
}

function Cmd-FixEverything {
  $d = Resolve-Drive
  Assert-Offline $d
  $skipRestore = ($Option -match 'no-restore')
  $onlyRestore = ($Option -match 'restore-only')   # step 4 alone: the GUI runs it after the user says yes
  $Option = ''   # the steps below read Option too (DISM takes it as a media path)
  $script:fx = @(); $script:fxSnap = $null; $script:fxBcdSaved = $false
  $bt = $null; $btErr = $null
  Head "Fix Everything on $($d):"
  if ($onlyRestore) { Say 'Step 4 only: System Restore, then the newest good snapshot.' }
  elseif ($skipRestore) { Say 'Steps 1 to 3: snapshot, boot files, DISM and SFC. System Restore is left for you to start next.' }
  else { Say 'In order: 1 snapshot, 2 boot files, 3 DISM and SFC, 4 System Restore, then the newest good snapshot.' }
  Say 'The registry and the boot configuration are saved first. User files are not touched. This can take 30 minutes or more.'
  if (-not (Confirm-Action 'Go ahead?')) { Say 'Cancelled.'; return }
  # Asked once, here: the steps called below must not ask again. A person at the keyboard (no -Yes) is still
  # asked before step 4, which is the one that goes back in time.
  $askBefore4 = -not $Yes
  $Yes = [switch]$true
  try {
   if (-not $onlyRestore) {
    # ---- 1
    Head '1 of 4: Snapshot the current state'
    Save-Snapshot $d 'before Fix Everything' 'before-restore_'
    if (-not $script:lastSnap) { throw 'The registry could not be saved, so nothing was changed.' }
    $script:fxSnap = $script:lastSnap
    try { $bt = Get-FxBootTarget $d } catch { $btErr = $_.Exception.Message }
    if ($bt) { Save-FxBcd $bt $script:fxSnap } else { Say "  boot configuration not saved: $btErr" }
    Add-FxResult 1 'Snapshot' 'ok' ('registry' + $(if ($script:fxBcdSaved) { ' and BCD' } else { ' only (BCD not saved)' }) + ' in ' + (Split-Path $script:fxSnap -Leaf))

    # ---- 2
    Head '2 of 4: Rebuild the boot files'
    if (-not $bt) { Add-FxResult 2 'Boot files' 'failed' $btErr }
    else { try { Invoke-FxBoot $d $bt } catch { Add-FxResult 2 'Boot files' 'failed' $_.Exception.Message } }

    # ---- 3
    Head '3 of 4: DISM and SFC repair (several minutes each)'
    $global:LASTEXITCODE = $null
    try {
      Cmd-RestoreHealth
      $code = $global:LASTEXITCODE
      if ($code -eq 0) { Add-FxResult 3 'DISM repair' 'ok' 'component store checked and repaired' }
      else { Add-FxResult 3 'DISM repair' 'failed' "dism exit code $code. The media may be a different Windows build than the installed one." }
    } catch {
      if ($_.Exception.Message -match 'No install\.wim') { Add-FxResult 3 'DISM repair' 'skipped' 'no Windows install media (install.wim or install.esd). Plug it in and run DISM repair.' }
      else { Add-FxResult 3 'DISM repair' 'failed' $_.Exception.Message }
    }
    try {
      $sfcOut = @()
      Cmd-Sfc | Tee-Object -Variable sfcOut
      $v = Get-FxSfcVerdict $sfcOut
      Add-FxResult 3 'SFC scan' $v.Status $v.Note
    } catch { Add-FxResult 3 'SFC scan' 'failed' $_.Exception.Message }
   }

    # ---- 4
    if (-not $skipRestore -and $askBefore4 -and -not $onlyRestore) {
      Say ''
      if (-not (Confirm-Action 'Steps 1 to 3 are done. Go on to step 4, System Restore and then the newest good snapshot?')) { $skipRestore = $true }
    }
    Head '4 of 4: System Restore, then the newest good snapshot'
    if ($skipRestore) {
      Add-FxResult 4 'System Restore' 'skipped' 'not started; run Fix Everything again with restore-only, or System Restore by itself'
      Add-FxResult 4 'Registry snapshot' 'skipped' 'not started'
    } else {
      # System Restore normally restarts the PC when it finishes, which ends this run before the final summary.
      Show-FxSummary 'So far (if the PC restarts after System Restore, it worked)'
      $stamp = Get-FxHiveStamp $d
      $restoreErr = $null
      Say ''
      Say 'Opening System Restore. Pick a restore point in its window.'
      try { Cmd-RestoreSafe } catch { $restoreErr = $_.Exception.Message; Say "System Restore could not run: $restoreErr" }
      if (-not $script:fxSnap -and $script:lastSnap) { $script:fxSnap = $script:lastSnap }   # restore-only: its own before-restore copy is the undo point
      if (-not $restoreErr -and (Get-FxHiveStamp $d) -ne $stamp) {
        Add-FxResult 4 'System Restore' 'ok' 'the registry was replaced by the restore point'
        Add-FxResult 4 'Registry snapshot' 'skipped' 'not needed'
      } else {
        Add-FxResult 4 'System Restore' 'failed' $(if ($restoreErr) { $restoreErr } else { 'it closed without changing the registry (cancelled, or it failed)' })
        Say ''
        Say 'Falling back to the newest good Violet snapshot.'
        Select-FxSnapshot $d
        if (-not $script:fxPick) {
          foreach ($w in $script:fxWhy) { Say "  passed over $w" }
          Add-FxResult 4 'Registry snapshot' 'skipped' 'no usable snapshot (needs one made inside a working Windows, same build, that loads). Try rp-shadow-restore.'
        } else {
          $s = $script:fxPick
          Say "Using snapshot $($s.Name)."
          try { Restore-Hives $s.FullName $d "snapshot $($s.Name) (Fix Everything)"; Add-FxResult 4 'Registry snapshot' 'ok' "put back $($s.Name)" }
          catch { Add-FxResult 4 'Registry snapshot' 'failed' $_.Exception.Message }
        }
      }
    }
  } finally { Close-FxBootTarget $bt }
  Show-FxSummary 'Fix Everything: what happened'
  Say ''
  Say 'Next: shut down, take the USB stick out, start Windows.'
  if ($script:fxSnap) { Say "Undo the registry changes: snap-restore -Option $(Split-Path $script:fxSnap -Leaf)   (saved before anything changed)" }
  if ($script:fxBcdSaved) { Say "The old boot configuration is in $($script:fxSnap)\bcd. A BCD.bak also sits next to the new BCD on the boot partition." }
}
