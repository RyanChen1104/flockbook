//! Headless rendering: one frame, offscreen, through `iced_test::Simulator` on the tiny-skia (CPU) renderer.
//! No window, no Dock icon, no focus change. Output is RGBA at 2x scale.

use crate::state::Screen;
use crate::{App, Message};
use fb_ui::Mode;
use iced::{Settings, Size};
use iced_test::Simulator;
use std::path::Path;

#[derive(Debug, Clone, Copy)]
pub struct Options {
    pub screen: Screen,
    pub mode: Mode,
    /// Logical size in points. The PNG is `size * 2`.
    pub size: (u32, u32),
}

impl Default for Options {
    fn default() -> Self {
        Options { screen: Screen::Conversation, mode: Mode::Light, size: (1280, 852) }
    }
}

pub struct Image {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

pub fn parse_size(s: &str) -> Option<(u32, u32)> {
    let (w, h) = s.split_once('x')?;
    Some((w.parse().ok()?, h.parse().ok()?))
}

/// Renders an app that the caller built (any source, any state).
pub fn render_app(app: &App, size: (u32, u32)) -> Image {
    std::env::set_var("ICED_TEST_BACKEND", "tiny-skia");
    let settings = Settings { fonts: fb_ui::fonts::bytes(), default_font: fb_ui::fonts::default_font(), ..Settings::default() };
    let mut sim: Simulator<'_, Message> = Simulator::with_size(settings, Size::new(size.0 as f32, size.1 as f32), app.view());
    let snap = sim.snapshot(&app.theme()).expect("snapshot");
    // `Snapshot` keeps its pixels private; it can only write a PNG, so go through a temp file.
    static COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let dir = std::env::temp_dir().join(format!("fb-snap-{}-{}", std::process::id(), COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst)));
    snap.matches_image(dir.join("frame")).expect("write snapshot");
    let png_path = std::fs::read_dir(&dir).expect("snapshot dir").map(|e| e.unwrap().path()).find(|p| p.extension().is_some_and(|e| e == "png")).expect("png written");
    let img = read_png(&png_path);
    let _ = std::fs::remove_dir_all(&dir);
    img
}

fn read_png(path: &Path) -> Image {
    let decoder = png::Decoder::new(std::io::BufReader::new(std::fs::File::open(path).expect("open png")));
    let mut reader = decoder.read_info().expect("png header");
    let mut buf = vec![0; reader.output_buffer_size().expect("png size")];
    let info = reader.next_frame(&mut buf).expect("png frame");
    buf.truncate(info.buffer_size());
    Image { width: info.width, height: info.height, rgba: buf }
}

/// Renders the demo app for `opts`.
pub fn render(opts: Options) -> Image {
    let app = App::demo(opts.mode, opts.screen);
    render_app(&app, opts.size)
}

pub fn write_png(img: &Image, path: &Path) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        if !dir.as_os_str().is_empty() {
            std::fs::create_dir_all(dir)?;
        }
    }
    let file = std::io::BufWriter::new(std::fs::File::create(path)?);
    let mut enc = png::Encoder::new(file, img.width, img.height);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    let mut w = enc.write_header().map_err(std::io::Error::other)?;
    w.write_image_data(&img.rgba).map_err(std::io::Error::other)?;
    Ok(())
}

/// Count of distinct colors, a cheap "is this more than a blank frame" measure.
pub fn distinct_colors(img: &Image) -> usize {
    let mut set = std::collections::HashSet::new();
    for p in img.rgba.chunks_exact(4) {
        set.insert([p[0], p[1], p[2], p[3]]);
        if set.len() > 4096 {
            break;
        }
    }
    set.len()
}
