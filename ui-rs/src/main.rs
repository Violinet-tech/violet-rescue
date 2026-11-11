//! Violet Rescue UI: a plain Win32 window that shows a CPU-drawn frame through GDI.
//! No GPU, no DWM, no WebView, so it starts the same on a desktop and inside WinRE.
//!
//!   VioletRescueUI.exe                     normal window
//!   VioletRescueUI.exe --shot out.png [--tab N] [--size 1024x768] [--demo] [--mouse X,Y] [--time T]
//!                                          draw one frame to a PNG without a window

#![windows_subsystem = "windows"]

mod app;
mod gfx;
mod sys;

use app::App;
use std::cell::RefCell;
use std::time::Instant;
use tiny_skia::Pixmap;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Graphics::Gdi::*;
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{ReleaseCapture, SetCapture};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

struct State { app: App, pm: Pixmap, bgra: Vec<u32>, last: Instant }

thread_local! { static ST: RefCell<Option<State>> = const { RefCell::new(None) }; }

fn wide(s: &str) -> Vec<u16> { s.encode_utf16().chain(std::iter::once(0)).collect() }

fn exe_dir() -> std::path::PathBuf {
    std::env::current_exe().ok().and_then(|p| p.parent().map(|d| d.to_path_buf())).unwrap_or_else(|| ".".into())
}

fn fail(msg: &str) -> ! {
    let t = wide(msg);
    let c = wide("Violet Rescue");
    unsafe { MessageBoxW(std::ptr::null_mut(), t.as_ptr(), c.as_ptr(), MB_OK | MB_ICONERROR) };
    std::process::exit(1);
}

fn lparam_xy(l: LPARAM) -> (f32, f32) {
    ((l & 0xFFFF) as u16 as i16 as f32, ((l >> 16) & 0xFFFF) as u16 as i16 as f32)
}

fn with<R>(f: impl FnOnce(&mut State) -> R) -> Option<R> {
    ST.with(|c| c.try_borrow_mut().ok().and_then(|mut g| g.as_mut().map(f)))
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_SIZE => {
            let (w, h) = ((lp & 0xFFFF) as u32, ((lp >> 16) & 0xFFFF) as u32);
            if w > 0 && h > 0 {
                with(|s| {
                    if let Some(pm) = Pixmap::new(w, h) { s.pm = pm; s.bgra = vec![0; (w * h) as usize]; }
                    s.app.resize(w as f32, h as f32);
                });
            }
            0
        }
        WM_TIMER => { InvalidateRect(hwnd, std::ptr::null(), 0); 0 }
        WM_ERASEBKGND => 1,
        WM_PAINT => {
            let mut ps: PAINTSTRUCT = std::mem::zeroed();
            let hdc = BeginPaint(hwnd, &mut ps);
            with(|s| {
                let now = Instant::now();
                let dt = (now - s.last).as_secs_f32().min(0.05);
                s.last = now;
                s.app.update(dt);
                s.app.draw(&mut s.pm);
                let (w, h) = (s.pm.width() as i32, s.pm.height() as i32);
                for (o, px) in s.bgra.iter_mut().zip(s.pm.data().chunks_exact(4)) {
                    *o = (px[0] as u32) << 16 | (px[1] as u32) << 8 | px[2] as u32;
                }
                let mut bi: BITMAPINFO = std::mem::zeroed();
                bi.bmiHeader.biSize = std::mem::size_of::<BITMAPINFOHEADER>() as u32;
                bi.bmiHeader.biWidth = w;
                bi.bmiHeader.biHeight = -h; // top-down rows
                bi.bmiHeader.biPlanes = 1;
                bi.bmiHeader.biBitCount = 32;
                bi.bmiHeader.biCompression = BI_RGB as _;
                StretchDIBits(hdc, 0, 0, w, h, 0, 0, w, h, s.bgra.as_ptr() as *const _, &bi, DIB_RGB_COLORS, SRCCOPY);
            });
            EndPaint(hwnd, &ps);
            0
        }
        WM_MOUSEMOVE => { let (x, y) = lparam_xy(lp); with(|s| s.app.mouse_move(x, y)); 0 }
        WM_LBUTTONDOWN => { SetCapture(hwnd); let (x, y) = lparam_xy(lp); with(|s| s.app.mouse_down(x, y)); 0 }
        WM_LBUTTONUP => { ReleaseCapture(); let (x, y) = lparam_xy(lp); with(|s| s.app.mouse_up(x, y)); 0 }
        WM_MOUSEWHEEL => {
            let d = ((wp >> 16) & 0xFFFF) as u16 as i16 as f32 / 120.0;
            with(|s| s.app.wheel(d));
            0
        }
        WM_CHAR => {
            if let Some(c) = char::from_u32(wp as u32) { with(|s| s.app.key_char(c)); }
            0
        }
        WM_KEYDOWN => { with(|s| s.app.key_down(wp as u32)); 0 }
        WM_DESTROY => { PostQuitMessage(0); 0 }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn shot(args: &[String]) {
    let get = |k: &str| args.iter().position(|a| a == k).and_then(|i| args.get(i + 1)).cloned();
    let out = get("--shot").unwrap();
    let (w, h) = get("--size").and_then(|s| { let p: Vec<u32> = s.split('x').filter_map(|v| v.parse().ok()).collect(); (p.len() == 2).then(|| (p[0], p[1])) }).unwrap_or((1024, 768));
    let tab: usize = get("--tab").and_then(|v| v.parse().ok()).unwrap_or(0);
    let time: f32 = get("--time").and_then(|v| v.parse().ok()).unwrap_or(2.0);
    let demo = args.iter().any(|a| a == "--demo");
    let mut app = App::new(&exe_dir(), demo).unwrap_or_else(|e| { eprintln!("{e}"); std::process::exit(1) });
    app.resize(w as f32, h as f32);
    if let Some(m) = get("--mouse") {
        let p: Vec<f32> = m.split(',').filter_map(|v| v.parse().ok()).collect();
        if p.len() == 2 { app.mouse_move(p[0], p[1]); }
    }
    app.tab = tab;
    let mut pm = Pixmap::new(w, h).unwrap();
    if let Some(verb) = get("--run") {
        // drive a real command through the same runner the buttons use, then show the result
        app.run_now(&verb);
        let start = Instant::now();
        while app.busy() && start.elapsed().as_secs() < 120 {
            app.update(1.0 / 60.0);
            std::thread::sleep(std::time::Duration::from_millis(16));
        }
    }
    // step the clock so animations settle the way a person would see them
    let steps = (time * 60.0) as usize;
    for i in 0..steps.max(1) {
        app.update(1.0 / 60.0);
        if i + 1 == steps.max(1) || i % 15 == 0 { app.draw(&mut pm); }
    }
    pm.save_png(&out).unwrap_or_else(|e| { eprintln!("{e}"); std::process::exit(1) });
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--shot") { return shot(&args); }
    unsafe { SetProcessDPIAware() };
    let app = App::new(&exe_dir(), args.iter().any(|a| a == "--demo")).unwrap_or_else(|e| fail(&e));
    unsafe {
        let hinst = GetModuleHandleW(std::ptr::null());
        let class = wide("VioletRescueUI");
        let wc = WNDCLASSW {
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(wndproc),
            hInstance: hinst,
            hCursor: LoadCursorW(std::ptr::null_mut(), IDC_ARROW),
            lpszClassName: class.as_ptr(),
            ..std::mem::zeroed()
        };
        RegisterClassW(&wc);
        ST.with(|c| *c.borrow_mut() = Some(State { app, pm: Pixmap::new(1024, 768).unwrap(), bgra: vec![0; 1024 * 768], last: Instant::now() }));
        let title = wide("Violet Rescue");
        let hwnd = CreateWindowExW(0, class.as_ptr(), title.as_ptr(), WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            CW_USEDEFAULT, CW_USEDEFAULT, 1180, 820, std::ptr::null_mut(), std::ptr::null_mut(), hinst, std::ptr::null());
        if hwnd.is_null() { fail("Could not open the window."); }
        ShowWindow(hwnd, SW_MAXIMIZE);
        SetTimer(hwnd, 1, 16, None);
        let mut msg: MSG = std::mem::zeroed();
        while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}
