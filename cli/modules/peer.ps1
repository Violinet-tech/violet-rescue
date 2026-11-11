# Cable link: an Ethernet cable from this PC straight into a working PC that runs helper\RescueHelper.ps1.
# Dot-sourced by rescue.ps1.
#   cable-check                     is a cable plugged in, what is on the other end, is a helper there
#   cable-link -Option <code>       link to the helper (code shown on its screen); it can then send files,
#              [-Target E]          ask for files, run rescue commands and share its internet. Received files go
#                                   to E:\Received (default X:\Received). Runs until the helper ends it or Stop.

$CableBlocked = @('cable-link', 'help')

function Open-RescueFirewall {
  if (Get-Command wpeutil.exe -ErrorAction SilentlyContinue) { & wpeutil.exe DisableFirewall 2>&1 | Out-Null }
}

function Find-Helper([int]$seconds) {
  $u = New-Object Net.Sockets.UdpClient
  $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
  $u.Client.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, $WireUdp)))
  $u.Client.ReceiveTimeout = 1000
  $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
  $end = (Get-Date).AddSeconds($seconds)
  try {
    while ((Get-Date) -lt $end) {
      try {
        $t = [Text.Encoding]::ASCII.GetString($u.Receive([ref]$ep))
        if ($t -like 'VIOLET-RESCUE-HELPER|*') { return [pscustomobject]@{ IP = $ep.Address.ToString(); Name = $t.Split('|')[1] } }
      } catch { }
    }
  } finally { $u.Close() }
  return $null
}

function Cmd-CableCheck {
  Head 'Network ports'
  $cfg = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue)
  foreach ($a in Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=True' -ErrorAction SilentlyContinue) {
    $ips = @(($cfg | Where-Object { $_.Index -eq $a.Index }).IPAddress | Where-Object { $_ -match '^\d+\.' })
    $state = switch ($a.NetConnectionStatus) { 2 { 'cable in' } 7 { 'no cable' } default { "state $($a.NetConnectionStatus)" } }
    $what = ''
    if ($ips -match '^169\.254\.') { $what = 'cable goes straight to another computer (no router, no internet)' }
    elseif ($ips -match '^192\.168\.137\.') { $what = 'other computer is sharing its internet' }
    elseif ($ips.Count) { $what = 'on a normal network' }
    Say ('{0,-40} {1,-9} {2,-16} {3}' -f $a.Name, $state, ($ips -join ' '), $what)
  }
  Say ''
  Say 'Listening for a Rescue Helper on the cable (8 seconds)...'
  Open-RescueFirewall
  $h = Find-Helper 8
  if ($h) { Say "Helper found: $($h.Name) at $($h.IP). Use cable-link with the code on its screen." }
  else { Say 'No helper found. On the other PC run helper\RescueHelper.ps1 as administrator. A direct cable can take a minute to get an address.' }
}

function Invoke-ForHelper($m) {
  if (-not $m.verb -or $m.verb -in $CableBlocked) { return "Command '$($m.verb)' is not allowed over the cable." }
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $CliPath, $m.verb)
  if ($m.drive)  { $a += '-Drive', $m.drive }
  if ($m.target) { $a += '-Target', $m.target }
  if ($m.option) { $a += '-Option', $m.option }
  $a += '-Yes'
  return (& powershell.exe @a 2>&1 | Out-String)
}

function Cmd-CableLink {
  if (-not $Option) { throw 'Put the 6-digit code shown on the helper PC in Option.' }
  $recv = if ($Target) { "$((Resolve-Target)):\Received" } else { "$env:SystemDrive\Received" }
  Open-RescueFirewall
  $again = $true
  while ($again) {
    $again = $false
    Say 'Looking for the helper PC...'
    $h = Find-Helper 30
    if (-not $h) { throw 'No helper PC found on the cable.' }
    Say "Found $($h.Name) at $($h.IP). Linking..."
    $c = New-Object Net.Sockets.TcpClient
    $c.Connect($h.IP, $WireTcp)
    $s = $c.GetStream()
    try {
      Send-Msg $s @{ type = 'hello'; code = $Option; name = $env:COMPUTERNAME }
      $r = Read-Msg $s
      if ($r.type -ne 'ok') { throw "Helper refused the link: $($r.message)" }
      Say 'Linked. The helper PC is in control now. Press Stop here to end.'
      :link while ($true) {
        $m = Read-Msg $s
        switch ($m.type) {
          'run' {
            Say "Helper runs: $($m.verb) $($m.drive) $($m.option)"
            Send-Msg $s @{ type = 'output'; text = (Invoke-ForHelper $m) }
          }
          'file' {
            $dest = Join-Path $recv (Safe-Name $m.name)
            Receive-File $s $dest ([long]$m.size)
            Say "Received $dest"
            Send-Msg $s @{ type = 'ok' }
          }
          'get' {
            $p = $m.path
            if (-not (Test-Path -LiteralPath $p)) { Send-Msg $s @{ type = 'error'; message = "$p not found" }; continue }
            $item = Get-Item -LiteralPath $p
            if ($item.PSIsContainer) {
              $list = @(Walk-Files $item.FullName)
              Send-Msg $s @{ type = 'files'; count = $list.Count }
              foreach ($f in $list) { Send-File $s $f.FullName ($item.Name + $f.FullName.Substring($item.FullName.Length)) }
            } else {
              Send-Msg $s @{ type = 'files'; count = 1 }
              Send-File $s $item.FullName $item.Name
            }
            Say "Sent $p to the helper."
          }
          'internet' {
            Say 'Helper is sharing its internet. Reconnecting in a few seconds...'
            Send-Msg $s @{ type = 'ok' }
            $again = $true
            break link
          }
          'bye' { Say 'Helper ended the link.'; break link }
        }
      }
    } finally { $c.Close() }
    if ($again) {
      Start-Sleep 10
      & ipconfig.exe /renew | Out-Null
      & ipconfig.exe | Select-String 'IPv4'
    }
  }
}
