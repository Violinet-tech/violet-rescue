# Used by the agent on the helper PC: runs one rescue command on the broken PC through the open
# Rescue Helper window and prints the result.
#   powershell -File send.ps1 updates -Drive C
param(
  [Parameter(Position = 0, Mandatory = $true)][string]$Verb,
  [string]$Drive,
  [string]$Target,
  [string]$Option
)
. (Join-Path $PSScriptRoot '..\cli\modules\wire.ps1')
try {
  $c = New-Object Net.Sockets.TcpClient('127.0.0.1', $WireLocal)
} catch {
  Write-Output 'The Rescue Helper bridge is not running. In the Rescue Helper window choose 6 (Agent help).'
  exit 1
}
try {
  $s = $c.GetStream()
  Send-Msg $s @{ type = 'run'; verb = $Verb; drive = $Drive; target = $Target; option = $Option }
  Write-Output (Read-Msg $s).text
} finally { $c.Close() }
