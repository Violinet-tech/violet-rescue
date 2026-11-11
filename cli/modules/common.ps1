# Shared helpers for the Violet Rescue modules. Dot-sourced by rescue.ps1.

# Walk a folder without following junctions (AppData has self-pointing ones). Yields FileInfo.
function Walk-Files($dir) {
  $stack = New-Object System.Collections.Stack
  $stack.Push((New-Object IO.DirectoryInfo $dir))
  while ($stack.Count) {
    $d = $stack.Pop()
    try {
      foreach ($e in $d.EnumerateFileSystemInfos()) {
        if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($e -is [IO.DirectoryInfo]) { $stack.Push($e) } else { $e }
      }
    } catch { }
  }
}

function Get-FolderBytes($dir) {
  $s = [long]0
  foreach ($f in Walk-Files $dir) { $s += $f.Length }
  return $s
}

function Format-Bytes([long]$b) {
  if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
  if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }
  return ('{0:N0} KB' -f ($b / 1KB))
}

# Find Windows install media (install.wim / install.esd) on any drive.
function Find-InstallImage {
  foreach ($c in [char[]](67..90)) {
    foreach ($n in 'install.wim', 'install.esd') {
      if (Test-Path "$($c):\sources\$n") { return "$($c):\sources\$n" }
    }
  }
  return $null
}

function Get-OfflineEdition($d) {
  Use-Hive "$($d):\Windows\System32\config\SOFTWARE" 'SOFT' {
    param($r) (Get-ItemProperty "$r\Microsoft\Windows NT\CurrentVersion").EditionID
  }
}

# Index in an install image that matches an edition name (falls back to 1).
function Find-ImageIndex($src, $edition) {
  $idx = 1
  foreach ($img in Get-WindowsImage -ImagePath $src) {
    $full = Get-WindowsImage -ImagePath $src -Index $img.ImageIndex
    if ($full.EditionId -eq $edition) { $idx = $img.ImageIndex }
  }
  return $idx
}

# Give the EFI System partition on the same disk as drive $d a letter; returns the letter.
function Mount-Esp($d) {
  $part = Get-Partition -DriveLetter $d
  $esp = Get-Partition -DiskNumber $part.DiskNumber | Where-Object { $_.GptType -eq $EspGuid } | Select-Object -First 1
  if (-not $esp) { throw "No EFI System partition on disk $($part.DiskNumber)." }
  if ($esp.DriveLetter -and "$($esp.DriveLetter)" -ne "`0") { return "$($esp.DriveLetter)" }
  $esp | Set-Partition -NewDriveLetter S
  return 'S'
}
