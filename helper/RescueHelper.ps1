# Rescue Helper - run on a WORKING PC that has an Ethernet cable into the broken PC.
# Run as administrator (it opens a firewall port while running and can share internet).
#   powershell -ExecutionPolicy Bypass -File RescueHelper.ps1
# On the broken PC, run cable-link with the code this window shows.
. (Join-Path $PSScriptRoot '..\cli\modules\wire.ps1')
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) {
  Write-Host 'Run this as administrator (right-click PowerShell > Run as administrator).' -ForegroundColor Yellow
  exit 1
}

$Code = '{0:D6}' -f (Get-Random -Maximum 1000000)
$RuleName = 'Violet Rescue Helper'
New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Protocol TCP -LocalPort $WireTcp -Action Allow -Profile Any | Out-Null
$script:client = $null; $script:s = $null

function Send-Beacon {
  $msg = [Text.Encoding]::ASCII.GetBytes("VIOLET-RESCUE-HELPER|$env:COMPUTERNAME")
  foreach ($ip in Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne '127.0.0.1' }) {
    try {
      $u = New-Object Net.Sockets.UdpClient((New-Object Net.IPEndPoint([Net.IPAddress]::Parse($ip.IPAddress), 0)))
      $u.EnableBroadcast = $true
      [void]$u.Send($msg, $msg.Length, (New-Object Net.IPEndPoint([Net.IPAddress]::Broadcast, $WireUdp)))
      $u.Close()
    } catch { }
  }
}

function Wait-RescuePC {
  $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, $WireTcp)
  $l.Start()
  try {
    $tries = 0
    while ($true) {
      Send-Beacon
      $t = (Get-Date).AddSeconds(2)
      while ((Get-Date) -lt $t) {
        if ($l.Pending()) {
          $c = $l.AcceptTcpClient(); $st = $c.GetStream()
          $h = Read-Msg $st
          if ($h.type -eq 'hello' -and $h.code -eq $Code) {
            Send-Msg $st @{ type = 'ok' }
            $script:client = $c; $script:s = $st
            Write-Host "Linked to $($h.name) ($($c.Client.RemoteEndPoint))." -ForegroundColor Green
            return
          }
          Send-Msg $st @{ type = 'refused'; message = 'wrong code' }; $c.Close()
          $tries++
          Write-Host 'A PC tried to link with the wrong code.' -ForegroundColor Yellow
          if ($tries -ge 5) { throw 'Five wrong codes. Stopping.' }
        }
        Start-Sleep -Milliseconds 200
      }
    }
  } finally { $l.Stop() }
}

function Invoke-Remote($verb, $drive, $target, $option) {
  Send-Msg $script:s @{ type = 'run'; verb = $verb; drive = $drive; target = $target; option = $option }
  return (Read-Msg $script:s).text
}

# "updates -Drive C -Option x" -> parts
function Split-CommandLine($line) {
  $tok = [regex]::Matches($line, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') }
  $r = @{ verb = $tok[0]; drive = ''; target = ''; option = '' }
  for ($i = 1; $i -lt $tok.Count; $i++) {
    switch -regex ($tok[$i]) {
      '^-Drive$'  { $r.drive = $tok[++$i] }
      '^-Target$' { $r.target = $tok[++$i] }
      '^-Option$' { $r.option = $tok[++$i] }
    }
  }
  return $r
}

function Send-Path($path) {
  $item = Get-Item -LiteralPath $path
  $list = if ($item.PSIsContainer) { @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File) } else { @($item) }
  $base = if ($item.PSIsContainer) { $item.Parent.FullName } else { $item.DirectoryName }
  foreach ($f in $list) {
    Send-File $script:s $f.FullName $f.FullName.Substring($base.Length).TrimStart('\')
    [void](Read-Msg $script:s)
    Write-Host "  sent $($f.Name)"
  }
}

function Get-Path($remote, $saveTo) {
  Send-Msg $script:s @{ type = 'get'; path = $remote }
  $m = Read-Msg $script:s
  if ($m.type -eq 'error') { Write-Host $m.message -ForegroundColor Yellow; return }
  for ($i = 0; $i -lt $m.count; $i++) {
    $f = Read-Msg $script:s
    $dest = Join-Path $saveTo (Safe-Name $f.name)
    Receive-File $script:s $dest ([long]$f.size)
    if ($i % 200 -eq 0) { Write-Host "  $($i + 1)/$($m.count)  $($f.name)" }
  }
  Write-Host "Saved $($m.count) files to $saveTo" -ForegroundColor Green
}

function Get-CableAdapter {
  $local = $script:client.Client.LocalEndPoint.Address.ToString()
  (Get-NetIPAddress -IPAddress $local).InterfaceAlias
}

function Set-Sharing([bool]$on) {
  $hn = New-Object -ComObject HNetCfg.HNetShare
  $cable = Get-CableAdapter
  $public = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Where-Object { $_.InterfaceAlias -ne $cable } | Sort-Object RouteMetric | Select-Object -First 1).InterfaceAlias
  if ($on -and -not $public) { throw 'This PC has no internet connection to share.' }
  foreach ($c in $hn.EnumEveryConnection) {
    $p = $hn.NetConnectionProps.Invoke($c)
    $cfg = $hn.INetSharingConfigurationForINetConnection.Invoke($c)
    if ($cfg.SharingEnabled) { $cfg.DisableSharing() }
    if ($on -and $p.Name -eq $public) { $cfg.EnableSharing(0) }
    if ($on -and $p.Name -eq $cable) { $cfg.EnableSharing(1) }
  }
  if ($on) { Write-Host "Sharing '$public' over the cable ('$cable')." -ForegroundColor Green }
}

function Start-Agent {
  $work = Join-Path $env:TEMP 'violet-rescue-agent'
  New-Item -ItemType Directory -Force $work | Out-Null
  Write-Host 'Collecting a support bundle from the broken PC...'
  $out = Invoke-Remote 'support-bundle' '' '' ''
  Write-Host $out
  $bundle = ($out -split "`r?`n" | Where-Object { $_ -like 'BUNDLE|*' } | Select-Object -First 1)
  if ($bundle) { Get-Path $bundle.Substring(7).Trim() $work } else { Write-Host 'No bundle came back; the agent starts without it.' -ForegroundColor Yellow }
  $prompt = Get-Content (Join-Path $PSScriptRoot '..\agent\RESCUE-AGENT.md') -Raw
  $send = Join-Path $PSScriptRoot 'send.ps1'
  ($prompt -replace '\{SEND\}', $send) | Set-Content (Join-Path $work 'CLAUDE.md') -Encoding UTF8
  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host 'Claude Code is not installed on this PC. Install it from https://claude.com/claude-code and sign in with your own account, then choose Agent again.' -ForegroundColor Yellow
    return
  }
  Start-Process powershell.exe -ArgumentList '-NoExit', '-Command', "Set-Location '$work'; claude"
  Write-Host 'Agent window opened. It reaches the broken PC through this window. Press Q here to stop the bridge.'
  $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $WireLocal)
  $l.Start()
  try {
    while ($true) {
      if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Q') { break }
      if ($l.Pending()) {
        $c = $l.AcceptTcpClient(); $st = $c.GetStream()
        try {
          $m = Read-Msg $st
          Write-Host "Agent runs: $($m.verb) $($m.drive) $($m.option)" -ForegroundColor Cyan
          Send-Msg $st @{ type = 'output'; text = (Invoke-Remote $m.verb $m.drive $m.target $m.option) }
        } catch { Send-Msg $st @{ type = 'output'; text = "ERROR: $($_.Exception.Message)" } }
        finally { $c.Close() }
      }
      Start-Sleep -Milliseconds 200
    }
  } finally { $l.Stop() }
}

try {
  Write-Host ''
  Write-Host "Rescue Helper on $env:COMPUTERNAME" -ForegroundColor Magenta
  Write-Host "Pairing code: $Code" -ForegroundColor Magenta
  Write-Host 'On the broken PC: Cable link, type this code, press RUN. Waiting...'
  Wait-RescuePC
  while ($true) {
    Write-Host ''
    Write-Host '1 Send files/folder   2 Get files/folder   3 Run a rescue command   4 Share my internet'
    Write-Host '5 Stop sharing        6 Agent help (Claude Code)                   0 End'
    $ch = Read-Host 'Choose'
    try {
      switch ($ch) {
        '1' { Send-Path (Read-Host 'File or folder on THIS PC') }
        '2' { Get-Path (Read-Host 'File or folder on the BROKEN PC, e.g. your Documents folder on drive C') (Read-Host 'Save into which folder here') }
        '3' { $p = Split-CommandLine (Read-Host 'Command, e.g. updates -Drive C'); Write-Host (Invoke-Remote $p.verb $p.drive $p.target $p.option) }
        '4' {
          Send-Msg $script:s @{ type = 'internet' }; [void](Read-Msg $script:s)
          $script:client.Close()
          Set-Sharing $true
          Write-Host 'Waiting for the broken PC to reconnect...'
          Wait-RescuePC
        }
        '5' { Set-Sharing $false; Write-Host 'Sharing off.' }
        '6' { Start-Agent }
        '0' { Send-Msg $script:s @{ type = 'bye' }; break }
      }
    } catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
    if ($ch -eq '0') { break }
  }
} finally {
  if ($script:client) { $script:client.Close() }
  Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
}
