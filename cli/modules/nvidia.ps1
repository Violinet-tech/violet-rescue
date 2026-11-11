# NVIDIA drivers straight from NVIDIA's own driver lookup (the one nvidia.com/drivers uses).
# Dot-sourced by rescue.ps1. Needs internet (net-up, or the cable link's shared internet).
#   nvidia-gpus      [-Option filter]                       every NVIDIA card, current and legacy
#                                                           (GPU|psid|pfid|name|series lines for the app; detected card first)
#   nvidia-versions  -Option "<card>|game|studio|all"       list ALL driver versions for the card, newest first,
#                                                           including legacy, security-update and Standard (non-DCH) ones
#   nvidia-driver    -Option "<card>|game|studio[|version]" download the newest (or that exact version)
#                    [-Target E]                            save to E:\Drivers (default Downloads, or X:\Drivers on the USB)
# <card> is "psid:pfid" (what the app sends) or a card name like "GeForce RTX 3060".
#
# Checked against NVIDIA 2026-11-07: osID 135 = Windows 11, 57 = Windows 10 64-bit; upCRD=1 = Studio, 0 = Game Ready;
# dch=0 = Standard drivers, which very old cards (e.g. GTX 480) only have. A GTX 780 on Windows 11 returns its legacy
# 475.x security-update drivers.

$NvProducts = 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3'
$NvSeries   = 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=2'
$NvLookup   = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&languageCode=1033&sort1=0'

function Get-NvCached($url, $file) {
  $cache = Join-Path $Root "db\$file"
  if (-not (Test-Path $cache) -or ((Get-Date) - (Get-Item $cache).LastWriteTime).TotalDays -gt 7) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try { Invoke-WebRequest $url -OutFile $cache -UseBasicParsing -TimeoutSec 60 }
    catch { if (-not (Test-Path $cache)) { throw "Could not reach NVIDIA: $($_.Exception.Message)" } }
  }
  return ([xml](Get-Content $cache -Raw)).LookupValueSearch.LookupValues.LookupValue
}

function Get-NvProducts {
  $series = @{}
  foreach ($s in Get-NvCached $NvSeries 'nvidia-series.xml') { $series["$($s.Value)"] = $s.Name }
  Get-NvCached $NvProducts 'nvidia-gpus.xml' | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; Psid = $_.ParentID; Pfid = $_.Value; Series = $series["$($_.ParentID)"] }
  }
}

function Get-DetectedGpu {
  Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' } |
    Select-Object -First 1 -ExpandProperty Name
}

function Resolve-NvCard($card) {
  $card = $card.Trim()
  $all = @(Get-NvProducts)
  if ($card -match '^(\d+):(\d+)$') { $p = $all | Where-Object { $_.Psid -eq $Matches[1] -and $_.Pfid -eq $Matches[2] } | Select-Object -First 1 }
  else {
    $bare = $card -replace '^NVIDIA ', ''
    $p = $all | Where-Object { ($_.Name -replace '^NVIDIA ', '') -eq $bare -and $_.Series -notmatch 'Notebook|M Series' } | Select-Object -First 1
    if (-not $p) { $p = $all | Where-Object { $_.Name -like "*$bare*" } | Select-Object -First 1 }
  }
  if (-not $p) { throw "NVIDIA does not list a card called '$card'." }
  return $p
}

function Get-TargetOsId {
  if ($Drive) {
    $d = Resolve-Drive
    if ((Get-Item "$($d):\Windows\System32\ntoskrnl.exe").VersionInfo.FileBuildPart -lt 22000) { return 57 }
    return 135
  }
  if ([Environment]::OSVersion.Version.Build -lt 22000 -and $env:SystemDrive -ne 'X:') { return 57 }
  return 135
}

# Every driver NVIDIA lists for the card. Tries the target Windows first, then the legacy routes.
function Get-NvVersions($p, $kind) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $os = Get-TargetOsId
  $routes = @(@{ os = $os; dch = 1; label = '' })
  if ($os -ne 57) { $routes += @{ os = 57; dch = 1; label = 'Windows 10 driver' } }
  $routes += @{ os = 57; dch = 0; label = 'legacy Standard driver' }
  $kinds = switch ($kind) { 'studio' { @(1) } 'all' { @(0, 1) } default { @(0) } }
  foreach ($r in $routes) {
    $found = @()
    foreach ($k in $kinds) {
      $url = "$NvLookup&psid=$($p.Psid)&pfid=$($p.Pfid)&osID=$($r.os)&dch=$($r.dch)&upCRD=$k&numberOfResults=100"
      try { $j = Invoke-RestMethod $url -UseBasicParsing -TimeoutSec 90 } catch { Say "  (NVIDIA did not answer for route os $($r.os): $($_.Exception.Message))"; continue }
      foreach ($i in $j.IDS | ForEach-Object { $_.downloadInfo } | Where-Object { $_.Success -eq '1' }) {
        $found += [pscustomobject]@{
          Version = $i.Version; Date = $i.ReleaseDateTime; Name = [uri]::UnescapeDataString($i.Name)
          Url = $i.DownloadURL; Route = $r.label; Kind = $(if ($k -eq 1) { 'studio' } else { 'game' })
        }
      }
    }
    if ($found.Count) {
      return ($found | Sort-Object { [version]($_.Version + '.0') } -Descending | Group-Object { "$($_.Version)|$($_.Kind)" } | ForEach-Object { $_.Group[0] })
    }
  }
  return @()
}

function Cmd-NvidiaGpus {
  $det = Get-DetectedGpu
  if ($det) { Say "DETECTED|$det" }
  Get-NvProducts | Where-Object { -not $Option -or $_.Name -match [regex]::Escape($Option) } |
    ForEach-Object { Say "GPU|$($_.Psid)|$($_.Pfid)|$($_.Name)|$($_.Series)" }
  Say 'END'
}

function Cmd-NvidiaVersions {
  if (-not $Option) { throw 'Put "<card>|game", "<card>|studio" or "<card>|all" in Option.' }
  $card, $kind = $Option.Split('|')[0, 1]
  $p = Resolve-NvCard $card
  Head "Every NVIDIA driver for $($p.Name) ($($p.Series))"
  $list = @(Get-NvVersions $p "$kind")
  if (-not $list.Count) { Say 'NVIDIA lists no driver for this card on Windows 10/11.'; Say 'END'; return }
  foreach ($v in $list) {
    $route = if ($v.Route) { "  [$($v.Route)]" } else { '' }
    Say ("VER|{0}|{1}|{2}|{3}|{4}" -f $v.Version, $v.Date, ($v.Name + $route), $v.Url, $v.Kind)
  }
  if ($list[0].Route) { Say "This card is legacy: newest is $($list[0].Version) ($($list[0].Route))." }
  Say 'END'
}

function Cmd-NvidiaDriver {
  if (-not $Option) { throw 'Put "<card>|game" or "<card>|studio" (optionally "|version") in Option.' }
  $parts = $Option.Split('|')
  $p = Resolve-NvCard $parts[0]
  $kind = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1].Trim() } else { 'game' }
  $want = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '' }
  $list = @(Get-NvVersions $p $(if ($want) { 'all' } else { $kind }))
  $v = if ($want) { $list | Where-Object { $_.Version -eq $want } | Select-Object -First 1 } else { $list | Select-Object -First 1 }
  if (-not $v) { throw "NVIDIA has no $(if ($want) { "version $want" } else { $kind }) driver for $($p.Name)." }
  Say "$($p.Name): $($v.Name) $($v.Version), released $($v.Date) $(if ($v.Route) { "[$($v.Route)]" })"

  $dir = if ($Target) { "$((Resolve-Target)):\Drivers" } elseif ($env:SystemDrive -eq 'X:') { 'X:\Drivers' } else { Join-Path $env:USERPROFILE 'Downloads' }
  New-Item -ItemType Directory -Force $dir | Out-Null
  $file = Join-Path $dir (Split-Path $v.Url -Leaf)
  Say "Downloading $($v.Url)"
  Say "  to $file  (several hundred MB)"
  (New-Object Net.WebClient).DownloadFile($v.Url, $file)
  Say 'Downloaded.'
  if ($env:SystemDrive -eq 'X:') { Say 'The installer runs from inside Windows. Copy it to the new Windows, or run it after you sign in.' }
  elseif (Confirm-Action 'Start the NVIDIA installer now?') { Start-Process $file }
}
