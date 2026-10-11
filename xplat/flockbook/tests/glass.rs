//! Window glass: the per-platform choice, the fallback to opaque, the push to the window, and the look.
//! Headless (iced_test Simulator, tiny-skia). No window: the real backdrop is checked by the owner.
//! Set `FB_WRITE_EVIDENCE=1` to copy the PNGs to `evidence/`.

use std::collections::HashMap;

use fb_ui::theme::{Tokens, SIDEBAR_W, TOPROW_H};
use fb_ui::Mode;
use flockbook::glass::{self, Backdrop, GlassMsg, Os};
use flockbook::snapshot::{render_app, write_png, Image};
use flockbook::state::Screen;
use flockbook::{App, Message};
use iced::Color;

fn args(a: &[&str]) -> Vec<String> {
    a.iter().map(|s| s.to_string()).collect()
}

fn env(v: Option<&str>) -> HashMap<String, String> {
    v.map(|v| HashMap::from([("FLOCKBOOK_GLASS".to_string(), v.to_string())])).unwrap_or_default()
}

// ------------------------------------------------------------ choice per platform

#[test]
fn each_platform_gets_its_backdrop_by_default() {
    assert_eq!(glass::choose(Os::MacOs, &[], &env(None)), Backdrop::Vibrancy);
    assert_eq!(glass::choose(Os::Windows, &[], &env(None)), Backdrop::Mica);
    assert_eq!(glass::choose(Os::Other, &[], &env(None)), Backdrop::Opaque, "Linux has no backdrop API");
}

#[test]
fn off_turns_glass_off_and_linux_stays_opaque_when_asked_for_glass() {
    for os in [Os::MacOs, Os::Windows, Os::Other] {
        assert_eq!(glass::choose(os, &args(&["--glass", "off"]), &env(None)), Backdrop::Opaque);
        assert_eq!(glass::choose(os, &[], &env(Some("off"))), Backdrop::Opaque);
        assert_eq!(glass::choose(os, &[], &env(Some("0"))), Backdrop::Opaque);
    }
    assert_eq!(glass::choose(Os::Other, &args(&["--glass", "on"]), &env(None)), Backdrop::Opaque);
}

#[test]
fn the_flag_beats_the_env_and_unknown_values_count_as_unset() {
    assert_eq!(glass::choose(Os::MacOs, &args(&["--glass", "on"]), &env(Some("off"))), Backdrop::Vibrancy);
    assert_eq!(glass::choose(Os::MacOs, &args(&["--glass", "off"]), &env(Some("on"))), Backdrop::Opaque);
    assert_eq!(glass::choose(Os::Windows, &args(&["--glass", "maybe"]), &env(Some("off"))), Backdrop::Opaque, "bad flag: the env decides");
    assert_eq!(glass::choose(Os::Windows, &args(&["--glass"]), &env(Some(""))), Backdrop::Mica, "nothing valid: the default");
}

#[test]
fn only_a_backdrop_needs_a_transparent_window() {
    assert!(!glass::launch_transparent(Backdrop::Opaque));
    assert!(glass::launch_transparent(Backdrop::Vibrancy));
    assert!(glass::launch_transparent(Backdrop::Mica));
}

// ------------------------------------------------------------ state, fallback, push to the window

#[test]
fn the_demo_and_tests_are_opaque_until_installed() {
    let app = App::demo(Mode::Light, Screen::Conversation);
    assert!(!app.state.glass.on);
    assert_eq!(glass::root_color(&app), Tokens::LIGHT.bg);
}

#[test]
fn install_makes_the_root_clear_and_opaque_install_does_not() {
    let mut app = App::demo(Mode::Light, Screen::Conversation);
    glass::install(&mut app, Backdrop::Opaque);
    assert!(!app.state.glass.on);
    glass::install(&mut app, Backdrop::Vibrancy);
    assert!(app.state.glass.on);
    assert_eq!(glass::root_color(&app), Color::TRANSPARENT);
}

#[test]
fn a_failed_backdrop_falls_back_to_opaque() {
    let mut app = App::demo(Mode::Dark, Screen::Conversation);
    glass::install(&mut app, Backdrop::Mica);
    let _ = app.update(Message::Glass(GlassMsg::Applied(Err("older Windows".into()))));
    assert!(!app.state.glass.on);
    assert_eq!(app.state.glass.error.as_deref(), Some("older Windows"));
    assert_eq!(glass::root_color(&app), Tokens::DARK.bg, "the root paints the content color again");
    assert_eq!(app.bar_tokens().label_2, Tokens::DARK.label_2, "plain labels again");
}

#[test]
fn the_backdrop_is_pushed_once_per_window_and_theme() {
    let mut app = App::demo(Mode::Light, Screen::Conversation);
    glass::install(&mut app, Backdrop::Vibrancy);
    assert!(glass::sync(&mut app).is_none(), "no window yet");
    let id = iced::window::Id::unique();
    let _ = app.update(Message::Glass(GlassMsg::WindowOpened(id)));
    assert_eq!(app.state.glass.window, Some(id));
    // `update` pushed it already: nothing left to push.
    assert!(glass::sync(&mut app).is_none());
    let _ = app.update(Message::Glass(GlassMsg::WindowOpened(iced::window::Id::unique())));
    assert_eq!(app.state.glass.window, Some(id), "the first window keeps the backdrop");
    let _ = app.update(Message::SetMode(Mode::Dark));
    assert!(glass::sync(&mut app).is_none(), "the theme change was pushed by update");
    app.state.mode = Mode::Light;
    assert!(glass::sync(&mut app).is_some(), "a changed theme is pushed again");
    assert!(glass::sync(&mut app).is_none());
}

#[test]
fn nothing_is_pushed_when_glass_is_off() {
    let mut app = App::demo(Mode::Light, Screen::Conversation);
    app.state.glass.window = Some(iced::window::Id::unique());
    assert!(glass::sync(&mut app).is_none());
}

#[test]
fn bars_use_the_stronger_glass_labels() {
    let mut app = App::demo(Mode::Light, Screen::Conversation);
    assert_eq!(app.bar_tokens().label_3, Tokens::LIGHT.label_3);
    app.state.glass.on = true;
    assert_eq!(app.bar_tokens().label_2, Tokens::LIGHT.label_2_glass);
    assert_eq!(app.bar_tokens().label_3, Tokens::LIGHT.label_3_glass);
    assert_eq!(app.ground(), Tokens::LIGHT.content);
}

// ------------------------------------------------------------ the look

const SIZE: (u32, u32) = (1280, 852);

/// Mean RGB of a rectangle in points (the image is 2x).
fn mean(img: &Image, x0: f32, y0: f32, x1: f32, y1: f32) -> [f32; 3] {
    let (mut sum, mut n) = ([0f64; 3], 0f64);
    for y in (y0 * 2.0) as u32..(y1 * 2.0) as u32 {
        for x in (x0 * 2.0) as u32..(x1 * 2.0) as u32 {
            let i = ((y * img.width + x) * 4) as usize;
            for c in 0..3 {
                sum[c] += img.rgba[i + c] as f64;
            }
            n += 1.0;
        }
    }
    [(sum[0] / n) as f32, (sum[1] / n) as f32, (sum[2] / n) as f32]
}

fn dist(a: [f32; 3], b: [f32; 3]) -> f32 {
    (0..3).map(|c| (a[c] - b[c]).abs()).fold(0.0, f32::max)
}

fn shot(app: &App, name: &str) -> Image {
    let img = render_app(app, SIZE);
    write_png(&img, &std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("{name}.png"))).unwrap();
    if std::env::var_os("FB_WRITE_EVIDENCE").is_some() {
        write_png(&img, &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("evidence").join(format!("{name}.png"))).unwrap();
    }
    img
}

/// Opaque and glass renders of one screen. The regions are blank in the demo: the bottom of the sidebar, the
/// right end of the top row, and the bottom right of the main area above the composer.
fn compare(mode: Mode, screen: Screen, name: &str) {
    let mut app = App::demo(mode, screen);
    let opaque = shot(&app, &format!("{name}-opaque"));
    app.state.glass.on = true;
    let glass = shot(&app, name);
    let (w, h) = (SIZE.0 as f32, SIZE.1 as f32);
    let side = (8.0, h - 40.0, SIDEBAR_W - 8.0, h - 8.0);
    let main = (w - 120.0, TOPROW_H + 60.0, w - 20.0, TOPROW_H + 90.0);
    let m = |img: &Image, r: (f32, f32, f32, f32)| mean(img, r.0, r.1, r.2, r.3);
    assert!(dist(m(&opaque, side), m(&glass, side)) > 4.0, "{name}: the wallpaper shows through the sidebar: {:?} vs {:?}", m(&opaque, side), m(&glass, side));
    assert!(dist(m(&opaque, main), m(&glass, main)) < 14.0, "{name}: the content stays almost opaque: {:?} vs {:?}", m(&opaque, main), m(&glass, main));
}

#[test]
fn glass_conversation_light() {
    compare(Mode::Light, Screen::Conversation, "glass-conversation-light");
}

#[test]
fn glass_conversation_dark() {
    compare(Mode::Dark, Screen::Conversation, "glass-conversation-dark");
}

#[test]
fn glass_overview_light() {
    compare(Mode::Light, Screen::Overview, "glass-overview-light");
}

#[test]
fn glass_needs_you_list_is_a_bar_and_the_detail_is_content() {
    let mut app = App::demo(Mode::Light, Screen::NeedsYou);
    assert!(flockbook::needs_you::paints_own_ground(&app), "the demo has requests waiting");
    let opaque = shot(&app, "glass-needs-you-light-opaque");
    app.state.glass.on = true;
    let glass = shot(&app, "glass-needs-you-light");
    let h = SIZE.1 as f32;
    let list = (SIDEBAR_W + 8.0, h - 40.0, SIDEBAR_W + flockbook::needs_you::LIST_W - 8.0, h - 8.0);
    let m = |img: &Image, r: (f32, f32, f32, f32)| mean(img, r.0, r.1, r.2, r.3);
    assert!(dist(m(&opaque, list), m(&glass, list)) > 4.0, "the list column is glass: {:?} vs {:?}", m(&opaque, list), m(&glass, list));
}
