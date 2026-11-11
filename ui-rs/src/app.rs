//! App state, layout, input and the bridge to cli\rescue.ps1.
//! Immediate mode: every frame lays out and draws the whole window and records hit
//! rectangles; clicks are matched against the rectangles from the frame the user saw.

use crate::gfx::{self, col, Face, Fonts, Glass, Icon, Rgba, CYAN, DANGER, DIM, MAGENTA, VIOLET, WHITE};
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{channel, Receiver, TryRecvError};
use tiny_skia::{Color, Pixmap};

const TABS: [(&str, Icon); 5] = [
    ("Fix it", Icon::Spark),
    ("Restore points", Icon::Restore),
    ("Repair tools", Icon::Wrench),
    ("Drives", Icon::Drive),
    ("Log", Icon::Log),
];
const LOG_TAB: usize = 4;
const DRIVES_TAB: usize = 3;

/// Commands that run without a Windows drive (same list as gui\RescueGUI.ps1).
const NO_DRIVE: [&str; 14] = ["drives", "update-db", "net-up", "nvidia-gpus", "nvidia-driver", "nvidia-versions", "devconfig",
    "cable-check", "cable-link", "migrate-restore", "rp-fix", "rp-reset", "rp-auto", "rp-make"];

/// FIX IT: the usual order of repair. (verb, title, what it does, needs target, asks first)
const FIX: [(&str, &str, &str, bool, bool); 7] = [
    ("remove-bad-update", "Remove the bad update", "Try this first. Takes out the newest update that broke startup.", false, true),
    ("revert-pending", "Undo pending updates", "Rolls back updates that were half installed when it broke.", false, true),
    ("restore", "System Restore", "Go back in time to a restore point.", false, true),
    ("bootfix", "Fix the boot files", "Rebuilds the files the PC needs to find Windows.", false, true),
    ("backup", "Copy my files to another drive", "Saves your user folders before anything bigger.", true, false),
    ("updates", "Show the installed updates", "Only reads. Changes nothing.", false, false),
    ("clear-pending", "Clear stuck update leftovers", "Last resort, when the others do not help.", false, true),
];

/// Repair tools tab: (verb, title, hint for the Option box, needs target, asks first)
const REPAIR: [(&str, &str, &str, bool, bool); 21] = [
    ("drives", "List drives", "", false, false),
    ("updates", "Scan updates", "", false, false),
    ("remove-update", "Remove update", "Option: package name or KB. Empty = newest.", false, true),
    ("revert-pending", "Undo pending updates", "", false, true),
    ("rollback", "Rollback machine", "Option: date it broke, like 2026-11-02", false, true),
    ("restore", "System Restore", "", false, true),
    ("sfc", "SFC scan", "", false, false),
    ("chkdsk", "Check disk", "", false, true),
    ("restorehealth", "DISM repair", "Option: path to install.wim or .esd, add :index", false, true),
    ("bootfix", "Fix boot files", "", false, true),
    ("drivers", "List drivers", "Option: filter, like Realtek", false, false),
    ("remove-nvidia", "Remove NVIDIA display", "Option: all = every NVIDIA driver", false, true),
    ("remove-driver", "Remove driver", "Option: oemNN.inf, or Provider,Class", false, true),
    ("add-drivers", "Install drivers", "Option: nvidia, realtek, amd-chipset or a folder", false, true),
    ("block-driver-updates", "Block Windows drivers", "", false, true),
    ("unblock-driver-updates", "Allow Windows drivers", "", false, true),
    ("malware-scan", "Malware startup scan", "", false, false),
    ("disable-startup", "Disable startup item", "Option: name from the malware scan", false, true),
    ("backup", "Backup files", "Option: another folder. Empty = all user folders.", true, false),
    ("net-up", "Start network", "", false, false),
    ("update-db", "Update database", "", false, false),
];

#[derive(Clone, Copy, PartialEq)]
enum OnDone { Nothing, Snaps }

#[derive(Clone)]
struct Run { verb: String, option: String, target: bool, confirm: bool, label: String, on_done: OnDone }

impl Run {
    fn new(verb: &str, option: &str, target: bool, confirm: bool, label: &str) -> Run {
        Run { verb: verb.into(), option: option.into(), target, confirm, label: label.into(), on_done: OnDone::Nothing }
    }
}

#[derive(Clone)]
enum Act { Tab(usize), Run(Run), PickWin(char), PickTgt(char), Refresh, Stop, Yes, No, RpDec, RpInc, Snap(usize), SnapBack, Focus, OpenLog, Classic, Block }

struct Hit { x: f32, y: f32, w: f32, h: f32, act: Act, id: u32 }

#[derive(Default, Clone, Copy)]
struct Scroll { pos: f32, vel: f32, max: f32, shown: f32 }

struct Job { child: Child, rx: Receiver<String>, out: Vec<String>, on_done: OnDone, label: String, exited: Option<i32> }

pub struct Drive { pub letter: char, pub label: String, pub gb: f64, pub free: f64, pub has_win: bool, pub is_stick: bool, pub fixed: bool }

struct Snap { name: String, made: String, kind: String, size: String }

struct Press { x: f32, y: f32, id: Option<u32>, act: Option<Act>, scroll_tab: Option<usize>, dragging: bool, start_pos: f32, last_y: f32, last_t: f32, vel: f32 }

pub struct App {
    pub w: f32, pub h: f32, s: f32, pub t: f32,
    fonts: Fonts,
    cli: PathBuf,
    pub demo: bool,
    hits: Vec<Hit>, next_id: u32,
    mouse: (f32, f32), hover: Option<u32>, press: Option<Press>,
    pub tab: usize, tab_t: f32, sel_y: f32, sel_v: f32,
    scroll: [Scroll; 5],
    drives: Vec<Drive>, win: Option<char>, tgt: Option<char>,
    log: Vec<String>, job: Option<Job>, status_until: f32,
    confirm: Option<Run>, toast: Option<(String, f32)>,
    rp_num: u32, snaps: Vec<Snap>, snap_sel: Option<usize>,
    option: String, focus: bool,
    follow_log: bool,
}

fn find_cli(exe_dir: &std::path::Path) -> PathBuf {
    if let Ok(r) = std::env::var("VIOLET_RESCUE_ROOT") { return PathBuf::from(r).join("cli").join("rescue.ps1"); }
    let mut d = Some(exe_dir.to_path_buf());
    for _ in 0..5 {
        if let Some(dir) = d {
            let c = dir.join("cli").join("rescue.ps1");
            if c.exists() { return c; }
            d = dir.parent().map(|p| p.to_path_buf());
        }
    }
    exe_dir.join("cli").join("rescue.ps1")
}

fn ease_out(t: f32) -> f32 { 1.0 - (1.0 - t.clamp(0.0, 1.0)).powi(3) }

impl App {
    pub fn new(exe_dir: &std::path::Path, demo: bool) -> Result<App, String> {
        let fonts = Fonts::load(exe_dir)?;
        let cli = find_cli(exe_dir);
        let mut a = App {
            w: 1024.0, h: 768.0, s: 1.0, t: 0.0, fonts, cli, demo,
            hits: vec![], next_id: 0, mouse: (-1.0, -1.0), hover: None, press: None,
            tab: 0, tab_t: 1.0, sel_y: 0.0, sel_v: 0.0, scroll: [Scroll::default(); 5],
            drives: vec![], win: None, tgt: None, log: vec![], job: None, status_until: -1.0,
            confirm: None, toast: None, rp_num: 1, snaps: vec![], snap_sel: None,
            option: String::new(), focus: false, follow_log: true,
        };
        a.log.push("Violet Rescue. Pick a page on the left, then a button. Anything that changes the PC asks first.".into());
        if !a.cli.exists() { a.log.push(format!("Could not find cli\\rescue.ps1 (looked near {}).", exe_dir.display())); }
        a.refresh_drives();
        if demo { a.fill_demo(); }
        Ok(a)
    }

    /// Sample content for screenshots only (--demo). Never used on a real repair.
    fn fill_demo(&mut self) {
        for (n, m, k) in [("before-restore_2026-11-10_173345", "11/10/2026 5:33 PM", "before restore"),
                          ("before-restore_2026-11-10_171210", "11/10/2026 5:12 PM", "before restore"),
                          ("daily_2026-11-09", "11/9/2026 3:00 AM", "daily")] {
            self.snaps.push(Snap { name: n.into(), made: m.into(), kind: k.into(), size: "212 MB".into() });
        }
        self.snap_sel = Some(1);
        self.drives = vec![
            Drive { letter: 'C', label: "Windows".into(), gb: 931.0, free: 181.0, has_win: true, is_stick: false, fixed: true },
            Drive { letter: 'D', label: "Data".into(), gb: 466.0, free: 242.0, has_win: false, is_stick: false, fixed: true },
            Drive { letter: 'E', label: "".into(), gb: 29.0, free: 28.0, has_win: false, is_stick: true, fixed: true },
        ];
        self.win = Some('C');
        self.tgt = None;
        self.log.retain(|l| !l.starts_with("  ") && !l.starts_with("Drives found"));
        for l in ["> snap-list", "Snapshots on C:\\VioletRescue\\Snapshots", "  3 found", "[finished, exit code 0]", "",
                  "> rp-check", "Restore points on C:", "  [1] 10/31/2026 5:26 PM  Installed AMD chipset driver",
                  "  [2] 10/24/2026 3:00 AM  Windows Update", "System Restore service: off in this boot image"] {
            self.log.push(l.into());
        }
        self.status_until = 1e9;
    }

    pub fn resize(&mut self, w: f32, h: f32) {
        self.w = w.max(320.0);
        self.h = h.max(240.0);
        // Rescue screens are often 1024x768 or smaller: size everything off the short side.
        self.s = (self.h / 820.0).min(self.w / 1180.0).clamp(0.72, 2.2);
    }

    // ------------------------------------------------------------ drives

    pub fn refresh_drives(&mut self) {
        self.drives = crate::sys::list_drives();
        self.win = self.drives.iter().find(|d| d.has_win).map(|d| d.letter);
        if self.tgt.map_or(false, |t| !self.drives.iter().any(|d| d.letter == t) || Some(t) == self.win) { self.tgt = None; }
        self.log.push("Drives found:".into());
        for d in &self.drives {
            self.log.push(format!("  {}:  {}  {:.0} GB{}{}", d.letter, d.label, d.gb,
                if d.has_win { "  (has Windows)" } else { "" }, if d.is_stick { "  (rescue stick)" } else { "" }));
        }
        if self.win.is_none() {
            self.log.push("No drive with Windows on it was found. NVMe or RAID disks may need their driver: Repair tools, Install drivers.".into());
        }
    }

    fn auto_target(&mut self) {
        let best = self.drives.iter()
            .filter(|d| Some(d.letter) != self.win && !d.is_stick && d.fixed && d.gb >= 10.0)
            .max_by(|a, b| a.free.partial_cmp(&b.free).unwrap());
        if let Some(b) = best {
            self.tgt = Some(b.letter);
            self.log.push(format!("Target drive chosen automatically: {}: ({:.0} GB free)", b.letter, b.free));
        }
    }

    // ------------------------------------------------------------ commands

    /// Test hook for --shot --run VERB: start a command without the confirm step.
    pub fn run_now(&mut self, verb: &str) { self.exec(Run::new(verb, "", false, false, verb)); }
    pub fn busy(&self) -> bool { self.job.is_some() }

    fn toast(&mut self, m: &str) { self.toast = Some((m.to_string(), self.t)); }

    fn start(&mut self, r: Run) {
        if self.job.is_some() { return self.toast("A command is still running. Stop it or wait."); }
        let needs_drive = !NO_DRIVE.contains(&r.verb.as_str());
        if needs_drive && self.win.is_none() { self.refresh_drives(); }
        if needs_drive && self.win.is_none() { return self.toast("No Windows drive was found. Open Drives and press Refresh."); }
        if r.target && self.tgt.is_none() { self.auto_target(); }
        if r.target && self.tgt.is_none() { return self.toast("Pick a target drive first, on the Drives page."); }
        if r.confirm { self.confirm = Some(r); return; }
        self.exec(r);
    }

    fn confirm_text(&self, r: &Run) -> String {
        let mut m = format!("Run \"{}\"", r.label);
        if let Some(w) = self.win { if !NO_DRIVE.contains(&r.verb.as_str()) { m += &format!(" on {w}:"); } }
        if r.target { if let Some(t) = self.tgt { m += &format!(" and write to {t}:"); } }
        m += "?";
        if !r.option.is_empty() { m += &format!("\nOption: {}", r.option); }
        m
    }

    fn exec(&mut self, r: Run) {
        let mut cmd = Command::new("powershell.exe");
        cmd.arg("-NoProfile").arg("-ExecutionPolicy").arg("Bypass").arg("-File").arg(&self.cli).arg(&r.verb);
        if let Some(w) = self.win { if r.verb != "migrate-restore" { cmd.arg("-Drive").arg(w.to_string()); } }
        if r.target { if let Some(t) = self.tgt { cmd.arg("-Target").arg(t.to_string()); } }
        if !r.option.is_empty() { cmd.arg("-Option").arg(r.option.replace('"', "")); }
        cmd.arg("-Yes").stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
        #[cfg(windows)]
        { use std::os::windows::process::CommandExt; cmd.creation_flags(0x0800_0000); } // no console window
        self.log.push(String::new());
        self.log.push(format!("> {} {}", r.verb, r.option));
        self.follow_log = true;
        match cmd.spawn() {
            Ok(mut child) => {
                let (tx, rx) = channel();
                for pipe in [child.stdout.take().map(|p| Box::new(p) as Box<dyn std::io::Read + Send>),
                             child.stderr.take().map(|p| Box::new(p) as Box<dyn std::io::Read + Send>)].into_iter().flatten() {
                    let tx = tx.clone();
                    std::thread::spawn(move || {
                        let mut rd = BufReader::new(pipe);
                        let mut buf = Vec::new();
                        while rd.read_until(b'\n', &mut buf).map(|n| n > 0).unwrap_or(false) {
                            let line = String::from_utf8_lossy(&buf).trim_end_matches(['\r', '\n']).to_string();
                            if tx.send(line).is_err() { break; }
                            buf.clear();
                        }
                    });
                }
                self.job = Some(Job { child, rx, out: vec![], on_done: r.on_done, label: r.label, exited: None });
                self.status_until = f32::MAX;
            }
            Err(e) => {
                self.log.push(format!("Could not start PowerShell: {e}"));
                self.toast("Could not start the command. See Log.");
            }
        }
    }

    fn poll_job(&mut self) {
        let mut finished = false;
        if let Some(j) = self.job.as_mut() {
            loop {
                match j.rx.try_recv() {
                    Ok(l) => { self.log.push(l.clone()); j.out.push(l); }
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => { if j.exited.is_some() { finished = true; } break; }
                }
            }
            if j.exited.is_none() {
                if let Ok(Some(st)) = j.child.try_wait() { j.exited = Some(st.code().unwrap_or(-1)); }
            }
        }
        if finished {
            let j = self.job.take().unwrap();
            let code = j.exited.unwrap_or(-1);
            self.log.push(format!("[finished, exit code {code}]"));
            self.status_until = self.t + 6.0;
            if j.on_done == OnDone::Snaps {
                self.snaps.clear();
                self.snap_sel = None;
                for l in &j.out {
                    if let Some(rest) = l.strip_prefix("SNAP|") {
                        let p: Vec<&str> = rest.split('|').collect();
                        let g = |i: usize| p.get(i).map(|s| s.trim().to_string()).unwrap_or_default();
                        self.snaps.push(Snap { name: g(0), made: g(2), kind: g(3), size: g(4) });
                    }
                }
                if self.snaps.is_empty() { self.toast("No snapshots found on this Windows drive."); }
            }
            let _ = j.label;
        }
        if self.log.len() > 6000 { self.log.drain(0..1000); }
    }

    fn act(&mut self, a: Act) {
        self.focus = matches!(a, Act::Focus);
        match a {
            Act::Tab(i) => { if i != self.tab { self.tab = i; self.tab_t = 0.0; } }
            Act::Run(r) => self.start(r),
            Act::PickWin(l) => { self.win = Some(l); if self.tgt == Some(l) { self.tgt = None; } }
            Act::PickTgt(l) => { if Some(l) != self.win { self.tgt = Some(l); } else { self.toast("The target cannot be the Windows drive."); } }
            Act::Refresh => self.refresh_drives(),
            Act::Stop => {
                if let Some(j) = self.job.as_mut() { let _ = j.child.kill(); }
                self.log.push("[stopped]".into());
            }
            Act::Yes => { if let Some(r) = self.confirm.take() { self.exec(r); } }
            Act::No => { self.confirm = None; }
            Act::RpDec => { self.rp_num = (self.rp_num.max(2)) - 1; }
            Act::RpInc => { self.rp_num = (self.rp_num + 1).min(64); }
            Act::Snap(i) => { self.snap_sel = Some(i); }
            Act::SnapBack => match self.snap_sel.and_then(|i| self.snaps.get(i)) {
                Some(sn) => { let n = sn.name.clone(); self.start(Run::new("snap-restore", &n, false, true, &format!("Put snapshot {n} back"))); }
                None => self.toast("List snapshots, then pick one."),
            },
            Act::Focus => {}
            Act::OpenLog => { self.tab = LOG_TAB; self.tab_t = 0.0; self.follow_log = true; }
            Act::Classic => {
                // The PowerShell window still has the pages this one does not (New Windows, NVIDIA, Cable, Agent).
                let gui = self.cli.parent().and_then(|c| c.parent()).map(|r| r.join("gui").join("RescueGUI.ps1"));
                let started = gui.filter(|g| g.exists()).map(|g| Command::new("powershell.exe")
                    .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]).arg(g).spawn().is_ok()).unwrap_or(false);
                if started { self.toast("Opening the classic window..."); } else { self.toast("Could not find gui\\RescueGUI.ps1."); }
            }
            Act::Block => {}
        }
    }

    // ------------------------------------------------------------ input

    fn hit_at(&self, x: f32, y: f32) -> Option<&Hit> {
        self.hits.iter().rev().find(|h| x >= h.x && x < h.x + h.w && y >= h.y && y < h.y + h.h)
    }

    fn content_rect(&self) -> (f32, f32, f32, f32) {
        let s = self.s;
        let sb = self.sidebar_w();
        let x = 16.0 * s + sb + 16.0 * s;
        (x, 0.0, self.w - x - 16.0 * s, self.h)
    }

    fn sidebar_w(&self) -> f32 { if self.w / self.s < 880.0 { 78.0 * self.s } else { 236.0 * self.s } }

    pub fn mouse_move(&mut self, x: f32, y: f32) {
        self.mouse = (x, y);
        let t = self.t;
        let s = self.s;
        if let Some(p) = self.press.as_mut() {
            if let Some(tab) = p.scroll_tab {
                if !p.dragging && (y - p.y).abs() > 8.0 * s { p.dragging = true; p.id = None; p.act = None; }
                if p.dragging {
                    let sc = &mut self.scroll[tab];
                    let mut np = p.start_pos - (y - p.y);
                    // rubber band past either end
                    if np < 0.0 { np *= 0.35; } else if np > sc.max { np = sc.max + (np - sc.max) * 0.35; }
                    sc.pos = np;
                    sc.shown = t;
                    let dt = (t - p.last_t).max(1.0 / 240.0);
                    p.vel = p.vel * 0.6 + (-(y - p.last_y) / dt) * 0.4;
                    p.last_y = y;
                    p.last_t = t;
                    if tab == LOG_TAB { self.follow_log = false; }
                }
            }
        }
    }

    pub fn mouse_down(&mut self, x: f32, y: f32) {
        self.mouse = (x, y);
        let (id, act) = match self.hit_at(x, y) { Some(h) => (Some(h.id), Some(h.act.clone())), None => (None, None) };
        let (cx, _, cw, _) = self.content_rect();
        let in_content = x >= cx && x < cx + cw && self.confirm.is_none() && !matches!(act, Some(Act::Block));
        let tab = self.tab;
        self.press = Some(Press { x, y, id, act, scroll_tab: if in_content { Some(tab) } else { None }, dragging: false,
            start_pos: self.scroll[tab].pos, last_y: y, last_t: self.t, vel: 0.0 });
        self.scroll[tab].vel = 0.0;
    }

    pub fn mouse_up(&mut self, x: f32, y: f32) {
        if let Some(p) = self.press.take() {
            if p.dragging {
                if let Some(tab) = p.scroll_tab { self.scroll[tab].vel = p.vel.clamp(-6000.0, 6000.0); }
                return;
            }
            let now = self.hit_at(x, y).map(|h| h.id);
            match (p.act, now) {
                (Some(a), Some(n)) if Some(n) == p.id => self.act(a),
                _ => { self.focus = false; }
            }
        }
    }

    pub fn wheel(&mut self, notches: f32) {
        if self.confirm.is_some() { return; }
        let tab = self.tab;
        let sc = &mut self.scroll[tab];
        sc.vel += -notches * 1500.0 * self.s;
        sc.shown = self.t;
        if tab == LOG_TAB && notches > 0.0 { self.follow_log = false; }
    }

    pub fn key_char(&mut self, c: char) {
        if !self.focus { return; }
        match c {
            '\u{8}' => { self.option.pop(); }
            '\r' | '\n' | '\u{1b}' => { self.focus = false; }
            c if !c.is_control() && self.option.chars().count() < 200 => self.option.push(c),
            _ => {}
        }
    }

    /// Returns true when the app should close.
    pub fn key_down(&mut self, vk: u32) -> bool {
        const VK_RETURN: u32 = 0x0D; const VK_ESCAPE: u32 = 0x1B; const VK_PRIOR: u32 = 0x21; const VK_NEXT: u32 = 0x22;
        const VK_UP: u32 = 0x26; const VK_DOWN: u32 = 0x28; const VK_TAB: u32 = 0x09;
        if self.confirm.is_some() {
            match vk { VK_RETURN => self.act(Act::Yes), VK_ESCAPE => self.act(Act::No), _ => {} }
            return false;
        }
        if self.focus { return false; }
        match vk {
            VK_UP => self.wheel(0.6), VK_DOWN => self.wheel(-0.6),
            VK_PRIOR => self.wheel(3.0), VK_NEXT => self.wheel(-3.0),
            VK_TAB => self.act(Act::Tab((self.tab + 1) % TABS.len())),
            0x31..=0x35 => self.act(Act::Tab((vk - 0x31) as usize)),
            _ => {}
        }
        false
    }

    // ------------------------------------------------------------ frame

    pub fn update(&mut self, dt: f32) {
        self.t += dt;
        self.poll_job();
        self.tab_t = (self.tab_t + dt / 0.32).min(1.0);
        let dragging_tab = self.press.as_ref().filter(|p| p.dragging).and_then(|p| p.scroll_tab);
        for (i, sc) in self.scroll.iter_mut().enumerate() {
            if dragging_tab == Some(i) { continue; }
            sc.pos += sc.vel * dt;
            sc.vel *= (-dt * 4.2).exp();
            if sc.vel.abs() < 4.0 { sc.vel = 0.0; }
            // spring back from overscroll
            let k = 1.0 - (-dt * 13.0).exp();
            if sc.pos < 0.0 { sc.pos += (0.0 - sc.pos) * k; if sc.vel < 0.0 { sc.vel *= 0.55; } }
            if sc.pos > sc.max { sc.pos += (sc.max - sc.pos) * k; if sc.vel > 0.0 { sc.vel *= 0.55; } }
            if sc.vel != 0.0 { sc.shown = self.t; }
        }
        // the menu highlight chases the chosen item like a drop of liquid
        let target = self.tab as f32;
        let (k, d) = (240.0, 26.0);
        let acc = k * (target - self.sel_y) - d * self.sel_v;
        self.sel_v += acc * dt;
        self.sel_y += self.sel_v * dt;
        if let Some((_, t0)) = &self.toast { if self.t - t0 > 3.5 { self.toast = None; } }
    }

    fn hit(&mut self, x: f32, y: f32, w: f32, h: f32, act: Act) -> (u32, f32) {
        let id = self.next_id;
        self.next_id += 1;
        self.hits.push(Hit { x, y, w, h, act, id });
        let (mx, my) = self.mouse;
        let over = mx >= x && mx < x + w && my >= y && my < y + h;
        let blocked = self.confirm.is_some() && !matches!(self.hits.last().unwrap().act, Act::Yes | Act::No);
        (id, if over && !blocked { 1.0 } else { 0.0 })
    }

    fn pressed(&self, id: u32) -> bool { self.press.as_ref().map_or(false, |p| p.id == Some(id) && !p.dragging) }

    pub fn draw(&mut self, pm: &mut Pixmap) {
        self.hits.clear();
        self.next_id = 0;
        gfx::scene(pm, self.t);
        let (cx, _, cw, ch) = self.content_rect();
        let s = self.s;
        let header_h = 68.0 * s;
        let top = 16.0 * s + header_h + 22.0 * s;
        // page content, scrolled, sliding in after a tab change
        let e = ease_out(self.tab_t);
        let slide = (1.0 - e) * 26.0 * s;
        let tab = self.tab;
        let pos = self.scroll[tab].pos;
        let content_h = if tab == LOG_TAB {
            self.page_log(pm, cx, top, cw, ch - top - 16.0 * s, pos)
        } else {
            self.page(pm, tab, cx, top + slide - pos, cw)
        };
        let view = ch - top - 16.0 * s;
        let bottom_pad = if self.status_visible() { 90.0 * s } else { 24.0 * s };
        self.scroll[tab].max = if tab == LOG_TAB { (content_h - view).max(0.0) } else { (content_h + bottom_pad - (ch - top)).max(0.0) };
        if tab == LOG_TAB && self.follow_log { self.scroll[tab].pos = self.scroll[tab].max; }
        self.scrollbar(pm, cx + cw - 7.0 * s, top, ch - top - 16.0 * s);
        self.header(pm, cx, 16.0 * s, cw, header_h);
        self.sidebar(pm);
        if self.status_visible() { self.status(pm, cx, cw); }
        if let Some((m, t0)) = self.toast.clone() { self.draw_toast(pm, &m, self.t - t0); }
        if self.confirm.is_some() { self.dialog(pm); }
    }

    fn status_visible(&self) -> bool { self.job.is_some() || self.t < self.status_until }

    // ------------------------------------------------------------ chrome

    fn sidebar(&mut self, pm: &mut Pixmap) {
        let s = self.s;
        let (x, y, w, h) = (16.0 * s, 16.0 * s, self.sidebar_w(), self.h - 32.0 * s);
        let compact = w < 120.0 * s;
        self.hit(x, y, w, h, Act::Block);
        gfx::glass(pm, x, y, w, h, 26.0 * s, s, &Glass { lens: 16.0 * s, saturate: 1.5, bright: 0.78, tint: [0.10, 0.07, 0.20, 0.30] }, 0.0, None);
        // brand
        let orb = 15.0 * s;
        let (ox, oy) = (x + if compact { w / 2.0 } else { 22.0 * s + orb }, y + 40.0 * s);
        gfx::fill_shader(pm, &Some(tiny_skia::PathBuilder::from_circle(ox, oy, orb).unwrap()),
            gfx::radial(ox - orb * 0.35, oy - orb * 0.4, orb * 1.6, vec![(0.0, col(WHITE, 0.95)), (0.35, col(MAGENTA, 0.95)), (0.7, col(VIOLET, 1.0)), (1.0, col(CYAN, 0.9))]));
        if !compact {
            self.fonts.draw(pm, ox + orb + 12.0 * s, oy - 21.0 * s, "Violet", 21.0 * s, Face::Bold, WHITE);
            self.fonts.draw(pm, ox + orb + 12.0 * s, oy + 1.0 * s, "Rescue", 21.0 * s, Face::Regular, DIM);
        }
        let item_h = 56.0 * s;
        let list_y = y + 92.0 * s;
        // liquid selection: stretches while it travels, settles round
        let travel = self.sel_v.abs().min(14.0);
        let stretch = travel * 4.0 * s;
        let py = list_y + self.sel_y * item_h + 4.0 * s - stretch * 0.5;
        let (px, pw) = (x + 10.0 * s, w - 20.0 * s);
        let ph = item_h - 8.0 * s + stretch;
        gfx::glass(pm, px, py, pw, ph, (item_h - 8.0 * s) / 2.0, s,
            &Glass { lens: 10.0 * s, saturate: 1.9, bright: 1.25, tint: [0.54, 0.42, 1.0, 0.22] }, 0.6, None);
        for (i, (name, ic)) in TABS.iter().enumerate() {
            let iy = list_y + i as f32 * item_h;
            let (id, hov) = self.hit(x + 8.0 * s, iy, w - 16.0 * s, item_h, Act::Tab(i));
            let on = i == self.tab;
            if hov > 0.0 && !on {
                gfx::fill(pm, &gfx::rrect(px, iy + 4.0 * s, pw, item_h - 8.0 * s, (item_h - 8.0 * s) / 2.0), Color::from_rgba(1.0, 1.0, 1.0, if self.pressed(id) { 0.12 } else { 0.07 }).unwrap());
            }
            let c = if on { WHITE } else { DIM };
            let icx = if compact { x + w / 2.0 } else { px + 30.0 * s };
            gfx::icon(pm, *ic, icx, iy + item_h / 2.0, 22.0 * s, c);
            if !compact {
                let label = if i == LOG_TAB && self.job.is_some() { "Log  (running)" } else { name };
                self.fonts.draw(pm, px + 56.0 * s, iy + item_h / 2.0 - 11.0 * s, label, 17.0 * s, if on { Face::Bold } else { Face::Regular }, c);
            }
        }
        if !compact {
            let fy = y + h - 58.0 * s;
            self.fonts.draw(pm, x + 22.0 * s, fy, "Wheel, drag or arrows", 13.0 * s, Face::Regular, [1., 1., 1., 0.45]);
            self.fonts.draw(pm, x + 22.0 * s, fy + 19.0 * s, "to scroll.  Tab: next page", 13.0 * s, Face::Regular, [1., 1., 1., 0.45]);
        }
    }

    fn header(&mut self, pm: &mut Pixmap, x: f32, y: f32, w: f32, h: f32) {
        let s = self.s;
        self.hit(x, y, w, h, Act::Block);
        gfx::glass(pm, x, y, w, h, h / 2.0, s, &Glass { lens: 14.0 * s, saturate: 1.6, bright: 0.85, tint: [0.10, 0.08, 0.18, 0.22] }, 0.0, None);
        let title = TABS[self.tab].0;
        self.fonts.draw(pm, x + 28.0 * s, y + h / 2.0 - 15.0 * s, title, 25.0 * s, Face::Bold, WHITE);
        // drive chips on the right; a tap opens the Drives page
        let win = match self.win { Some(l) => format!("Windows  {l}:"), None => "Windows  not found".into() };
        let tgt = match self.tgt { Some(l) => format!("Target  {l}:"), None => "Target  auto".into() };
        let mut cx = x + w - 14.0 * s;
        for (txt, warn) in [(tgt, false), (win, self.win.is_none())] {
            let tw = self.fonts.measure(&txt, 15.0 * s, Face::Bold) + 34.0 * s;
            cx -= tw;
            if cx < x + 200.0 * s { break; }
            let (id, hov) = self.hit(cx, y + 12.0 * s, tw, h - 24.0 * s, Act::Tab(DRIVES_TAB));
            let r = (h - 24.0 * s) / 2.0;
            gfx::fill(pm, &gfx::rrect(cx, y + 12.0 * s, tw, h - 24.0 * s, r),
                if warn { col(DANGER, 0.30) } else { Color::from_rgba(1.0, 1.0, 1.0, 0.08 + hov * 0.08 + if self.pressed(id) { 0.08 } else { 0.0 }).unwrap() });
            gfx::stroke(pm, &gfx::rrect(cx + 0.5, y + 12.5 * s, tw - 1.0, h - 25.0 * s, r), Color::from_rgba(1.0, 1.0, 1.0, 0.22).unwrap(), 1.0);
            self.fonts.draw(pm, cx + 17.0 * s, y + h / 2.0 - 10.0 * s, &txt, 15.0 * s, Face::Bold, WHITE);
            cx -= 10.0 * s;
        }
    }

    fn scrollbar(&mut self, pm: &mut Pixmap, x: f32, y: f32, h: f32) {
        let sc = self.scroll[self.tab];
        if sc.max <= 1.0 { return; }
        let since = self.t - sc.shown;
        let a = if self.press.as_ref().map_or(false, |p| p.dragging) { 1.0 } else { (1.0 - (since - 0.8) / 0.5).clamp(0.0, 1.0) };
        if a <= 0.0 { return; }
        let view = h;
        let total = view + sc.max;
        let mut th = (view / total * view).max(36.0 * self.s);
        let mut ty = y + (sc.pos / sc.max).clamp(0.0, 1.0) * (view - th);
        if sc.pos < 0.0 { th += sc.pos * 0.5; ty = y; } else if sc.pos > sc.max { th -= (sc.pos - sc.max) * 0.5; ty = y + view - th; }
        let s = self.s;
        gfx::fill(pm, &gfx::rrect(x, ty, 5.0 * s, th.max(10.0 * s), 2.5 * s), Color::from_rgba(1.0, 1.0, 1.0, 0.55 * a).unwrap());
    }

    fn status(&mut self, pm: &mut Pixmap, cx: f32, cw: f32) {
        let s = self.s;
        let w = cw.min(760.0 * s);
        let h = 60.0 * s;
        let x = cx + (cw - w) / 2.0;
        let y = self.h - h - 22.0 * s;
        self.hit(x, y, w, h, Act::Block);
        gfx::glass(pm, x, y, w, h, h / 2.0, s, &Glass { lens: 14.0 * s, saturate: 1.7, bright: 0.8, tint: [0.12, 0.08, 0.24, 0.35] }, 0.0, None);
        let running = self.job.is_some() || (self.demo && self.t < self.status_until);
        if running { gfx::spinner(pm, x + 32.0 * s, y + h / 2.0, 11.0 * s, self.t, 3.0 * s); } else { gfx::icon(pm, Icon::Check, x + 32.0 * s, y + h / 2.0, 22.0 * s, CYAN); }
        let label = match &self.job { Some(j) => j.label.clone(), None => if self.demo { "Check restore points".into() } else { "Finished".into() } };
        let last = self.log.iter().rev().find(|l| !l.trim().is_empty()).cloned().unwrap_or_default();
        let bw = 92.0 * s;
        let text_w = w - 64.0 * s - (bw + 12.0 * s) * if running { 2.0 } else { 1.0 } - 16.0 * s;
        let l1 = self.fonts.fit(&label, 16.0 * s, Face::Bold, text_w);
        self.fonts.draw(pm, x + 56.0 * s, y + 9.0 * s, &l1, 16.0 * s, Face::Bold, WHITE);
        let l2 = self.fonts.fit(last.trim(), 13.5 * s, Face::Regular, text_w);
        self.fonts.draw(pm, x + 56.0 * s, y + 32.0 * s, &l2, 13.5 * s, Face::Regular, DIM);
        let mut bx = x + w - bw - 12.0 * s;
        self.pill(pm, bx, y + 10.0 * s, bw, h - 20.0 * s, "Log", Some(Icon::Log), Act::OpenLog, 0);
        if running {
            bx -= bw + 10.0 * s;
            self.pill(pm, bx, y + 10.0 * s, bw, h - 20.0 * s, "Stop", Some(Icon::Stop), Act::Stop, 2);
        }
    }

    fn draw_toast(&mut self, pm: &mut Pixmap, m: &str, age: f32) {
        let s = self.s;
        let a = ease_out(age / 0.25) * (1.0 - ((age - 3.0) / 0.5).clamp(0.0, 1.0));
        if a <= 0.01 { return; }
        let tw = self.fonts.measure(m, 16.0 * s, Face::Bold).min(self.w - 120.0 * s);
        let (w, h) = (tw + 48.0 * s, 52.0 * s);
        let (cx, _, cw, _) = self.content_rect();
        let x = cx + (cw - w) / 2.0;
        let y = 16.0 * s + 68.0 * s + 14.0 * s - (1.0 - a) * 20.0 * s;
        gfx::glass(pm, x, y, w, h, h / 2.0, s, &Glass { lens: 12.0 * s, saturate: 1.8, bright: 0.9, tint: [0.35, 0.18, 0.55, 0.40] }, 0.0, None);
        let t = self.fonts.fit(m, 16.0 * s, Face::Bold, tw);
        self.fonts.draw(pm, x + 24.0 * s, y + h / 2.0 - 11.0 * s, &t, 16.0 * s, Face::Bold, [1., 1., 1., a]);
    }

    fn dialog(&mut self, pm: &mut Pixmap) {
        let s = self.s;
        let r = self.confirm.clone().unwrap();
        self.hit(0.0, 0.0, self.w, self.h, Act::Block);
        gfx::fill(pm, &gfx::rrect(0.0, 0.0, self.w, self.h, 0.0), Color::from_rgba(0.01, 0.0, 0.04, 0.50).unwrap());
        let w = (580.0 * s).min(self.w - 40.0 * s);
        let msg = self.confirm_text(&r);
        let lines = self.fonts.wrap(&msg, 17.0 * s, Face::Regular, w - 64.0 * s);
        let h = 150.0 * s + lines.len() as f32 * 25.0 * s + 40.0 * s;
        let (x, y) = ((self.w - w) / 2.0, (self.h - h) / 2.0);
        gfx::glass(pm, x, y, w, h, 30.0 * s, s, &Glass { lens: 20.0 * s, saturate: 1.6, bright: 0.72, tint: [0.10, 0.06, 0.20, 0.40] }, 0.0, None);
        self.fonts.draw(pm, x + 32.0 * s, y + 28.0 * s, "Are you sure?", 25.0 * s, Face::Bold, WHITE);
        let mut ly = y + 72.0 * s;
        for l in &lines { self.fonts.draw(pm, x + 32.0 * s, ly, l, 17.0 * s, Face::Regular, DIM); ly += 25.0 * s; }
        self.fonts.draw(pm, x + 32.0 * s, ly + 4.0 * s, "Enter = Yes    Esc = No", 13.0 * s, Face::Regular, [1., 1., 1., 0.45]);
        let bw = (w - 64.0 * s - 14.0 * s) / 2.0;
        let by = y + h - 76.0 * s;
        self.pill(pm, x + 32.0 * s, by, bw, 52.0 * s, "No, go back", None, Act::No, 0);
        self.pill(pm, x + 32.0 * s + bw + 14.0 * s, by, bw, 52.0 * s, "Yes, run it", Some(Icon::Check), Act::Yes, 1);
    }

    /// Capsule button. kind: 0 glass, 1 primary (violet), 2 danger, 3 selected chip.
    fn pill(&mut self, pm: &mut Pixmap, x: f32, y: f32, w: f32, h: f32, label: &str, ic: Option<Icon>, act: Act, kind: u8) {
        let s = self.s;
        let (id, hov) = self.hit(x, y, w, h, act);
        let down = self.pressed(id);
        let (x, y, w, h) = if down { (x + w * 0.02, y + h * 0.04, w * 0.96, h * 0.92) } else { (x, y, w, h) };
        let r = h / 2.0;
        let tint: Rgba = match kind { 1 => [0.54, 0.42, 1.0, 0.55], 2 => [1.0, 0.30, 0.38, 0.45], 3 => [0.31, 0.65, 1.0, 0.45], _ => [0.12, 0.10, 0.22, 0.20] };
        gfx::glass(pm, x, y, w, h, r, s, &Glass { lens: 8.0 * s, saturate: 1.6, bright: 1.0 + hov * 0.1, tint }, hov, Some(self.mouse));
        if kind == 1 {
            gfx::fill_shader(pm, &gfx::rrect(x, y, w, h, r), gfx::hgrad(x, x + w, vec![(0.0, col(VIOLET, 0.35)), (1.0, col(CYAN, 0.18))]));
        }
        let fs = 16.0 * s;
        let tw = self.fonts.measure(label, fs, Face::Bold) + if ic.is_some() { 28.0 * s } else { 0.0 };
        let mut tx = x + (w - tw) / 2.0;
        if let Some(i) = ic { gfx::icon(pm, i, tx + 10.0 * s, y + h / 2.0, 18.0 * s, WHITE); tx += 28.0 * s; }
        let label = self.fonts.fit(label, fs, Face::Bold, w - 20.0 * s);
        self.fonts.draw(pm, tx, y + h / 2.0 - 11.0 * s, &label, fs, Face::Bold, WHITE);
    }

    fn pill_w(&self, label: &str, ic: bool) -> f32 { self.fonts.measure(label, 16.0 * self.s, Face::Bold) + 44.0 * self.s + if ic { 28.0 * self.s } else { 0.0 } }

    // ------------------------------------------------------------ pages

    fn section(&mut self, pm: &mut Pixmap, x: f32, y: f32, w: f32, title: &str, sub: &str) -> f32 {
        let s = self.s;
        let mut yy = y;
        if !title.is_empty() {
            if self.visible(yy, 30.0 * s) { self.fonts.draw(pm, x + 4.0 * s, yy, title, 19.0 * s, Face::Bold, WHITE); }
            yy += 30.0 * s;
        }
        if !sub.is_empty() {
            for l in self.fonts.wrap(sub, 15.0 * s, Face::Regular, w - 8.0 * s) {
                if self.visible(yy, 22.0 * s) { self.fonts.draw(pm, x + 4.0 * s, yy, &l, 15.0 * s, Face::Regular, DIM); }
                yy += 22.0 * s;
            }
        }
        yy + 12.0 * s - y
    }

    fn visible(&self, y: f32, h: f32) -> bool { y + h > 0.0 && y < self.h }

    /// Grid of big glass tiles. Returns the height used.
    fn tiles(&mut self, pm: &mut Pixmap, x: f32, y: f32, w: f32, items: Vec<(Option<String>, String, String, Act, bool)>, min_col: f32) -> f32 {
        let s = self.s;
        let gap = 16.0 * s;
        let cols = ((w + gap) / (min_col * s + gap)).floor().clamp(1.0, 3.0) as usize;
        let tw = (w - gap * (cols as f32 - 1.0)) / cols as f32;
        let mut yy = y;
        for row in items.chunks(cols) {
            let text_w = |has_num: bool| tw - 40.0 * s - if has_num { 58.0 * s } else { 0.0 };
            let rh = row.iter().map(|it| {
                let n = if it.2.is_empty() { 0 } else { self.fonts.wrap(&it.2, 14.5 * s, Face::Regular, text_w(it.0.is_some())).len() };
                (44.0 * s + 28.0 * s + n as f32 * 21.0 * s).max(92.0 * s)
            }).fold(0.0, f32::max);
            for (ci, (num, title, sub, act, primary)) in row.iter().enumerate() {
                let tx = x + ci as f32 * (tw + gap);
                if !self.visible(yy - 20.0 * s, rh + 40.0 * s) { self.hit(tx, yy, tw, rh, act.clone()); continue; }
                let (id, hov) = self.hit(tx, yy, tw, rh, act.clone());
                let down = self.pressed(id);
                let (bx, by, bw, bh) = if down { (tx + tw * 0.012, yy + rh * 0.02, tw * 0.976, rh * 0.96) } else { (tx, yy, tw, rh) };
                let r = 24.0 * s;
                if *primary {
                    // breathing halo marks the one to try first
                    let pulse = 0.5 + 0.5 * (self.t * 2.2).sin();
                    for k in 0..4 {
                        let e = (k as f32 + 1.0) * 3.0 * s;
                        gfx::fill(pm, &gfx::rrect(bx - e, by - e, bw + e * 2.0, bh + e * 2.0, r + e), col(VIOLET, 0.05 + 0.04 * pulse));
                    }
                }
                let tint: Rgba = if *primary { [0.54, 0.42, 1.0, 0.30] } else { [0.10, 0.08, 0.20, 0.22] };
                gfx::glass(pm, bx, by, bw, bh, r, s, &Glass { lens: 10.0 * s, saturate: 1.5, bright: 0.9 + hov * 0.12, tint }, hov, Some(self.mouse));
                let mut txx = bx + 22.0 * s;
                if let Some(n) = num {
                    let cr = 19.0 * s;
                    let (ccx, ccy) = (bx + 22.0 * s + cr, by + 22.0 * s + cr);
                    let circ = Some(tiny_skia::PathBuilder::from_circle(ccx, ccy, cr).unwrap());
                    if *primary {
                        gfx::fill_shader(pm, &circ, gfx::radial(ccx - cr * 0.4, ccy - cr * 0.5, cr * 1.8, vec![(0.0, col(WHITE, 0.9)), (0.4, col(VIOLET, 1.0)), (1.0, col(CYAN, 1.0))]));
                    } else {
                        gfx::fill(pm, &circ, Color::from_rgba(1.0, 1.0, 1.0, 0.12).unwrap());
                        gfx::stroke(pm, &circ, Color::from_rgba(1.0, 1.0, 1.0, 0.30).unwrap(), 1.0);
                    }
                    let nw = self.fonts.measure(n, 18.0 * s, Face::Bold);
                    self.fonts.draw(pm, ccx - nw / 2.0, ccy - 12.5 * s, n, 18.0 * s, Face::Bold, WHITE);
                    txx += 58.0 * s;
                }
                let tw2 = text_w(num.is_some());
                let t1 = self.fonts.fit(title, 19.0 * s, Face::Bold, tw2);
                self.fonts.draw(pm, txx, by + 22.0 * s, &t1, 19.0 * s, Face::Bold, WHITE);
                let mut ly = by + 22.0 * s + 30.0 * s;
                for l in self.fonts.wrap(sub, 14.5 * s, Face::Regular, tw2) {
                    self.fonts.draw(pm, txx, ly, &l, 14.5 * s, Face::Regular, DIM);
                    ly += 21.0 * s;
                }
            }
            yy += rh + gap;
        }
        yy - y
    }

    /// Flow of capsule buttons. Returns height used.
    fn pills(&mut self, pm: &mut Pixmap, x: f32, y: f32, w: f32, items: Vec<(String, Option<Icon>, Act, u8)>) -> f32 {
        let s = self.s;
        let h = 50.0 * s;
        let gap = 12.0 * s;
        let (mut px, mut py) = (x, y);
        for (label, ic, act, kind) in items {
            let pw = self.pill_w(&label, ic.is_some()).min(w);
            if px > x && px + pw > x + w { px = x; py += h + gap; }
            if self.visible(py - 20.0 * s, h + 40.0 * s) { self.pill(pm, px, py, pw, h, &label, ic, act, kind); } else { self.hit(px, py, pw, h, act); }
            px += pw + gap;
        }
        py + h + gap - y
    }

    fn page(&mut self, pm: &mut Pixmap, tab: usize, x: f32, y0: f32, w: f32) -> f32 {
        let s = self.s;
        let w = w - 14.0 * s; // room for the scroll indicator
        let mut y = y0;
        match tab {
            0 => {
                y += self.section(pm, x, y, w, "Go down the list", "The glowing one is the one to try first. Each one asks before it changes anything.");
                let items = FIX.iter().enumerate().map(|(i, f)| (Some((i + 1).to_string()), f.1.to_string(), f.2.to_string(),
                    Act::Run(Run::new(f.0, "", f.3, f.4, f.1)), i == 0)).collect();
                y += self.tiles(pm, x, y, w, items, 330.0);
            }
            1 => {
                y += self.section(pm, x, y, w, "From this USB", "When Windows will not start or System Restore fails.");
                let n = self.rp_num;
                let items = vec![
                    (None, "Safer System Restore".to_string(), "System Restore with the parts that usually make it fail moved aside first.".to_string(),
                        Act::Run(Run::new("restore-safe", "", false, true, "Safer System Restore")), true),
                    (None, format!("Registry from restore point {n}"), "Change the number with - and + below. Checks the copy loads before using it.".to_string(),
                        Act::Run(Run::new("rp-shadow-restore", &n.to_string(), false, true, &format!("Registry from restore point {n}"))), false),
                    (None, "Put WindowsApps back".to_string(), "Undo the move that Safer System Restore made.".to_string(),
                        Act::Run(Run::new("restore-safe", "undo", false, true, "Put WindowsApps back")), false),
                ];
                y += self.tiles(pm, x, y, w, items, 300.0);
                y += self.pills(pm, x, y, w, vec![
                    (String::new(), Some(Icon::Minus), Act::RpDec, 0),
                    (format!("Restore point {n}"), None, Act::Block, 3),
                    (String::new(), Some(Icon::Plus), Act::RpInc, 0),
                ]) + 14.0 * s;
                y += self.section(pm, x, y, w, "Violet snapshots", "Saved copies of the registry. They work without System Restore.");
                let mut list = vec![(String::from("List snapshots"), Some(Icon::Refresh), Act::Run(Run { on_done: OnDone::Snaps, ..Run::new("snap-list", "", false, false, "List snapshots") }), 0u8),
                                    ("Make snapshot now".into(), None, Act::Run(Run::new("snap-make", "", false, false, "Snapshot")), 0)];
                list.push(("Put selected back".into(), Some(Icon::Restore), Act::SnapBack, 1));
                y += self.pills(pm, x, y, w, list);
                y += self.snap_list(pm, x, y, w) + 18.0 * s;
                y += self.section(pm, x, y, w, "Inside Windows", "Make System Restore work again and keep a snapshot every day.");
                y += self.pills(pm, x, y, w, vec![
                    ("Check restore points".into(), None, Act::Run(Run::new("rp-check", "", false, false, "Check restore points")), 0),
                    ("Fix System Restore".into(), None, Act::Run(Run::new("rp-fix", "", false, true, "Fix System Restore")), 1),
                    ("Automatic daily".into(), None, Act::Run(Run::new("rp-auto", "5", false, true, "Daily restore point + snapshot, keep 5")), 0),
                    ("Make one now".into(), None, Act::Run(Run::new("rp-make", "", false, false, "Restore point + snapshot now")), 0),
                    ("Start fresh".into(), None, Act::Run(Run::new("rp-reset", "", false, true, "DELETE all restore points and start fresh")), 2),
                ]);
            }
            2 => {
                y += self.section(pm, x, y, w, "Option", "Only some buttons use it (their card says so). Leave it empty for the rest.");
                y += self.option_field(pm, x, y, w) + 20.0 * s;
                let opt = self.option.clone();
                let items = REPAIR.iter().map(|r| (None, r.1.to_string(),
                    if r.2.is_empty() { if r.4 { "Asks before it changes anything.".into() } else { "Only reads.".into() } } else { r.2.to_string() },
                    Act::Run(Run::new(r.0, if r.2.is_empty() { "" } else { &opt }, r.3, r.4, r.1)), false)).collect();
                y += self.tiles(pm, x, y, w, items, 250.0);
            }
            3 => {
                y += self.section(pm, x, y, w, "Windows drive", "The drive with the broken Windows on it. Found by itself when there is one.");
                let wins: Vec<(String, Option<Icon>, Act, u8)> = self.drives.iter().filter(|d| d.has_win)
                    .map(|d| (format!("{}:  {}  {:.0} GB", d.letter, d.label, d.gb), Some(Icon::Drive), Act::PickWin(d.letter), if Some(d.letter) == self.win { 3 } else { 0 })).collect();
                if wins.is_empty() { y += self.section(pm, x, y, w, "", "None found. If the disk is NVMe or RAID, install its driver from Repair tools."); } else { y += self.pills(pm, x, y, w, wins) + 10.0 * s; }
                y += self.section(pm, x, y, w, "Target drive", "Where copies and downloads go. Leave it and the roomiest other drive is used.");
                let tg: Vec<(String, Option<Icon>, Act, u8)> = self.drives.iter().filter(|d| !d.has_win || Some(d.letter) != self.win)
                    .map(|d| (format!("{}:  {}  {:.0} GB free{}", d.letter, d.label, d.free, if d.is_stick { "  (this stick)" } else { "" }), None, Act::PickTgt(d.letter), if Some(d.letter) == self.tgt { 3 } else { 0 })).collect();
                y += self.pills(pm, x, y, w, tg) + 10.0 * s;
                y += self.pills(pm, x, y, w, vec![("Refresh drives".into(), Some(Icon::Refresh), Act::Refresh, 1)]) + 18.0 * s;
                y += self.section(pm, x, y, w, "More tools", "Fresh Windows, moving files, NVIDIA drivers, cable link and agent help are in the classic window for now.");
                y += self.pills(pm, x, y, w, vec![("Open classic window".into(), None, Act::Classic, 0)]);
            }
            _ => {}
        }
        y - y0
    }

    fn snap_list(&mut self, pm: &mut Pixmap, x: f32, y: f32, w: f32) -> f32 {
        let s = self.s;
        let row_h = 46.0 * s;
        let n = self.snaps.len().max(1);
        let h = n as f32 * row_h + 16.0 * s;
        if self.visible(y, h) {
            gfx::glass(pm, x, y, w, h, 22.0 * s, s, &Glass { lens: 8.0 * s, saturate: 1.4, bright: 0.7, tint: [0.06, 0.05, 0.12, 0.35] }, 0.0, None);
        }
        if self.snaps.is_empty() {
            self.fonts.draw(pm, x + 22.0 * s, y + 8.0 * s + row_h / 2.0 - 11.0 * s, "Press List snapshots to see them here.", 15.0 * s, Face::Regular, DIM);
            return h;
        }
        for i in 0..self.snaps.len() {
            let ry = y + 8.0 * s + i as f32 * row_h;
            let (id, hov) = self.hit(x + 8.0 * s, ry, w - 16.0 * s, row_h, Act::Snap(i));
            if !self.visible(ry, row_h) { continue; }
            let on = self.snap_sel == Some(i);
            if on {
                gfx::glass(pm, x + 8.0 * s, ry + 3.0 * s, w - 16.0 * s, row_h - 6.0 * s, (row_h - 6.0 * s) / 2.0, s,
                    &Glass { lens: 8.0 * s, saturate: 1.9, bright: 1.2, tint: [0.54, 0.42, 1.0, 0.35] }, 0.5, None);
            } else if hov > 0.0 || self.pressed(id) {
                gfx::fill(pm, &gfx::rrect(x + 8.0 * s, ry + 3.0 * s, w - 16.0 * s, row_h - 6.0 * s, (row_h - 6.0 * s) / 2.0), Color::from_rgba(1.0, 1.0, 1.0, 0.07).unwrap());
            }
            let sn = &self.snaps[i];
            let (name, made, kind, size) = (sn.name.clone(), sn.made.clone(), sn.kind.clone(), sn.size.clone());
            // centre on cap height: Consolas and Segoe UI have very different ascents
            let fs = 14.5 * s;
            let mid = ry + row_h / 2.0 + 0.36 * fs;
            let col1 = (w * 0.48).max(180.0 * s);
            let nm = self.fonts.fit(&name, fs, Face::Mono, col1 - 30.0 * s);
            let ty_m = mid - self.fonts.ascent(fs, Face::Mono);
            self.fonts.draw(pm, x + 26.0 * s, ty_m, &nm, fs, Face::Mono, WHITE);
            let rest = format!("{made}   {kind}   {size}");
            let rs = self.fonts.fit(&rest, fs, Face::Regular, w - col1 - 40.0 * s);
            let ty_r = mid - self.fonts.ascent(fs, Face::Regular);
            self.fonts.draw(pm, x + col1, ty_r, &rs, fs, Face::Regular, if on { WHITE } else { DIM });
        }
        h
    }

    fn option_field(&mut self, pm: &mut Pixmap, x: f32, y: f32, w: f32) -> f32 {
        let s = self.s;
        let h = 54.0 * s;
        let (_, hov) = self.hit(x, y, w, h, Act::Focus);
        if !self.visible(y, h) { return h; }
        let tint: Rgba = if self.focus { [0.54, 0.42, 1.0, 0.28] } else { [0.05, 0.04, 0.10, 0.40] };
        gfx::glass(pm, x, y, w, h, h / 2.0, s, &Glass { lens: 8.0 * s, saturate: 1.3, bright: 0.8, tint }, hov * 0.5, None);
        let ty = y + h / 2.0 - 11.0 * s;
        if self.option.is_empty() && !self.focus {
            self.fonts.draw(pm, x + 24.0 * s, ty, "Click here to type an option (most buttons do not need one)", 16.0 * s, Face::Regular, [1., 1., 1., 0.45]);
        } else {
            let shown = self.option.clone();
            let tw = self.fonts.draw(pm, x + 24.0 * s, ty, &shown, 16.0 * s, Face::Regular, WHITE);
            if self.focus && (self.t * 2.0).fract() < 0.6 {
                gfx::fill(pm, &gfx::rrect(x + 26.0 * s + tw, y + 15.0 * s, 2.0 * s, h - 30.0 * s, 1.0), col(WHITE, 0.9));
            }
        }
        h
    }

    fn page_log(&mut self, pm: &mut Pixmap, x: f32, y: f32, w: f32, h: f32, pos: f32) -> f32 {
        let s = self.s;
        let w = w - 14.0 * s;
        gfx::glass(pm, x, y, w, h, 24.0 * s, s, &Glass { lens: 10.0 * s, saturate: 1.2, bright: 0.45, tint: [0.03, 0.02, 0.07, 0.45] }, 0.0, None);
        let lh = 21.0 * s;
        let fs = 14.5 * s;
        let pad = 18.0 * s;
        let total = self.log.len() as f32 * lh + pad * 2.0 + if self.status_visible() { 80.0 * s } else { 0.0 };
        let first = ((pos - pad) / lh).floor().max(0.0) as usize;
        let rows = (h / lh).ceil() as usize + 2;
        let inner_top = y + 6.0 * s;
        let inner_bot = y + h - 6.0 * s;
        for i in first..(first + rows).min(self.log.len()) {
            let ly = y + pad + i as f32 * lh - pos;
            if ly < inner_top || ly + lh > inner_bot { continue; } // keep text inside the panel
            let line = self.log[i].clone();
            let c = if line.starts_with("> ") { CYAN } else if line.starts_with("[finished") { [0.6, 1.0, 0.75, 0.9] }
                else if line.contains("ERROR") || line.starts_with("[stopped") { DANGER } else { [0.92, 0.90, 1.0, 0.88] };
            let t = self.fonts.fit(&line, fs, Face::Mono, w - pad * 2.0);
            self.fonts.draw(pm, x + pad, ly, &t, fs, if line.starts_with("> ") { Face::Bold } else { Face::Mono }, c);
        }
        total
    }
}
