# Agent help. Dot-sourced by rescue.ps1.
#   support-bundle -Drive C [-Target E]   collect what an agent (or a person) needs to diagnose the PC
#   agent          -Drive C               start Claude Code here with the Codey/Warden rescue brief
#                                         (needs Claude Code installed: a working Windows or the helper PC)

function Cmd-SupportBundle {
  $d = Resolve-Drive
  $dir = if ($Target) { "$((Resolve-Target)):\RescueBundle" } else { "$env:SystemDrive\RescueBundle" }
  New-Item -ItemType Directory -Force $dir | Out-Null
  Say "Collecting into $dir ..."
  $run = { param($verb, $file) & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CliPath $verb -Drive $d 2>&1 | Out-File (Join-Path $dir $file) -Encoding UTF8 }
  & $run 'drives' 'drives.txt'
  & $run 'updates' 'updates.txt'
  & $run 'drivers' 'drivers.txt'
  & $run 'malware-scan' 'startup.txt'
  $cbs = "$($d):\Windows\Logs\CBS\CBS.log"
  if (Test-Path $cbs) { Get-Content $cbs -Tail 400 | Out-File "$dir\cbs-tail.txt" -Encoding UTF8 }
  foreach ($log in 'System', 'Setup', 'Application') {
    $evtx = "$($d):\Windows\System32\winevt\Logs\$log.evtx"
    if (Test-Path $evtx) { & wevtutil.exe qe $evtx /lf:true /c:150 /rd:true /f:text 2>&1 | Out-File "$dir\events-$log.txt" -Encoding UTF8 }
  }
  Get-ChildItem "$($d):\Windows\Minidump" -ErrorAction SilentlyContinue | Select-Object Name, Length, LastWriteTime | Out-File "$dir\minidumps.txt"
  foreach ($p in "$($d):\Windows\Panther\setupact.log", "$($d):\Windows\System32\LogFiles\Srt\SrtTrail.txt") {
    if (Test-Path $p) { Copy-Item $p $dir -Force }
  }
  Say 'Done. Nothing in the bundle holds passwords; it does list file and program names.'
  Say "BUNDLE|$dir"
}

function Cmd-Agent {
  $d = Resolve-Drive
  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Say 'Claude Code is not available here.'
    Say 'From the rescue USB: plug a cable into a working PC, run helper\RescueHelper.ps1 there, link, and choose Agent help.'
    Say 'In a working Windows: install Claude Code from https://claude.com/claude-code, sign in with your own account, then run agent again.'
    return
  }
  $work = Join-Path $env:TEMP 'violet-rescue-agent'
  New-Item -ItemType Directory -Force $work | Out-Null
  $Target = $null
  Cmd-SupportBundle | Out-Null
  Copy-Item "$env:SystemDrive\RescueBundle" $work -Recurse -Force
  $send = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$CliPath`" -Yes"
  (Get-Content (Join-Path $Root 'agent\RESCUE-AGENT.md') -Raw) -replace '\{SEND\}', $send | Set-Content (Join-Path $work 'CLAUDE.md') -Encoding UTF8
  Start-Process powershell.exe -ArgumentList '-NoExit', '-Command', "Set-Location '$work'; claude"
  Say "Agent opened in a new window, working on Windows at $($d):"
}
