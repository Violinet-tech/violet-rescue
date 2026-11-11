# Fresh Windows on a new partition, next to the broken one. Dot-sourced by rescue.ps1.
#   new-windows -Drive C [-Option <GB, default 120>]   shrink C by that much and install there
#   new-windows -Drive C -Target N                      install onto existing partition N (it is formatted)

function Cmd-NewWindows {
  $d = Resolve-Drive
  $src = Find-InstallImage
  if (-not $src) { throw 'No install.wim or install.esd found. Plug in Windows 11 install media (the setup USB).' }
  $edition = Get-OfflineEdition $d
  $idx = Find-ImageIndex $src $edition
  $name = (Get-WindowsImage -ImagePath $src -Index $idx).ImageName
  Say "Image: $src  index $idx  ($name, matches your $edition)"

  if ($Target) {
    $n = Resolve-Target
    if ($n -eq $d) { throw 'Target is the broken Windows drive itself. Pick another partition.' }
    if (-not (Confirm-Action "ERASE partition $($n): and install a fresh $name on it? Your old Windows on $($d): is not touched.")) { Say 'Cancelled.'; return }
  } else {
    $gb = if ($Option) { [int]$Option } else { 120 }
    $p = Get-Partition -DriveLetter $d
    $sup = Get-PartitionSupportedSize -DriveLetter $d
    $newSize = $p.Size - ([long]$gb * 1GB)
    if ($newSize -lt ($sup.SizeMin + 10GB)) {
      throw ('Not enough free space on {0}: to give {1} GB. At most about {2:N0} GB can be taken.' -f $d, $gb, (($p.Size - $sup.SizeMin - 10GB) / 1GB))
    }
    if (-not (Confirm-Action "Shrink $($d): by $gb GB and install a fresh $name in the new space? Your files on $($d): stay. Run Check disk first if $($d): had errors.")) { Say 'Cancelled.'; return }
    Say "Shrinking $($d): ..."
    Resize-Partition -DriveLetter $d -Size $newSize -ErrorAction Stop
    $np = New-Partition -DiskNumber $p.DiskNumber -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    $n = "$($np.DriveLetter)"
    Say "New partition: $($n):"
  }

  Format-Volume -DriveLetter $n -FileSystem NTFS -NewFileSystemLabel 'Windows fresh' -Confirm:$false -ErrorAction Stop | Out-Null
  Say "Installing Windows onto $($n): (10-30 minutes) ..."
  Expand-WindowsImage -ImagePath $src -Index $idx -ApplyPath "$($n):\" -ErrorAction Stop | Out-Null

  $L = Mount-Esp $d
  & bcdboot.exe "$($n):\Windows" /s "$($L):" /f UEFI
  & bcdedit.exe /store "$($L):\EFI\Microsoft\Boot\BCD" /set '{default}' description 'Windows (fresh)'
  & bcdedit.exe /store "$($L):\EFI\Microsoft\Boot\BCD" /timeout 10

  Say ''
  Say "Fresh Windows installed on $($n): and set to start first. The old one stays in the boot menu."
  Say "Next: use Move my files to pack folders from $($d): into $($n): before you restart."
}
