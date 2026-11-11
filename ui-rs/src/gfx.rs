//! Software drawing: fonts, rounded shapes, the animated backdrop and the liquid-glass material.
//! Everything lands in one tiny-skia Pixmap that main.rs blits to the window with GDI,
//! because WinRE has no GPU driver and no desktop compositor to borrow blur from.

use std::collections::HashMap;
use std::path::PathBuf;
use tiny_skia::*;

pub type Rgba = [f32; 4];

pub const WHITE: Rgba = [1.0, 1.0, 1.0, 1.0];
pub const DIM: Rgba = [0.86, 0.84, 0.95, 0.70];
pub const VIOLET: Rgba = [0.541, 0.420, 1.0, 1.0];
pub const CYAN: Rgba = [0.310, 0.765, 1.0, 1.0];
pub const MAGENTA: Rgba = [1.0, 0.416, 0.835, 1.0];
pub const DANGER: Rgba = [1.0, 0.36, 0.42, 1.0];

pub fn col(c: Rgba, a: f32) -> Color {
    Color::from_rgba(c[0].clamp(0., 1.), c[1].clamp(0., 1.), c[2].clamp(0., 1.), (c[3] * a).clamp(0., 1.)).unwrap()
}

// ---------------------------------------------------------------- fonts

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub enum Face { Regular, Bold, Mono }

pub struct Fonts {
    faces: [fontdue::Font; 3],
    cache: HashMap<(Face, char, u32), (fontdue::Metrics, Vec<u8>)>,
}

fn load_face(dirs: &[PathBuf], names: &[&str]) -> Option<fontdue::Font> {
    for d in dirs {
        for n in names {
            if let Ok(bytes) = std::fs::read(d.join(n)) {
                if let Ok(f) = fontdue::Font::from_bytes(bytes, fontdue::FontSettings::default()) {
                    return Some(f);
                }
            }
        }
    }
    None
}

impl Fonts {
    /// Fonts come from a `fonts` folder next to the exe first (so the stick can carry its own),
    /// then from the running Windows (X:\Windows\Fonts inside WinRE).
    pub fn load(exe_dir: &std::path::Path) -> Result<Fonts, String> {
        let win = std::env::var("WINDIR").or_else(|_| std::env::var("SystemRoot")).unwrap_or_else(|_| "C:\\Windows".into());
        let dirs = vec![exe_dir.join("fonts"), PathBuf::from(win).join("Fonts")];
        let reg_names = ["ui.ttf", "segoeui.ttf", "arial.ttf", "tahoma.ttf", "verdana.ttf"];
        let regular = load_face(&dirs, &reg_names).ok_or("No usable font found (looked for Segoe UI, Arial, Tahoma).")?;
        let bold = load_face(&dirs, &["ui-bold.ttf", "segoeuib.ttf", "seguisb.ttf", "arialbd.ttf", "tahomabd.ttf"])
            .or_else(|| load_face(&dirs, &reg_names)).unwrap();
        let mono = load_face(&dirs, &["mono.ttf", "consola.ttf", "lucon.ttf", "cour.ttf"])
            .or_else(|| load_face(&dirs, &reg_names)).unwrap();
        Ok(Fonts { faces: [regular, bold, mono], cache: HashMap::new() })
    }

    fn face(&self, f: Face) -> &fontdue::Font {
        &self.faces[match f { Face::Regular => 0, Face::Bold => 1, Face::Mono => 2 }]
    }

    pub fn ascent(&self, size: f32, f: Face) -> f32 {
        self.face(f).horizontal_line_metrics(size).map(|m| m.ascent).unwrap_or(size * 0.8)
    }

    pub fn measure(&self, text: &str, size: f32, f: Face) -> f32 {
        let face = self.face(f);
        text.chars().map(|c| face.metrics(c, size).advance_width).sum()
    }

    /// Greedy word wrap.
    pub fn wrap(&self, text: &str, size: f32, f: Face, max_w: f32) -> Vec<String> {
        let mut out = Vec::new();
        for para in text.split('\n') {
            let mut line = String::new();
            for word in para.split(' ') {
                let cand = if line.is_empty() { word.to_string() } else { format!("{line} {word}") };
                if self.measure(&cand, size, f) > max_w && !line.is_empty() {
                    out.push(std::mem::take(&mut line));
                    line = word.to_string();
                } else {
                    line = cand;
                }
            }
            out.push(line);
        }
        out
    }

    /// Cut a string to fit, ending in "...".
    pub fn fit(&self, text: &str, size: f32, f: Face, max_w: f32) -> String {
        if self.measure(text, size, f) <= max_w { return text.to_string(); }
        let mut s: String = text.to_string();
        while !s.is_empty() && self.measure(&(s.clone() + "..."), size, f) > max_w { s.pop(); }
        s + "..."
    }

    /// Draw one line with its top-left at (x, y). Returns the width drawn.
    pub fn draw(&mut self, pm: &mut Pixmap, x: f32, y: f32, text: &str, size: f32, f: Face, c: Rgba) -> f32 {
        let base = y + self.ascent(size, f);
        let (pw, ph) = (pm.width() as i32, pm.height() as i32);
        let data = pm.data_mut();
        let mut pen = x;
        for ch in text.chars() {
            let key = (f, ch, (size * 4.0).round() as u32);
            if !self.cache.contains_key(&key) {
                let r = self.faces[match f { Face::Regular => 0, Face::Bold => 1, Face::Mono => 2 }].rasterize(ch, size);
                self.cache.insert(key, r);
            }
            let (m, bmp) = &self.cache[&key];
            let gx = (pen + m.xmin as f32).round() as i32;
            let gy = (base - m.height as f32 - m.ymin as f32).round() as i32;
            for row in 0..m.height as i32 {
                let py = gy + row;
                if py < 0 || py >= ph { continue; }
                for colm in 0..m.width as i32 {
                    let px = gx + colm;
                    if px < 0 || px >= pw { continue; }
                    let cov = bmp[(row * m.width as i32 + colm) as usize] as f32 / 255.0;
                    if cov <= 0.0 { continue; }
                    let a = cov * c[3];
                    let i = ((py * pw + px) * 4) as usize;
                    for k in 0..3 {
                        data[i + k] = (c[k] * 255.0 * a + data[i + k] as f32 * (1.0 - a)).round() as u8;
                    }
                    data[i + 3] = (255.0 * a + data[i + 3] as f32 * (1.0 - a)).round() as u8;
                }
            }
            pen += m.advance_width;
        }
        pen - x
    }
}

// ---------------------------------------------------------------- shapes

pub fn rrect(x: f32, y: f32, w: f32, h: f32, r: f32) -> Option<Path> {
    let r = r.min(w / 2.0).min(h / 2.0).max(0.0);
    let k = 0.5523 * r;
    let mut pb = PathBuilder::new();
    pb.move_to(x + r, y);
    pb.line_to(x + w - r, y);
    pb.cubic_to(x + w - r + k, y, x + w, y + r - k, x + w, y + r);
    pb.line_to(x + w, y + h - r);
    pb.cubic_to(x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h);
    pb.line_to(x + r, y + h);
    pb.cubic_to(x + r - k, y + h, x, y + h - r + k, x, y + h - r);
    pb.line_to(x, y + r);
    pb.cubic_to(x, y + r - k, x + r - k, y, x + r, y);
    pb.close();
    pb.finish()
}

pub fn fill(pm: &mut Pixmap, path: &Option<Path>, c: Color) {
    if let Some(p) = path {
        let mut paint = Paint::default();
        paint.set_color(c);
        paint.anti_alias = true;
        pm.fill_path(p, &paint, FillRule::Winding, Transform::identity(), None);
    }
}

pub fn fill_shader(pm: &mut Pixmap, path: &Option<Path>, shader: Option<Shader>) {
    if let (Some(p), Some(sh)) = (path, shader) {
        let paint = Paint { shader: sh, anti_alias: true, ..Default::default() };
        pm.fill_path(p, &paint, FillRule::Winding, Transform::identity(), None);
    }
}

pub fn stroke_shader(pm: &mut Pixmap, path: &Option<Path>, shader: Option<Shader>, width: f32) {
    if let (Some(p), Some(sh)) = (path, shader) {
        let paint = Paint { shader: sh, anti_alias: true, ..Default::default() };
        let st = Stroke { width, line_cap: LineCap::Round, line_join: LineJoin::Round, ..Default::default() };
        pm.stroke_path(p, &paint, &st, Transform::identity(), None);
    }
}

pub fn stroke(pm: &mut Pixmap, path: &Option<Path>, c: Color, width: f32) {
    if let Some(p) = path {
        let mut paint = Paint::default();
        paint.set_color(c);
        paint.anti_alias = true;
        let st = Stroke { width, line_cap: LineCap::Round, line_join: LineJoin::Round, ..Default::default() };
        pm.stroke_path(p, &paint, &st, Transform::identity(), None);
    }
}

pub fn vgrad(y0: f32, y1: f32, stops: Vec<(f32, Color)>) -> Option<Shader<'static>> {
    LinearGradient::new(
        Point::from_xy(0.0, y0), Point::from_xy(0.0, y1),
        stops.into_iter().map(|(p, c)| GradientStop::new(p, c)).collect(),
        SpreadMode::Pad, Transform::identity(),
    )
}

pub fn hgrad(x0: f32, x1: f32, stops: Vec<(f32, Color)>) -> Option<Shader<'static>> {
    LinearGradient::new(
        Point::from_xy(x0, 0.0), Point::from_xy(x1, 0.0),
        stops.into_iter().map(|(p, c)| GradientStop::new(p, c)).collect(),
        SpreadMode::Pad, Transform::identity(),
    )
}

pub fn radial(cx: f32, cy: f32, r: f32, stops: Vec<(f32, Color)>) -> Option<Shader<'static>> {
    RadialGradient::new(
        Point::from_xy(cx, cy), Point::from_xy(cx, cy), r,
        stops.into_iter().map(|(p, c)| GradientStop::new(p, c)).collect(),
        SpreadMode::Pad, Transform::identity(),
    )
}

/// Cheap soft shadow: a stack of faint, growing rounded rects.
pub fn shadow(pm: &mut Pixmap, x: f32, y: f32, w: f32, h: f32, r: f32, s: f32, strength: f32) {
    for i in 0..6 {
        let e = (i as f32 + 1.0) * 2.6 * s;
        fill(pm, &rrect(x - e * 0.6, y - e * 0.3 + 6.0 * s, w + e * 1.2, h + e * 1.2, r + e), Color::from_rgba(0.0, 0.0, 0.02, 0.045 * strength).unwrap());
    }
}

/// Signed distance to a rounded rectangle (negative inside).
fn sdf(px: f32, py: f32, cx: f32, cy: f32, hw: f32, hh: f32, r: f32) -> f32 {
    let qx = (px - cx).abs() - (hw - r);
    let qy = (py - cy).abs() - (hh - r);
    let ox = qx.max(0.0);
    let oy = qy.max(0.0);
    (ox * ox + oy * oy).sqrt() + qx.max(qy).min(0.0) - r
}

pub struct Glass {
    pub lens: f32,      // width of the refracting rim in px (0 = flat frosted glass)
    pub saturate: f32,  // vibrancy boost of what shows through
    pub bright: f32,
    pub tint: Rgba,     // rgb + how much of it
}

/// The liquid-glass material. Reads what is already drawn under the shape, blurs it
/// (downsample x4 + two box passes), bends it near the rim like a lens, boosts its colour,
/// tints it and writes it back inside the rounded shape with an antialiased edge.
pub fn backdrop(pm: &mut Pixmap, x: f32, y: f32, w: f32, h: f32, r: f32, g: &Glass) {
    let pw = pm.width() as i32;
    let ph = pm.height() as i32;
    let m = 28;
    let rx0 = (x as i32 - m).max(0);
    let ry0 = (y as i32 - m).max(0);
    let rx1 = ((x + w) as i32 + m).min(pw);
    let ry1 = ((y + h) as i32 + m).min(ph);
    if rx1 <= rx0 + 2 || ry1 <= ry0 + 2 { return; }
    const F: i32 = 4;
    let sw = (rx1 - rx0 + F - 1) / F;
    let sh = (ry1 - ry0 + F - 1) / F;
    let mut buf = vec![[0f32; 3]; (sw * sh) as usize];
    {
        let d = pm.data();
        for sy in 0..sh {
            for sx in 0..sw {
                let mut acc = [0f32; 3];
                let mut n = 0.0;
                for dy in 0..F {
                    let py = ry0 + sy * F + dy;
                    if py >= ry1 { break; }
                    for dx in 0..F {
                        let px = rx0 + sx * F + dx;
                        if px >= rx1 { break; }
                        let i = ((py * pw + px) * 4) as usize;
                        acc[0] += d[i] as f32;
                        acc[1] += d[i + 1] as f32;
                        acc[2] += d[i + 2] as f32;
                        n += 1.0;
                    }
                }
                buf[(sy * sw + sx) as usize] = [acc[0] / n, acc[1] / n, acc[2] / n];
            }
        }
    }
    let rad = 3i32;
    let mut tmp = buf.clone();
    for _ in 0..2 {
        for sy in 0..sh {
            for sx in 0..sw {
                let mut a = [0f32; 3];
                for k in -rad..=rad {
                    let xx = (sx + k).clamp(0, sw - 1);
                    let p = buf[(sy * sw + xx) as usize];
                    a[0] += p[0]; a[1] += p[1]; a[2] += p[2];
                }
                let n = (2 * rad + 1) as f32;
                tmp[(sy * sw + sx) as usize] = [a[0] / n, a[1] / n, a[2] / n];
            }
        }
        for sy in 0..sh {
            for sx in 0..sw {
                let mut a = [0f32; 3];
                for k in -rad..=rad {
                    let yy = (sy + k).clamp(0, sh - 1);
                    let p = tmp[(yy * sw + sx) as usize];
                    a[0] += p[0]; a[1] += p[1]; a[2] += p[2];
                }
                let n = (2 * rad + 1) as f32;
                buf[(sy * sw + sx) as usize] = [a[0] / n, a[1] / n, a[2] / n];
            }
        }
    }
    let sample = |fx: f32, fy: f32| -> [f32; 3] {
        let fx = ((fx - rx0 as f32) / F as f32 - 0.5).clamp(0.0, (sw - 1) as f32);
        let fy = ((fy - ry0 as f32) / F as f32 - 0.5).clamp(0.0, (sh - 1) as f32);
        let x0 = fx.floor() as i32;
        let y0 = fy.floor() as i32;
        let x1 = (x0 + 1).min(sw - 1);
        let y1 = (y0 + 1).min(sh - 1);
        let tx = fx - x0 as f32;
        let ty = fy - y0 as f32;
        let p00 = buf[(y0 * sw + x0) as usize];
        let p10 = buf[(y0 * sw + x1) as usize];
        let p01 = buf[(y1 * sw + x0) as usize];
        let p11 = buf[(y1 * sw + x1) as usize];
        let mut o = [0f32; 3];
        for k in 0..3 {
            let a = p00[k] + (p10[k] - p00[k]) * tx;
            let b = p01[k] + (p11[k] - p01[k]) * tx;
            o[k] = a + (b - a) * ty;
        }
        o
    };
    let (cx, cy, hw, hh) = (x + w / 2.0, y + h / 2.0, w / 2.0, h / 2.0);
    let r = r.min(hw).min(hh);
    let d = pm.data_mut();
    let yb = (y.floor() as i32).max(0);
    let ye = ((y + h).ceil() as i32).min(ph);
    let xb = (x.floor() as i32).max(0);
    let xe = ((x + w).ceil() as i32).min(pw);
    for py in yb..ye {
        for px in xb..xe {
            let fx = px as f32 + 0.5;
            let fy = py as f32 + 0.5;
            let dist = sdf(fx, fy, cx, cy, hw, hh, r);
            let cov = (0.5 - dist).clamp(0.0, 1.0);
            if cov <= 0.0 { continue; }
            let (mut sx, mut sy) = (fx, fy);
            if g.lens > 0.0 && -dist < g.lens {
                // Rim refraction: pull the sample inward along the surface normal,
                // strongest at the very edge, the way a thick glass lip magnifies.
                let t = 1.0 + dist / g.lens;
                let nx = sdf(fx + 1.0, fy, cx, cy, hw, hh, r) - sdf(fx - 1.0, fy, cx, cy, hw, hh, r);
                let ny = sdf(fx, fy + 1.0, cx, cy, hw, hh, r) - sdf(fx, fy - 1.0, cx, cy, hw, hh, r);
                let nl = (nx * nx + ny * ny).sqrt().max(1e-4);
                let push = t * t * g.lens * 0.9;
                sx -= nx / nl * push;
                sy -= ny / nl * push;
            }
            let mut c = sample(sx, sy);
            let lum = 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];
            for k in 0..3 {
                c[k] = (lum + (c[k] - lum) * g.saturate) * g.bright;
                c[k] = c[k] * (1.0 - g.tint[3]) + g.tint[k] * 255.0 * g.tint[3];
            }
            let i = ((py * pw + px) * 4) as usize;
            for k in 0..3 {
                d[i + k] = (c[k].clamp(0.0, 255.0) * cov + d[i + k] as f32 * (1.0 - cov)).round() as u8;
            }
            d[i + 3] = 255;
        }
    }
}

/// A full glass surface: shadow, backdrop, sheen, rim light, optional pointer glow.
pub fn glass(pm: &mut Pixmap, x: f32, y: f32, w: f32, h: f32, r: f32, s: f32, g: &Glass, hover: f32, pointer: Option<(f32, f32)>) {
    shadow(pm, x, y, w, h, r, s, 1.0 + hover * 0.6);
    backdrop(pm, x, y, w, h, r, g);
    let path = rrect(x, y, w, h, r);
    // sheen: brighter at the top, the light source of the whole UI
    fill_shader(pm, &path, vgrad(y, y + h, vec![
        (0.0, Color::from_rgba(1.0, 1.0, 1.0, 0.16 + hover * 0.06).unwrap()),
        (0.45, Color::from_rgba(1.0, 1.0, 1.0, 0.04).unwrap()),
        (1.0, Color::from_rgba(1.0, 1.0, 1.0, 0.02 + hover * 0.03).unwrap()),
    ]));
    if let Some((mx, my)) = pointer {
        fill_shader(pm, &path, radial(mx, my, (w.max(h)) * 0.55, vec![
            (0.0, Color::from_rgba(1.0, 1.0, 1.0, 0.13 * hover).unwrap()),
            (1.0, Color::from_rgba(1.0, 1.0, 1.0, 0.0).unwrap()),
        ]));
    }
    // rim: bright on top, fading down, so the edge reads as a curved lip
    stroke_shader(pm, &rrect(x + 0.5, y + 0.5, w - 1.0, h - 1.0, r), vgrad(y, y + h, vec![
        (0.0, Color::from_rgba(1.0, 1.0, 1.0, 0.55).unwrap()),
        (0.5, Color::from_rgba(1.0, 1.0, 1.0, 0.10).unwrap()),
        (1.0, Color::from_rgba(1.0, 1.0, 1.0, 0.22).unwrap()),
    ]), (1.0 * s).max(1.0));
}

// ---------------------------------------------------------------- backdrop scene

/// Slowly drifting colour fields on a near-black void. Computed at 1/8 size and
/// stretched, which is both cheap and naturally smooth.
pub fn scene(pm: &mut Pixmap, t: f32) {
    let (w, h) = (pm.width() as i32, pm.height() as i32);
    let sw = w / 8 + 2;
    let sh = h / 8 + 2;
    let aspect = w as f32 / h.max(1) as f32;
    let blobs: [([f32; 2], [f32; 3], f32, f32); 5] = [
        ([0.16 + 0.07 * (t * 0.13).sin(), 0.22 + 0.08 * (t * 0.10).cos()], [138., 107., 255.], 0.48, 0.80),
        ([0.88 + 0.05 * (t * 0.09).cos(), 0.18 + 0.10 * (t * 0.12).sin()], [79., 195., 255.], 0.40, 0.55),
        ([0.64 + 0.10 * (t * 0.07).sin(), 0.92 + 0.05 * (t * 0.11).cos()], [255., 106., 213.], 0.42, 0.50),
        ([0.38 + 0.08 * (t * 0.05).cos(), 0.62 + 0.09 * (t * 0.08).sin()], [70., 45., 190.], 0.55, 0.70),
        ([0.95, 0.75 + 0.06 * (t * 0.06).sin()], [120., 60., 230.], 0.35, 0.45),
    ];
    let mut small = vec![[0f32; 3]; (sw * sh) as usize];
    for sy in 0..sh {
        for sx in 0..sw {
            let u = sx as f32 / (sw - 2).max(1) as f32;
            let v = sy as f32 / (sh - 2).max(1) as f32;
            let mut c = [6.0f32, 5.0, 12.0];
            for (p, bc, rad, k) in blobs.iter() {
                let dx = (u - p[0]) * aspect;
                let dy = v - p[1];
                let f = (-(dx * dx + dy * dy) / (rad * rad) * 2.2).exp() * k;
                for i in 0..3 { c[i] += bc[i] * f; }
            }
            let vig = 1.0 - 0.35 * ((u - 0.5).powi(2) + (v - 0.5).powi(2));
            small[(sy * sw + sx) as usize] = [c[0] * vig, c[1] * vig, c[2] * vig];
        }
    }
    let d = pm.data_mut();
    for py in 0..h {
        let fy = py as f32 / 8.0;
        let y0 = fy.floor() as i32;
        let ty = fy - y0 as f32;
        let y1 = (y0 + 1).min(sh - 1);
        for px in 0..w {
            let fx = px as f32 / 8.0;
            let x0 = fx.floor() as i32;
            let tx = fx - x0 as f32;
            let x1 = (x0 + 1).min(sw - 1);
            let a = small[(y0 * sw + x0) as usize];
            let b = small[(y0 * sw + x1) as usize];
            let c = small[(y1 * sw + x0) as usize];
            let e = small[(y1 * sw + x1) as usize];
            // tiny ordered dither so the dark gradients do not band
            let n = (((px * 7 + py * 13) & 15) as f32 / 15.0 - 0.5) * 1.6;
            let i = ((py * w + px) * 4) as usize;
            for k in 0..3 {
                let top = a[k] + (b[k] - a[k]) * tx;
                let bot = c[k] + (e[k] - c[k]) * tx;
                d[i + k] = (top + (bot - top) * ty + n).clamp(0.0, 255.0) as u8;
            }
            d[i + 3] = 255;
        }
    }
}

// ---------------------------------------------------------------- icons

#[derive(Clone, Copy)]
pub enum Icon { Spark, Restore, Wrench, Drive, Log, Stop, Check, Minus, Plus, Refresh }

pub fn icon(pm: &mut Pixmap, ic: Icon, cx: f32, cy: f32, size: f32, c: Rgba) {
    let s = size / 24.0;
    let lw = (1.9 * s).max(1.2);
    let p = |x: f32, y: f32| (cx + (x - 12.0) * s, cy + (y - 12.0) * s);
    let colr = col(c, 1.0);
    let arc = |pb: &mut PathBuilder, ox: f32, oy: f32, r: f32, a0: f32, a1: f32, first: bool| {
        let steps = 24;
        for i in 0..=steps {
            let a = a0 + (a1 - a0) * i as f32 / steps as f32;
            let (x, y) = p(ox + r * a.cos(), oy + r * a.sin());
            if i == 0 && first { pb.move_to(x, y) } else { pb.line_to(x, y) }
        }
    };
    let mut pb = PathBuilder::new();
    match ic {
        Icon::Spark => {
            let pts = [(12., 2.5), (14.2, 9.8), (21.5, 12.), (14.2, 14.2), (12., 21.5), (9.8, 14.2), (2.5, 12.), (9.8, 9.8)];
            for (i, (x, y)) in pts.iter().enumerate() { let (a, b) = p(*x, *y); if i == 0 { pb.move_to(a, b) } else { pb.line_to(a, b) } }
            pb.close();
            fill(pm, &pb.finish(), colr);
            return;
        }
        Icon::Restore => {
            arc(&mut pb, 12., 12., 8., -2.6, 2.4, true);
            let (a, b) = p(3.2, 4.0); pb.move_to(a, b);
            let (a, b) = p(3.9, 8.9); pb.line_to(a, b);
            let (a, b) = p(8.6, 8.0); pb.line_to(a, b);
            let (a, b) = p(12., 7.5); pb.move_to(a, b);
            let (a, b) = p(12., 12.3); pb.line_to(a, b);
            let (a, b) = p(15., 14.); pb.line_to(a, b);
        }
        Icon::Wrench => {
            arc(&mut pb, 15.5, 8.5, 4.6, 2.0, 2.0 + 5.0, true);
            let (a, b) = p(12.4, 11.6); pb.move_to(a, b);
            let (a, b) = p(4.5, 19.5); pb.line_to(a, b);
        }
        Icon::Drive => {
            stroke(pm, &rrect(cx - 9. * s, cy - 6. * s, 18. * s, 12. * s, 3. * s), colr, lw);
            let (a, b) = p(16.5, 12.); fill(pm, &PathBuilder::from_circle(a, b, 1.4 * s), colr);
            let (a, b) = p(6.5, 12.); pb.move_to(a, b);
            let (a, b) = p(11., 12.); pb.line_to(a, b);
        }
        Icon::Log => {
            stroke(pm, &rrect(cx - 9.5 * s, cy - 8. * s, 19. * s, 16. * s, 3. * s), colr, lw);
            let (a, b) = p(7., 9.); pb.move_to(a, b);
            let (a, b) = p(10., 12.); pb.line_to(a, b);
            let (a, b) = p(7., 15.); pb.line_to(a, b);
            let (a, b) = p(12.5, 15.); pb.move_to(a, b);
            let (a, b) = p(17., 15.); pb.line_to(a, b);
        }
        Icon::Stop => {
            fill(pm, &rrect(cx - 6. * s, cy - 6. * s, 12. * s, 12. * s, 2.5 * s), colr);
            return;
        }
        Icon::Check => {
            let (a, b) = p(5., 12.5); pb.move_to(a, b);
            let (a, b) = p(10., 17.); pb.line_to(a, b);
            let (a, b) = p(19., 7.); pb.line_to(a, b);
        }
        Icon::Minus => {
            let (a, b) = p(6., 12.); pb.move_to(a, b);
            let (a, b) = p(18., 12.); pb.line_to(a, b);
        }
        Icon::Plus => {
            let (a, b) = p(6., 12.); pb.move_to(a, b);
            let (a, b) = p(18., 12.); pb.line_to(a, b);
            let (a, b) = p(12., 6.); pb.move_to(a, b);
            let (a, b) = p(12., 18.); pb.line_to(a, b);
        }
        Icon::Refresh => {
            arc(&mut pb, 12., 12., 7.5, -1.2, 4.3, true);
            let (a, b) = p(15.2, 2.8); pb.move_to(a, b);
            let (a, b) = p(15.4, 5.2); pb.line_to(a, b);
            let (a, b) = p(12.9, 5.9); pb.line_to(a, b);
        }
    }
    stroke(pm, &pb.finish(), colr, lw);
}

/// Spinning arc for "working".
pub fn spinner(pm: &mut Pixmap, cx: f32, cy: f32, r: f32, t: f32, lw: f32) {
    let mut pb = PathBuilder::new();
    let a0 = t * 5.0;
    for i in 0..=28 {
        let a = a0 + 4.2 * i as f32 / 28.0;
        let (x, y) = (cx + r * a.cos(), cy + r * a.sin());
        if i == 0 { pb.move_to(x, y) } else { pb.line_to(x, y) }
    }
    stroke_shader(pm, &pb.finish(), hgrad(cx - r, cx + r, vec![(0.0, col(VIOLET, 1.0)), (1.0, col(CYAN, 1.0))]), lw);
}
