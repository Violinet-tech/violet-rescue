# Cable link wire format, shared by the rescue PC and the helper PC.
# Each message: 4-byte length + UTF-8 JSON. A message with "size" is followed by that many raw bytes.
$WireUdp   = 47830   # helper beacon
$WireTcp   = 47831   # rescue PC <-> helper PC
$WireLocal = 47832   # helper's localhost port for the agent (send.ps1)

function Send-Msg($stream, $obj) {
  $json = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress -Depth 6))
  $stream.Write([BitConverter]::GetBytes([int]$json.Length), 0, 4)
  $stream.Write($json, 0, $json.Length)
  $stream.Flush()
}

function Read-Exact($stream, [int]$n) {
  $buf = New-Object byte[] $n
  $off = 0
  while ($off -lt $n) {
    $r = $stream.Read($buf, $off, $n - $off)
    if ($r -le 0) { throw 'The cable link closed.' }
    $off += $r
  }
  return , $buf
}

function Read-Msg($stream) {
  $len = [BitConverter]::ToInt32((Read-Exact $stream 4), 0)
  if ($len -lt 2 -or $len -gt 64MB) { throw 'Bad message on the cable link.' }
  return ([Text.Encoding]::UTF8.GetString((Read-Exact $stream $len)) | ConvertFrom-Json)
}

function Send-File($stream, $path, $name) {
  $fi = Get-Item -LiteralPath $path
  Send-Msg $stream @{ type = 'file'; name = $name; size = $fi.Length }
  $fs = [IO.File]::OpenRead($fi.FullName)
  try { $fs.CopyTo($stream) } finally { $fs.Close() }
  $stream.Flush()
}

function Receive-File($stream, $path, [long]$size) {
  New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
  $fs = [IO.File]::Create($path)
  try {
    $buf = New-Object byte[] 1MB
    $left = $size
    while ($left -gt 0) {
      $r = $stream.Read($buf, 0, [int][Math]::Min($buf.Length, $left))
      if ($r -le 0) { throw 'The cable link closed mid-file.' }
      $fs.Write($buf, 0, $r); $left -= $r
    }
  } finally { $fs.Close() }
}

# Names come from the other PC: keep them inside the folder they are saved to.
function Safe-Name($name) {
  $n = ($name -replace '/', '\').TrimStart('\')
  if ($n -match '(^|\\)\.\.(\\|$)' -or $n -match ':') { throw "Refused unsafe file name: $name" }
  return $n
}
