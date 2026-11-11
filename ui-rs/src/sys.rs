//! Drive discovery through the Win32 volume calls (no WMI: WinRE does not run it reliably).

use crate::app::Drive;
use windows_sys::Win32::Storage::FileSystem::{GetDiskFreeSpaceExW, GetDriveTypeW, GetFileAttributesW, GetLogicalDrives, GetVolumeInformationW, INVALID_FILE_ATTRIBUTES};

fn wide(s: &str) -> Vec<u16> { s.encode_utf16().chain(std::iter::once(0)).collect() }

fn present(path: &str) -> bool {
    let w = wide(path);
    unsafe { GetFileAttributesW(w.as_ptr()) != INVALID_FILE_ATTRIBUTES }
}

pub fn list_drives() -> Vec<Drive> {
    let mut out = Vec::new();
    let mask = unsafe { GetLogicalDrives() };
    for i in 0..26u32 {
        if mask & (1 << i) == 0 { continue; }
        let letter = (b'A' + i as u8) as char;
        if letter == 'X' { continue; } // the RAM drive WinRE boots into
        let root = format!("{letter}:\\");
        let w = wide(&root);
        let kind = unsafe { GetDriveTypeW(w.as_ptr()) };
        // 2 removable, 3 fixed, 4 network, 5 cd-rom, 6 ram disk
        if kind == 5 || kind < 2 { continue; }
        let (mut free, mut total, mut _tf) = (0u64, 0u64, 0u64);
        let ok = unsafe { GetDiskFreeSpaceExW(w.as_ptr(), &mut free, &mut total, &mut _tf) };
        if ok == 0 { continue; } // not ready
        let mut name = [0u16; 64];
        let got = unsafe {
            GetVolumeInformationW(w.as_ptr(), name.as_mut_ptr(), name.len() as u32, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), 0)
        };
        let label = if got != 0 { String::from_utf16_lossy(&name[..name.iter().position(|&c| c == 0).unwrap_or(0)]) } else { String::new() };
        // GetFileAttributes, not Path::exists: a running Windows holds SYSTEM open and
        // std's metadata call can fail on that sharing violation, hiding the drive.
        // Without admin rights the config folder cannot be listed, so also accept the kernel + folder.
        let has_win = present(&format!("{letter}:\\Windows\\System32\\config\\SYSTEM"))
            || (present(&format!("{letter}:\\Windows\\System32\\config")) && present(&format!("{letter}:\\Windows\\System32\\ntoskrnl.exe")));
        let is_stick = present(&format!("{letter}:\\sources\\boot.wim"));
        out.push(Drive {
            letter, label, gb: total as f64 / 1_073_741_824.0, free: free as f64 / 1_073_741_824.0,
            has_win, is_stick, fixed: kind == 3 || kind == 2,
        });
    }
    out
}
