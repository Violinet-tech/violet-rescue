# Closes leftovers of an earlier build so they cannot block a new one: command windows running
# fix-stick or build-media (one may be stuck on a question) and any oscdimg still open.
# Runs from fix-stick.cmd, elevated. It never touches the window that started it.
$me = (Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID)).ParentProcessId
$stale = Get-CimInstance Win32_Process | Where-Object {
  $_.ProcessId -ne $PID -and $_.ProcessId -ne $me -and (
    ($_.Name -eq 'cmd.exe' -and $_.CommandLine -match 'fix-stick|build-media|MakeWinPEMedia') -or
    $_.Name -eq 'oscdimg.exe')
}
foreach ($p in $stale) {
  Write-Output ('Closing leftover ' + $p.Name + ' ' + $p.ProcessId)
  Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}
