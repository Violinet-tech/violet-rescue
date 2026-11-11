# Violet Rescue - button front end for cli\rescue.ps1.
# Top: pick the Windows drive (and a target drive when a command needs one).
# Tabs: Repair, New Windows + files, NVIDIA drivers, Cable link, Agent help.
# Bottom: the terminal pane every command streams into.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Root = Split-Path -Parent $PSScriptRoot
$Cli  = Join-Path $Root 'cli\rescue.ps1'

# verb, button text, hint for the Option box, needs target, changes things
$RepairCommands = @(
  @('drives',                 'List drives',            '', $false, $false),
  @('updates',                'Scan updates',           '', $false, $false),
  @('remove-update',          'Remove update',          'Package name or KB. Empty = newest update.', $false, $true),
  @('revert-pending',         'Undo pending updates',   '', $false, $true),
  @('rollback',               'Rollback machine',       'Date it broke, like 2026-11-02', $false, $true),
  @('restore',                'System Restore',         '', $false, $true),
  @('sfc',                    'SFC scan',               '', $false, $false),
  @('chkdsk',                 'Check disk',             '', $false, $true),
  @('restorehealth',          'DISM repair',            'Optional: path to install.wim or .esd, add :index', $false, $true),
  @('bootfix',                'Fix boot files',         '', $false, $true),
  @('drivers',                'List drivers',           'Optional filter, like Realtek', $false, $false),
  @('remove-nvidia',          'Remove NVIDIA display',  'Type all to remove every NVIDIA driver', $false, $true),
  @('remove-driver',          'Remove driver',          'oemNN.inf, or Provider,Class like Realtek,Net', $false, $true),
  @('add-drivers',            'Install drivers',        'nvidia, realtek, amd-chipset, or a folder path', $false, $true),
  @('block-driver-updates',   'Block Windows drivers',  '', $false, $true),
  @('unblock-driver-updates', 'Allow Windows drivers',  '', $false, $true),
  @('malware-scan',           'Malware startup scan',   '', $false, $false),
  @('disable-startup',        'Disable startup item',   'Name from the malware scan', $false, $true),
  @('backup',                 'Backup files',           'Optional: other folder to copy. Default = all user folders.', $true, $false),
  @('net-up',                 'Start network',          '', $false, $false),
  @('update-db',              'Update database',        '', $false, $false)
)
$NoDriveNeeded = 'drives', 'update-db', 'net-up', 'nvidia-gpus', 'nvidia-driver', 'nvidia-versions', 'devconfig', 'cable-check', 'cable-link', 'migrate-restore', 'rp-fix', 'rp-reset', 'rp-auto', 'rp-make'

$script:winDrive = $null; $script:target = $null; $script:cmd = $null
$script:proc = $null; $script:onDone = $null; $script:fullOut = ''
$script:outFile = Join-Path $env:TEMP 'violet-rescue-out.txt'
$script:errFile = Join-Path $env:TEMP 'violet-rescue-err.txt'
$script:outPos = 0; $script:errPos = 0; $script:itemPaths = @()

$bg  = [Drawing.Color]::FromArgb(24, 24, 28)
$off = [Drawing.Color]::FromArgb(45, 45, 52)
$on  = [Drawing.Color]::FromArgb(130, 80, 200)
$go  = [Drawing.Color]::FromArgb(40, 140, 70)
$fg  = [Drawing.Color]::White

$form = New-Object Windows.Forms.Form
# Fit the window to the screen: a recovery environment often runs at a small resolution.
$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Text = 'Violet Rescue'; $form.Size = New-Object Drawing.Size([Math]::Min(1150, $wa.Width), [Math]::Min(880, $wa.Height)); $form.StartPosition = 'CenterScreen'
$form.WindowState = 'Maximized'
$script:labW = [Math]::Max(300, $wa.Width - 70)   # widest a label may be before it wraps
$form.BackColor = $bg; $form.ForeColor = $fg; $form.Font = New-Object Drawing.Font('Segoe UI', 10)

function New-Label($parent, $text, $x, $y, [bool]$bold = $true) {
  $l = New-Object Windows.Forms.Label
  $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y); $l.AutoSize = $true
  if ($parent -is [Windows.Forms.FlowLayoutPanel]) { $l.MaximumSize = New-Object Drawing.Size($script:labW, 0); $l.Margin = New-Object Windows.Forms.Padding(3, 10, 3, 4) }
  if ($bold) { $l.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold) } else { $l.ForeColor = [Drawing.Color]::Silver }
  $parent.Controls.Add($l); return $l
}
function New-Flow($parent, $x, $y, $w, $h) {
  $f = New-Object Windows.Forms.FlowLayoutPanel
  $f.Location = New-Object Drawing.Point($x, $y); $f.Size = New-Object Drawing.Size($w, $h)
  $f.AutoScroll = $true
  $parent.Controls.Add($f); return $f
}
function New-Btn($text, $tag, $w, $color = $null) {
  $b = New-Object Windows.Forms.Button
  $b.Text = $text; $b.Tag = $tag; $b.Size = New-Object Drawing.Size($w, 34)
  # Grow to fit the text, so a substitute font or a scaled display never clips a label.
  $b.AutoSize = $true; $b.AutoSizeMode = 'GrowOnly'; $b.MinimumSize = New-Object Drawing.Size($w, 34); $b.Padding = New-Object Windows.Forms.Padding(6, 0, 6, 0)
  $b.FlatStyle = 'Flat'; $b.BackColor = $(if ($color) { $color } else { $off }); $b.ForeColor = $fg
  return $b
}
function Place($parent, $ctl, $x, $y) { $ctl.Location = New-Object Drawing.Point($x, $y); $parent.Controls.Add($ctl); return $ctl }
function Select-In($panel, $btn) { foreach ($c in $panel.Controls) { $c.BackColor = $off }; $btn.BackColor = $on }
function New-Text($w) { $t = New-Object Windows.Forms.TextBox; $t.Size = New-Object Drawing.Size($w, 26); $t.BackColor = $off; $t.ForeColor = $fg; return $t }

# ---- layout: everything is docked (tabs fill the middle, the log sits at the bottom, drive rows at the top),
# so nothing falls off a small screen. Dock order: the control added first is laid out last (it gets the leftover space).
$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'; $tabs.Multiline = $true; $tabs.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$form.Controls.Add($tabs)
function New-Tab($name) {
  $t = New-Object Windows.Forms.TabPage; $t.Text = $name; $t.BackColor = $bg; $t.ForeColor = $fg; $t.AutoScroll = $true
  $t.Font = New-Object Drawing.Font('Segoe UI', 10); $tabs.TabPages.Add($t); return $t
}
$tFix = New-Tab 'FIX IT'; $tRepair = New-Tab 'Repair'; $tNew = New-Tab 'New Windows + files'; $tNv = New-Tab 'NVIDIA drivers'; $tCable = New-Tab 'Cable link'; $tAgent = New-Tab 'Agent help'; $tDev = New-Tab 'Set up this PC'; $tRp = New-Tab 'Restore points'

# ---- bottom: terminal (a third of the screen) with Stop / Refresh above it
$bottom = New-Object Windows.Forms.Panel
$bottom.Dock = 'Bottom'; $bottom.Height = [int][Math]::Max(180, $wa.Height * 0.33)
$term = New-Object Windows.Forms.TextBox
$term.Multiline = $true; $term.ReadOnly = $true; $term.ScrollBars = 'Both'; $term.WordWrap = $false
$term.Dock = 'Fill'; $term.BackColor = [Drawing.Color]::Black; $term.ForeColor = [Drawing.Color]::LightGreen
$term.Font = New-Object Drawing.Font('Consolas', 11)
$strip = New-Object Windows.Forms.Panel
$strip.Dock = 'Top'; $strip.Height = 44
$bottom.Controls.Add($term); $bottom.Controls.Add($strip)
$form.Controls.Add($bottom)
$stop = Place $strip (New-Btn 'Stop' 'stop' 90) 6 5
$stop.Enabled = $false
$refresh = Place $strip (New-Btn 'Refresh drives' 'refresh' 150) 106 5

# ---- top: the two drive rows (label on the left, buttons scroll sideways if there are many)
function New-Row($text) {
  $p = New-Object Windows.Forms.Panel; $p.Dock = 'Top'; $p.Height = 60
  $l = New-Object Windows.Forms.Label; $l.Dock = 'Left'; $l.Width = 270; $l.TextAlign = 'MiddleLeft'; $l.Text = $text
  $l.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
  $f = New-Object Windows.Forms.FlowLayoutPanel; $f.Dock = 'Fill'; $f.WrapContents = $false; $f.AutoScroll = $true
  $p.Controls.Add($f); $p.Controls.Add($l); $form.Controls.Add($p)
  return @($l, $f)
}
$rowT = New-Row '2. Target drive: auto'; $lblTgt = $rowT[0]; $tgtPanel = $rowT[1]
$rowW = New-Row '1. Windows drive: ...';  $lblWin = $rowW[0]; $winPanel = $rowW[1]
function Update-Labels {
  $lblWin.Text = '1. Windows drive: ' + $(if ($script:winDrive) { "$($script:winDrive):" } else { 'not found yet' })
  $lblTgt.Text = '2. Target drive: ' + $(if ($script:target) { "$($script:target):" } else { 'auto' })
}

function Write-Term($t) { if ($t) { $term.AppendText(($t -replace "(?<!`r)`n", "`r`n")) } }

function Read-New($path, $pos) {
  if (-not (Test-Path $path)) { return @('', $pos) }
  $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
  try { [void]$fs.Seek($pos, 'Begin'); $t = (New-Object IO.StreamReader($fs)).ReadToEnd(); return @($t, $fs.Position) } finally { $fs.Close() }
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
  # Note whether it had exited BEFORE reading: output written between the read and the exit check was lost,
  # which printed "[finished]" with no text for short commands.
  $wasDone = ($script:proc -and $script:proc.HasExited)
  $r = Read-New $script:outFile $script:outPos; Write-Term $r[0]; $script:fullOut += $r[0]; $script:outPos = $r[1]
  $r = Read-New $script:errFile $script:errPos; Write-Term $r[0]; $script:errPos = $r[1]
  if ($wasDone) {
    $timer.Stop()
    Write-Term ("`n[finished, exit code {0}]`n" -f $script:proc.ExitCode)
    $script:proc = $null; $stop.Enabled = $false
    if ($script:onDone) { $cb = $script:onDone; $script:onDone = $null; & $cb $script:fullOut }
  }
})

# No Windows drive picked: use the drive that holds Windows (the first one if there are several).
function Set-AutoWinDrive {
  foreach ($di in [IO.DriveInfo]::GetDrives()) {
    try {
      if (-not $di.IsReady) { continue }
      $L = $di.Name.Substring(0, 1)
      if ($L -eq 'X') { continue }
      if (Test-Path "$($L):\Windows\System32\config\SYSTEM") { $script:winDrive = $L; Write-Term "`nWindows drive chosen automatically: ${L}:`n"; Update-Labels; return }
    } catch { }
  }
}

# No target picked: choose the roomiest drive that is not the Windows drive and not this rescue stick.
function Set-AutoTarget {
  $best = $null
  foreach ($di in [IO.DriveInfo]::GetDrives()) {
    try {
      if (-not $di.IsReady) { continue }
      $L = $di.Name.Substring(0, 1)
      if ($L -eq 'X' -or $L -eq $script:winDrive) { continue }
      if (Test-Path "$($L):\sources\boot.wim") { continue }
      if ($di.DriveType -eq 'CDRom' -or $di.TotalSize -lt 10GB) { continue }
      if (-not $best -or $di.AvailableFreeSpace -gt $best.AvailableFreeSpace) { $best = $di }
    } catch { }
  }
  if ($best) { $script:target = $best.Name.Substring(0, 1); Update-Labels; Write-Term ("`nTarget drive chosen automatically: {0}: ({1:N0} GB free)`n" -f $script:target, ($best.AvailableFreeSpace / 1GB)) }
}

# Run one CLI command. $confirm = it changes things, ask first. $onDone gets the full output.
function Start-Rescue($verb, $option, [bool]$needsTarget, [bool]$confirm, $label, $onDone = $null) {
  if ($script:proc) { [Windows.Forms.MessageBox]::Show('A command is still running.') | Out-Null; return }
  if ($verb -notin $NoDriveNeeded -and -not $script:winDrive) { Set-AutoWinDrive }
  if ($verb -notin $NoDriveNeeded -and -not $script:winDrive) { [Windows.Forms.MessageBox]::Show('No Windows drive was found. Click Refresh drives and read the list in the log.') | Out-Null; return }
  if ($needsTarget -and -not $script:target) { Set-AutoTarget }
  if ($needsTarget -and -not $script:target) { [Windows.Forms.MessageBox]::Show('Pick a target drive first (second row).') | Out-Null; return }
  if ($confirm) {
    $msg = "Run '$label'"; if ($script:winDrive) { $msg += " on $($script:winDrive):" }; if ($needsTarget) { $msg += " -> $($script:target):" }
    if ($option) { $msg += "`nOption: $option" }
    if ([Windows.Forms.MessageBox]::Show("$msg ?", 'Confirm', 'YesNo', 'Warning') -ne 'Yes') { return }
  }
  $a = "-NoProfile -ExecutionPolicy Bypass -File `"$Cli`" $verb"
  if ($script:winDrive -and $verb -notin 'migrate-restore') { $a += " -Drive $($script:winDrive)" }
  if ($script:target -and $needsTarget) { $a += " -Target $($script:target)" }
  if ($option) { $a += ' -Option "' + ($option -replace '"', '') + '"' }
  $a += ' -Yes'
  Remove-Item $script:outFile, $script:errFile -ErrorAction SilentlyContinue
  $script:outPos = 0; $script:errPos = 0; $script:fullOut = ''; $script:onDone = $onDone
  Write-Term "`n> $verb $option`n"
  $script:proc = Start-Process powershell.exe -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput $script:outFile -RedirectStandardError $script:errFile
  [void]$script:proc.Handle
  $stop.Enabled = $true
  $timer.Start()
}

function Fill-Drives {
  $winPanel.Controls.Clear(); $tgtPanel.Controls.Clear(); $script:winDrive = $null; $script:target = $null
  $seen = @()
  try {
    foreach ($di in [IO.DriveInfo]::GetDrives()) {
      $L = $di.Name.Substring(0, 1)
      if (-not $di.IsReady) { $seen += "${L}: not ready"; continue }
      if ($L -eq 'X') { continue }
      $label = '{0}:  {1}  {2:N0} GB' -f $L, $di.VolumeLabel, ($di.TotalSize / 1GB)
      $isWin = Test-Path "$($L):\Windows\System32\config\SYSTEM"
      $seen += "$label$(if ($isWin) { '  (has Windows)' })"
      if ($isWin) {
        $b = New-Btn $label $L 200; $b.Add_Click({ $script:winDrive = $this.Tag; Select-In $winPanel $this; Update-Labels }); $winPanel.Controls.Add($b)
      }
      $t = New-Btn $label $L 200; $t.Add_Click({ $script:target = $this.Tag; Select-In $tgtPanel $this; Update-Labels }); $tgtPanel.Controls.Add($t)
    }
  } catch { $seen += "Could not read the drives: $($_.Exception.Message)" }
  Write-Term ("`nDrives found:`n  " + (($seen | ForEach-Object { $_ }) -join "`n  ") + "`n")
  if ($winPanel.Controls.Count -eq 0) {
    Write-Term "No drive with Windows on it was found. If the PC's disk is NVMe or RAID (Intel RST/VMD), it needs its driver: Repair tab, Install drivers.`n"
  }
  # Set it directly: PerformClick does nothing before the window is shown, which left the drive unchosen.
  if ($winPanel.Controls.Count -ge 1) { $script:winDrive = $winPanel.Controls[0].Tag; Select-In $winPanel $winPanel.Controls[0] }
  Update-Labels
}

# ---- FIX IT tab: big buttons for the usual order of repair, one click each
$fixPanel = New-Flow $tFix 0 0 100 100; $fixPanel.Dock = 'Fill'
$fixIntro = New-Label $fixPanel 'Go down the list. Green is the one to try first. Each one asks before it changes anything.' 0 0 $false
$fixPanel.SetFlowBreak($fixIntro, $true)
$fixDefs = @(
  @('1   Remove the bad update (try this first)', 'remove-bad-update', $false, $true),
  @('2   Undo pending updates',                   'revert-pending',    $false, $true),
  @('3   System Restore (go back in time)',       'restore',           $false, $true),
  @('4   Fix the boot files',                     'bootfix',           $false, $true),
  @('5   Copy my files to another drive',         'backup',            $true,  $false),
  @('6   Show the installed updates',             'updates',           $false, $false),
  @('7   Clear stuck update leftovers (last resort)', 'clear-pending', $false, $true)
)
foreach ($f in $fixDefs) {
  # two columns where the screen is wide enough, so all seven fit without scrolling
  $fw = [int][Math]::Min(500, ($script:labW - 40) / 2)
  $b = New-Btn $f[0] $f $fw
  $b.MinimumSize = New-Object Drawing.Size($fw, 58); $b.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
  if ($f[1] -eq 'remove-bad-update') { $b.BackColor = $go }
  $b.Add_Click({ $c = $this.Tag; Start-Rescue $c[1] '' $c[2] $c[3] $c[0].Substring(1).Trim() })
  $fixPanel.Controls.Add($b)
}

# ---- Repair tab: pick a command, then RUN
$cmdPanel = New-Flow $tRepair 0 0 100 100; $cmdPanel.Dock = 'Fill'
$repBot = New-Object Windows.Forms.Panel; $repBot.Dock = 'Bottom'; $repBot.Height = 84
$tRepair.Controls.Add($repBot)
$hint = New-Label $repBot 'Option (only some commands use it):' 8 6 $false
$hint.Size = New-Object Drawing.Size($script:labW, 22); $hint.AutoSize = $false
$optW = [int][Math]::Min(640, $script:labW - 170)
$opt = Place $repBot (New-Text $optW) 8 32
$run = Place $repBot (New-Btn 'RUN' 'run' 140 $go) ($optW + 20) 28
$run.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
foreach ($c in $RepairCommands) {
  $b = New-Btn $c[1] $c 172
  $b.Add_Click({ $script:cmd = $this.Tag; Select-In $cmdPanel $this; $hint.Text = if ($this.Tag[2]) { 'Option: ' + $this.Tag[2] } else { 'Option: (not used by this command)' } })
  $cmdPanel.Controls.Add($b)
}
$run.Add_Click({
  if (-not $script:cmd) { [Windows.Forms.MessageBox]::Show('Pick a command first.') | Out-Null; return }
  $c = $script:cmd; Start-Rescue $c[0] $opt.Text $c[3] $c[4] $c[1]
})

# ---- New Windows + files tab
New-Label $tNew 'Fresh Windows on a new partition (needs the Windows install USB plugged in)' 8 8 | Out-Null
New-Label $tNew 'Size to take from the Windows drive (GB):' 8 36 $false | Out-Null
$gb = Place $tNew (New-Object Windows.Forms.NumericUpDown) 290 34
$gb.Minimum = 60; $gb.Maximum = 2000; $gb.Value = 120; $gb.Width = 80
$mk = Place $tNew (New-Btn 'Make fresh Windows' 'mk' 190 $go) 390 30
$mk.Add_Click({
  if ($script:target -and [Windows.Forms.MessageBox]::Show("Install onto the target drive $($script:target): instead of shrinking? (Yes = erase $($script:target):, No = shrink the Windows drive)", 'Where', 'YesNo') -eq 'Yes') {
    Start-Rescue 'new-windows' '' $true $true 'Fresh Windows (erases target)'
  } else { Start-Rescue 'new-windows' ([string]$gb.Value) $false $true "Fresh Windows in $($gb.Value) GB" }
})
New-Label $tNew 'Move my files: tick folders, pick the target drive (usually the new Windows), Pack. Sign in there and open "Restore my files".' 8 76 $false | Out-Null
$list = Place $tNew (New-Object Windows.Forms.CheckedListBox) 8 100
$list.Size = New-Object Drawing.Size(830, 190); $list.BackColor = $off; $list.ForeColor = $fg; $list.CheckOnClick = $true
$load = Place $tNew (New-Btn 'Load folder list' 'load' 230) 850 100
$pack = Place $tNew (New-Btn 'Pack ticked into zip' 'pack' 230 $go) 850 140
$rest = Place $tNew (New-Btn 'Restore my files (new Windows)' 'rest' 230) 850 180
$all  = Place $tNew (New-Btn 'Tick all user folders' 'all' 230) 850 220
$load.Add_Click({
  $list.Items.Clear(); $script:itemPaths = @()
  Start-Rescue 'migrate-list' '' $false $false 'List folders' {
    param($out)
    foreach ($line in $out -split "`r?`n") {
      if ($line -notlike 'ITEM|*') { continue }
      $p = $line.Split('|'); $size = if ([long]$p[2] -ge 0) { '{0:N1} GB' -f ([long]$p[2] / 1GB) } else { '?' }
      $note = if ($p[3]) { "   ($($p[3]))" } else { '' }
      [void]$list.Items.Add(('{0,-9}  {1}{2}' -f $size, $p[1], $note))
      $script:itemPaths += $p[1]
    }
  }
})
$all.Add_Click({ for ($i = 0; $i -lt $list.Items.Count; $i++) { if ($list.Items[$i] -match '\\Users\\' -and $list.Items[$i] -notmatch 'AppData') { $list.SetItemChecked($i, $true) } } })
$pack.Add_Click({
  if ($list.CheckedItems.Count -eq 0) { [Windows.Forms.MessageBox]::Show('Tick at least one folder (Load folder list first).') | Out-Null; return }
  $sel = Join-Path $env:TEMP 'violet-rescue-selection.txt'
  $list.CheckedIndices | ForEach-Object { $script:itemPaths[$_] } | Set-Content $sel
  Start-Rescue 'migrate-pack' $sel $true $true "Pack $($list.CheckedItems.Count) folders into a zip"
})
$rest.Add_Click({ Start-Rescue 'migrate-restore' '' $false $true 'Restore my files' })

# ---- NVIDIA tab
$script:gpuKeys = @(); $script:verRows = @()
New-Label $tNv 'Drivers straight from NVIDIA, current and legacy cards (needs internet: Start network, or the cable link)' 8 8 | Out-Null
New-Label $tNv 'Card:' 8 40 $false | Out-Null
$gpu = Place $tNv (New-Object Windows.Forms.ComboBox) 60 36
$gpu.Width = 470; $gpu.DropDownStyle = 'DropDownList'; $gpu.BackColor = $off; $gpu.ForeColor = $fg; $gpu.MaxDropDownItems = 25
$loadGpu = Place $tNv (New-Btn 'Load card list' 'lg' 150) 540 32
$rbGame   = Place $tNv (New-Object Windows.Forms.RadioButton) 60 72;  $rbGame.Text = 'Game Ready'; $rbGame.AutoSize = $true; $rbGame.Checked = $true
$rbStudio = Place $tNv (New-Object Windows.Forms.RadioButton) 190 72; $rbStudio.Text = 'Studio'; $rbStudio.AutoSize = $true
$rbAll    = Place $tNv (New-Object Windows.Forms.RadioButton) 290 72; $rbAll.Text = 'All types'; $rbAll.AutoSize = $true
$dl      = Place $tNv (New-Btn 'Download newest' 'dl' 170 $go) 700 32
$listAll = Place $tNv (New-Btn 'List all versions' 'la' 170) 880 32
$vers = Place $tNv (New-Object Windows.Forms.ListBox) 8 104
$vers.Size = New-Object Drawing.Size(860, 180); $vers.BackColor = $off; $vers.ForeColor = $fg; $vers.Font = New-Object Drawing.Font('Consolas', 9)
$dlSel = Place $tNv (New-Btn 'Download selected' 'ds' 200 $go) 880 104
New-Label $tNv 'Saved to target\Drivers, or Downloads (X:\Drivers on the USB).' 880 146 $false | Out-Null
function Get-NvKind { if ($rbStudio.Checked) { 'studio' } elseif ($rbAll.Checked) { 'all' } else { 'game' } }
function Get-NvCard {
  if ($gpu.SelectedIndex -lt 0) { [Windows.Forms.MessageBox]::Show('Load the card list and pick your card.') | Out-Null; return $null }
  return $script:gpuKeys[$gpu.SelectedIndex]
}
$loadGpu.Add_Click({
  $gpu.Items.Clear(); $script:gpuKeys = @()
  Start-Rescue 'nvidia-gpus' '' $false $false 'Load NVIDIA cards' {
    param($out)
    $det = $null
    foreach ($line in $out -split "`r?`n") {
      if ($line -like 'DETECTED|*') { $det = $line.Substring(9) -replace '^NVIDIA ', '' }
      elseif ($line -like 'GPU|*') {
        $p = $line.Split('|')
        [void]$gpu.Items.Add(('{0}   ({1})' -f $p[3], $p[4])); $script:gpuKeys += "$($p[1]):$($p[2])"
      }
    }
    if ($det) {
      for ($i = 0; $i -lt $gpu.Items.Count; $i++) {
        $n = ($gpu.Items[$i] -replace '\s+\(.*\)$', '') -replace '^NVIDIA ', ''
        if ($n -eq $det -and $gpu.Items[$i] -notmatch 'Notebook|M Series') { $gpu.SelectedIndex = $i; break }
      }
    }
    if ($gpu.SelectedIndex -lt 0 -and $gpu.Items.Count) { $gpu.SelectedIndex = 0 }
  }
})
$dl.Add_Click({
  $card = Get-NvCard; if (-not $card) { return }
  $kind = Get-NvKind; if ($kind -eq 'all') { $kind = 'game' }
  Start-Rescue 'nvidia-driver' "$card|$kind" ([bool]$script:target) $false "Download newest $kind driver"
})
$listAll.Add_Click({
  $card = Get-NvCard; if (-not $card) { return }
  $vers.Items.Clear(); $script:verRows = @()
  Start-Rescue 'nvidia-versions' "$card|$(Get-NvKind)" $false $false 'List all driver versions' {
    param($out)
    foreach ($line in $out -split "`r?`n") {
      if ($line -notlike 'VER|*') { continue }
      $p = $line.Split('|')
      [void]$vers.Items.Add(('{0,-9} {1,-17} {2}' -f $p[1], $p[2], $p[3])); $script:verRows += , $p
    }
    if (-not $vers.Items.Count) { [void]$vers.Items.Add('No drivers listed for this card on Windows 10/11.') }
  }
})
$dlSel.Add_Click({
  if ($vers.SelectedIndex -lt 0 -or -not $script:verRows.Count) { [Windows.Forms.MessageBox]::Show('List all versions, then pick one.') | Out-Null; return }
  $card = Get-NvCard; if (-not $card) { return }
  $row = $script:verRows[$vers.SelectedIndex]
  Start-Rescue 'nvidia-driver' "$card|$($row[5])|$($row[1])" ([bool]$script:target) $false "Download driver $($row[1])"
})

# ---- Cable link tab
New-Label $tCable 'Ethernet cable straight into another, working PC' 8 8 | Out-Null
New-Label $tCable 'On the working PC run helper\RescueHelper.ps1 as administrator. It shows a 6-digit code. It can then send and get files, run these commands, share its internet, and run the agent.' 8 34 $false | Out-Null
$chk = Place $tCable (New-Btn 'Check cable' 'chk' 160) 8 70
New-Label $tCable 'Code:' 190 76 $false | Out-Null
$code = Place $tCable (New-Text 120) 240 72
$link = Place $tCable (New-Btn 'Link' 'link' 120 $go) 372 70
New-Label $tCable 'Received files go to the target drive\Received if one is picked, otherwise X:\Received. Press Stop to end the link.' 8 116 $false | Out-Null
$chk.Add_Click({ Start-Rescue 'cable-check' '' $false $false 'Check cable' })
$link.Add_Click({ if ($code.Text -notmatch '^\d{6}$') { [Windows.Forms.MessageBox]::Show('Type the 6-digit code from the helper PC.') | Out-Null; return }; Start-Rescue 'cable-link' $code.Text ([bool]$script:target) $false 'Cable link' })

# ---- Agent tab
New-Label $tAgent 'Codey and Warden (VNet setup hub agents), running in Claude Code' 8 8 | Out-Null
New-Label $tAgent 'They read a support bundle, run the look-only commands, and ask you before anything that changes the PC.' 8 34 $false | Out-Null
New-Label $tAgent 'From this rescue USB: link a helper PC on the Cable link tab, then choose 6 (Agent help) on the helper.' 8 58 $false | Out-Null
New-Label $tAgent 'In a working Windows with Claude Code installed: press Start agent here. Sign in with your own Claude account.' 8 82 $false | Out-Null
$bundle = Place $tAgent (New-Btn 'Make support bundle' 'b' 200) 8 116
$agentBtn = Place $tAgent (New-Btn 'Start agent' 'a' 160 $go) 220 116
$bundle.Add_Click({ Start-Rescue 'support-bundle' '' ([bool]$script:target) $false 'Support bundle' })
$agentBtn.Add_Click({ Start-Rescue 'agent' '' $false $false 'Agent' })

# ---- Set up this PC tab (Microsoft Windows Developer Config, run in the fresh Windows)
. (Join-Path $Root 'cli\modules\devconfig.ps1')
New-Label $tDev "Microsoft's Windows Developer Config: one click per setup (github.com/microsoft/WindowsDeveloperConfig)" 8 8 | Out-Null
New-Label $tDev 'Use it in the fresh Windows after signing in. Each script is downloaded from Microsoft, its signature checked, then run in its own window.' 8 34 $false | Out-Null
$flow = Place $tDev (New-Object Windows.Forms.ComboBox) 8 66
$flow.Width = 760; $flow.DropDownStyle = 'DropDownList'; $flow.BackColor = $off; $flow.ForeColor = $fg; $flow.MaxDropDownItems = 20
foreach ($f in $DevFlows) { [void]$flow.Items.Add($f[1]) }
$flow.SelectedIndex = 0
$devRun = Place $tDev (New-Btn 'Run setup' 'dev' 160 $go) 784 62
New-Label $tDev 'Full workstation setups turn on WSL and may restart the PC; they pick up where they left off. Local AI matches PyTorch to your GPU.' 8 104 $false | Out-Null
$devRun.Add_Click({ $f = $DevFlows[$flow.SelectedIndex]; Start-Rescue 'devconfig' $f[0] $false $true $f[1] })

# ---- Restore points tab
function Add-F($flow, $ctl, [bool]$brk = $false) { $flow.Controls.Add($ctl); if ($brk) { $flow.SetFlowBreak($ctl, $true) }; return $ctl }
$rpFlow = New-Flow $tRp 0 0 100 100; $rpFlow.Dock = 'Fill'
# The USB section comes first: it is the one needed when Windows will not start.
$l1 = New-Label $rpFlow 'From this USB, when Windows will not start or System Restore fails:' 0 0; $rpFlow.SetFlowBreak($l1, $true)
$rpSafe   = Add-F $rpFlow (New-Btn 'Safer System Restore' 'rps' 200 $go)
$rpShadow = Add-F $rpFlow (New-Btn 'Registry from restore point no.' 'rpsh' 250)
$rpNum    = Add-F $rpFlow (New-Object Windows.Forms.NumericUpDown)
$rpNum.Minimum = 1; $rpNum.Maximum = 64; $rpNum.Value = 1; $rpNum.Width = 60; $rpNum.Margin = New-Object Windows.Forms.Padding(3, 8, 12, 3)
$rpUndo   = Add-F $rpFlow (New-Btn 'Put WindowsApps back' 'rpu' 200) $true
$l2 = New-Label $rpFlow 'Violet snapshots (work without System Restore):' 0 0; $rpFlow.SetFlowBreak($l2, $true)
$snaps    = Add-F $rpFlow (New-Object Windows.Forms.ListBox) $true
$snaps.Size = New-Object Drawing.Size([int][Math]::Min(830, $script:labW - 20), 110); $snaps.BackColor = $off; $snaps.ForeColor = $fg; $snaps.Font = New-Object Drawing.Font('Consolas', 10)
$snapList = Add-F $rpFlow (New-Btn 'List snapshots' 'sl' 190)
$snapMake = Add-F $rpFlow (New-Btn 'Make snapshot now' 'sm' 190)
$snapBack = Add-F $rpFlow (New-Btn 'Put selected back (USB)' 'sb' 230 $go) $true
$l3 = New-Label $rpFlow 'In Windows: make System Restore work, and keep a Violet snapshot of the registry every day' 0 0; $rpFlow.SetFlowBreak($l3, $true)
$rpCheck = Add-F $rpFlow (New-Btn 'Check restore points' 'rpc' 190)
$rpFix   = Add-F $rpFlow (New-Btn 'Fix System Restore' 'rpf' 180 $go)
$rpReset = Add-F $rpFlow (New-Btn 'Start fresh' 'rpr' 130)
$rpAuto  = Add-F $rpFlow (New-Btn 'Automatic daily' 'rpa' 160 $go)
$rpMake  = Add-F $rpFlow (New-Btn 'Make one now' 'rpm' 140)
$script:snapNames = @()
$rpCheck.Add_Click({ Start-Rescue 'rp-check' '' $false $false 'Check restore points' })
$rpFix.Add_Click({ Start-Rescue 'rp-fix' '' $false $true 'Fix System Restore' })
$rpReset.Add_Click({ Start-Rescue 'rp-reset' '' $false $true 'DELETE all restore points and start fresh' })
$rpAuto.Add_Click({ Start-Rescue 'rp-auto' '5' $false $true 'Daily restore point + snapshot, keep 5' })
$rpMake.Add_Click({ Start-Rescue 'rp-make' '' $false $false 'Restore point + snapshot now' })
$rpSafe.Add_Click({ Start-Rescue 'restore-safe' '' $false $true 'Safer System Restore' })
$rpShadow.Add_Click({ Start-Rescue 'rp-shadow-restore' ([string]$rpNum.Value) $false $true "Registry from restore point $($rpNum.Value)" })
$rpUndo.Add_Click({ Start-Rescue 'restore-safe' 'undo' $false $true 'Put WindowsApps back' })
$snapList.Add_Click({
  $snaps.Items.Clear(); $script:snapNames = @()
  Start-Rescue 'snap-list' '' $false $false 'List snapshots' {
    param($out)
    foreach ($line in $out -split "`r?`n") {
      if ($line -notlike 'SNAP|*') { continue }
      $p = $line.Split('|')
      [void]$snaps.Items.Add(('{0,-36} {1,-24} {2,-16} {3}' -f $p[1], $p[3], $p[4], $p[5])); $script:snapNames += $p[1]
    }
    if (-not $snaps.Items.Count) { [void]$snaps.Items.Add('No snapshots yet.') }
  }
})
$snapMake.Add_Click({ Start-Rescue 'snap-make' '' $false $false 'Snapshot' })
$snapBack.Add_Click({
  if ($snaps.SelectedIndex -lt 0 -or -not $script:snapNames.Count) { [Windows.Forms.MessageBox]::Show('List snapshots, then pick one.') | Out-Null; return }
  $n = $script:snapNames[$snaps.SelectedIndex]
  Start-Rescue 'snap-restore' $n $false $true "Put snapshot $n back"
})

$stop.Add_Click({ if ($script:proc -and -not $script:proc.HasExited) { $script:proc.Kill(); Write-Term "`n[stopped]`n" } })
$refresh.Add_Click({ Fill-Drives })

Fill-Drives
Write-Term "Violet Rescue. Pick the Windows drive at the top, then a tab and a button.`n"
[void]$form.ShowDialog()
