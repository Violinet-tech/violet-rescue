# Move files from the old Windows into one zip on another drive, then put them back in place.
# Dot-sourced by rescue.ps1.
#   migrate-list    -Drive C                       every folder that can be moved, with sizes (ITEM| lines for the app)
#   migrate-pack    -Drive C -Target N -Option <file with one folder per line, or empty for the usual user folders>
#   migrate-restore [-Option <path to VioletMigrate.zip>]   run in the NEW Windows after signing in
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$SkipRoot = @('Windows', 'Users', '$Recycle.Bin', 'System Volume Information', 'Recovery', '$WinREAgent', 'Config.Msi',
  'PerfLogs', 'RescueScratch', 'Documents and Settings', 'MSOCache', '$SysReset', '$Windows.~BT', '$Windows.~WS',
  'VioletMigrate', 'VioletRescue', 'OneDriveTemp')
$SkipUsers = @('Default', 'Default User', 'All Users')
$UsualFolders = @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos', 'Favorites', 'Saved Games', 'Contacts', 'Links')
$AppNote = 'files only: programs need reinstalling'

function Get-MigrateItems($d, [bool]$withSize) {
  $items = @()
  foreach ($u in Get-ChildItem "$($d):\Users" -Directory -Force -ErrorAction SilentlyContinue) {
    if ($u.Name -in $SkipUsers -or ($u.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
    foreach ($f in Get-ChildItem $u.FullName -Directory -Force -ErrorAction SilentlyContinue) {
      if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
      if ($f.Name -eq 'AppData') {
        foreach ($a in 'Roaming', 'Local', 'LocalLow') {
          $p = Join-Path $f.FullName $a
          if (Test-Path $p) { $items += [pscustomobject]@{ Path = $p; User = $u.Name; Rel = "AppData\$a"; Note = 'app settings' } }
        }
      } else {
        $items += [pscustomobject]@{ Path = $f.FullName; User = $u.Name; Rel = $f.Name; Note = '' }
      }
    }
  }
  foreach ($f in Get-ChildItem "$($d):\" -Directory -Force -ErrorAction SilentlyContinue) {
    if ($f.Name -in $SkipRoot -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
    $note = if ($f.Name -match '^Program(Data| Files)') { $AppNote } else { '' }
    $items += [pscustomobject]@{ Path = $f.FullName; User = ''; Rel = $f.Name; Note = $note }
  }
  if ($withSize) { foreach ($i in $items) { $i | Add-Member Bytes (Get-FolderBytes $i.Path) } }
  return $items
}

function Cmd-MigrateList {
  $d = Resolve-Drive
  Head "Folders on $($d): that can be moved (sizing them can take a few minutes)"
  foreach ($i in Get-MigrateItems $d ($Option -ne 'nosize')) {
    $b = if ($null -ne $i.Bytes) { $i.Bytes } else { -1 }
    Say ("ITEM|{0}|{1}|{2}" -f $i.Path, $b, $i.Note)
  }
  Say 'END'
}

function Cmd-MigratePack {
  $d = Resolve-Drive
  $t = Resolve-Target
  if ($t -eq $d) { throw 'Target is the same drive. Pick the new Windows partition or another drive.' }
  $all = Get-MigrateItems $d $false
  if ($Option -and (Test-Path $Option)) {
    $want = Get-Content $Option | Where-Object { $_.Trim() }
    $sel = @($all | Where-Object { $_.Path -in $want })
  } else {
    $sel = @($all | Where-Object { $_.User -and $_.Rel -in $UsualFolders })
  }
  if (-not $sel.Count) { throw 'Nothing selected.' }

  $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
  $outDir = "$($t):\VioletMigrate\$stamp"
  $zipPath = "$outDir\VioletMigrate.zip"
  Say 'Packing:'
  $sel | ForEach-Object { '  ' + $_.Path }
  Say ('Free on {0}: {1}' -f $t, (Format-Bytes (Get-PSDrive $t).Free))
  if (-not (Confirm-Action "Pack these into $zipPath ? Nothing is deleted from $($d):")) { Say 'Cancelled.'; return }

  New-Item -ItemType Directory -Force $outDir | Out-Null
  $manifest = [ordered]@{ created = $stamp; fromDrive = $d; items = @() }
  $fs = [IO.File]::Open($zipPath, 'Create')
  $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
  $files = 0; $bytes = [long]0; $skipped = 0
  try {
    for ($n = 0; $n -lt $sel.Count; $n++) {
      $it = $sel[$n]
      Say "[$($n + 1)/$($sel.Count)] $($it.Path)"
      $manifest.items += [ordered]@{ i = $n; user = $it.User; rel = $it.Rel; source = $it.Path.Substring(3) }
      foreach ($f in Walk-Files $it.Path) {
        $rel = $f.FullName.Substring($it.Path.Length).TrimStart('\') -replace '\\', '/'
        try {
          [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, "$n/$rel", [IO.Compression.CompressionLevel]::Optimal)
          $files++; $bytes += $f.Length
          if ($files % 1000 -eq 0) { Say ("   {0:N0} files, {1}" -f $files, (Format-Bytes $bytes)) }
        } catch { $skipped++; Add-Content "$outDir\skipped.txt" "$($f.FullName)  ($($_.Exception.Message))" }
      }
    }
    $e = $zip.CreateEntry('manifest.json')
    $w = New-Object IO.StreamWriter($e.Open())
    $w.Write(($manifest | ConvertTo-Json -Depth 5)); $w.Close()
  } finally { $zip.Dispose(); $fs.Dispose() }
  $manifest | ConvertTo-Json -Depth 5 | Set-Content "$outDir\manifest.json"

  $zipSize = (Get-Item $zipPath).Length
  Say ('Packed {0:N0} files: {1} into a {2} zip. Skipped {3} (see skipped.txt).' -f $files, (Format-Bytes $bytes), (Format-Bytes $zipSize), $skipped)

  # Put the app and a "Restore my files" shortcut on the new Windows, if the target is one.
  if (Test-Path "$($t):\Windows\System32") {
    Copy-Item $Root "$($t):\VioletRescue" -Recurse -Force
    $desk = "$($t):\Users\Public\Desktop"
    New-Item -ItemType Directory -Force $desk | Out-Null
    $cmd = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%SystemDrive%\VioletRescue\cli\rescue.ps1`" migrate-restore -Option `"%SystemDrive%\VioletMigrate\$stamp\VioletMigrate.zip`"`r`npause`r`n"
    Set-Content "$desk\Restore my files.cmd" $cmd -Encoding ASCII
    Say 'Added "Restore my files" to the new Windows desktop. Sign in there and double-click it.'
  }
}

function Cmd-MigrateRestore {
  $zipPath = $Option
  if (-not $zipPath) {
    $zipPath = Get-ChildItem ([char[]](67..90) | ForEach-Object { "$($_):\VioletMigrate" }) -Recurse -Filter VioletMigrate.zip -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
  }
  if (-not $zipPath -or -not (Test-Path $zipPath)) { throw 'No VioletMigrate.zip found. Put its path in Option.' }
  $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
  try {
    $me = $zip.GetEntry('manifest.json')
    $r = New-Object IO.StreamReader($me.Open()); $manifest = $r.ReadToEnd() | ConvertFrom-Json; $r.Close()
    $users = @($manifest.items | Where-Object { $_.user } | Select-Object -ExpandProperty user -Unique)
    $mainUser = if ($users -contains $env:USERNAME) { $env:USERNAME } else {
      ($manifest.items | Where-Object { $_.user } | Group-Object user | Sort-Object Count -Descending | Select-Object -First 1).Name }

    $dest = @{}
    foreach ($it in $manifest.items) {
      if (-not $it.user) { $dest["$($it.i)"] = Join-Path "$env:SystemDrive\" $it.source }
      elseif ($it.user -eq $mainUser) { $dest["$($it.i)"] = Join-Path $env:USERPROFILE $it.rel }
      else { $dest["$($it.i)"] = Join-Path $env:USERPROFILE "Old users\$($it.user)\$($it.rel)" }
    }
    Say "Restoring from $zipPath"
    $manifest.items | ForEach-Object { '  {0}  ->  {1}' -f $_.source, $dest["$($_.i)"] }
    if (-not (Confirm-Action 'Put these files in place? Files that already exist are kept, not overwritten.')) { Say 'Cancelled.'; return }

    $done = 0; $kept = 0; $failed = 0
    foreach ($e in $zip.Entries) {
      if ($e.FullName -eq 'manifest.json' -or -not $e.Name) { continue }
      $slash = $e.FullName.IndexOf('/')
      $root = $dest[$e.FullName.Substring(0, $slash)]
      if (-not $root) { continue }
      $path = Join-Path $root ($e.FullName.Substring($slash + 1) -replace '/', '\')
      if (Test-Path $path) { $kept++; continue }
      try {
        New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $path, $false)
        $done++
        if ($done % 1000 -eq 0) { Say ("   {0:N0} files placed" -f $done) }
      } catch { $failed++ }
    }
    Say ('Done: {0:N0} files placed, {1:N0} already there, {2:N0} failed.' -f $done, $kept, $failed)
    if ($manifest.items | Where-Object { $_.source -match '^Program' }) { Say 'Program folders were copied back, but programs still need reinstalling to run.' }
  } finally { $zip.Dispose() }
}
