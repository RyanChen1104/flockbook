//! Flockbook binary.
//!
//! Normal run: opens a real window (for the owner only).
//! Headless: `flockbook --snapshot out.png --screen conversation|overview [--theme light|dark] [--tab LABEL] [--query TEXT] [--size 1280x852] [--demo]`
//! renders one demo frame offscreen and exits. It never opens a window.
//! `--read-only` (or env `FLOCKBOOK_READ_ONLY=1`): nothing is ever sent to a pane; the composer and the cards only read.

use fb_ui::Mode;
use flockbook::state::Screen;
use flockbook::{snapshot, App, Message};
use iced::{time, Size, Subscription, Task, Theme};
use std::time::Duration;

fn arg_value(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned()
}

fn main() -> iced::Result {
    let args: Vec<String> = std::env::args().skip(1).collect();

    if let Some(out) = arg_value(&args, "--snapshot") {
        let screen = arg_value(&args, "--screen").and_then(|s| Screen::parse(&s)).unwrap_or(Screen::Conversation);
        let mode = arg_value(&args, "--theme").and_then(|s| Mode::parse(&s)).unwrap_or(Mode::Light);
        let size = arg_value(&args, "--size").and_then(|s| snapshot::parse_size(&s)).unwrap_or((1280, 852));
        // Snapshots always use the demo source: they never touch a live herdr.
        // `--tab LABEL` shows that demo tab (e.g. `deploy` or `getting started`: the two blocked ones show a card).
        // `--query TEXT` types TEXT into Search (all demo conversations are loaded first).
        let img = if let Some(q) = arg_value(&args, "--query") {
            let mut app = App::demo(mode, Screen::Search);
            flockbook::search::preload_all(&mut app);
            let _ = app.update(Message::Search(flockbook::search::SearchMsg::Open));
            let _ = app.update(Message::Search(flockbook::search::SearchMsg::Input(q)));
            snapshot::render_app(&app, size)
        } else {
            match arg_value(&args, "--tab") {
                Some(label) => snapshot::render_app(&flockbook::cards::demo_app_on_tab(mode, screen, &label), size),
                None => snapshot::render(snapshot::Options { screen, mode, size }),
            }
        };
        match snapshot::write_png(&img, std::path::Path::new(&out)) {
            Ok(()) => {
                println!("wrote {out} ({}x{})", img.width, img.height);
                return Ok(());
            }
            Err(e) => {
                eprintln!("cannot write {out}: {e}");
                std::process::exit(1);
            }
        }
    }

    let demo = args.iter().any(|a| a == "--demo");
    iced::application(move || boot(demo, &args), App::update, App::view)
        .title(App::title)
        .theme(|app: &App| -> Theme { app.theme() })
        .subscription(|app: &App| -> Subscription<Message> { Subscription::batch([time::every(Duration::from_millis(800)).map(|_| Message::Tick), flockbook::toprow::subscription(app), flockbook::needs_you::subscription(app), flockbook::conversation::subscription(app), flockbook::search::subscription(app)]) })
        .font(fb_ui::fonts::BUNDLED[0])
        .font(fb_ui::fonts::BUNDLED[1])
        .font(fb_ui::fonts::BUNDLED[2])
        .font(fb_ui::fonts::BUNDLED[3])
        .font(fb_ui::fonts::BUNDLED[4])
        .default_font(fb_ui::fonts::default_font())
        .window(iced::window::Settings {
            size: Size::new(1280.0, 852.0),
            min_size: Some(Size::new(900.0, 560.0)),
            transparent: false,
            ..Default::default()
        })
        .run()
}

fn boot(demo: bool, args: &[String]) -> (App, Task<Message>) {
    let mut app = if demo {
        App::demo(Mode::Light, Screen::Conversation)
    } else {
        live_app(args)
    };
    // A real window opens links in the system browser. Snapshots and tests keep the recording opener.
    app.opener = Box::new(flockbook::links::SystemOpener);
    // Read-only also strips the demo's recording actions, so the demo shows the read-only look.
    if !writes_enabled(args) {
        flockbook::access::make_read_only(&mut app);
    }
    (app, Task::none())
}

/// Swift `writesEnabled`: `--read-only` or `FLOCKBOOK_READ_ONLY=1` turn it off. (No settings store yet: the setting is "not set".)
fn writes_enabled(args: &[String]) -> bool {
    let env: std::collections::HashMap<String, String> = std::env::vars().collect();
    flockbook::access::writes_enabled(args, &env, None)
}

#[cfg(unix)]
fn live_app(args: &[String]) -> App {
    // Read-only: the live source only subscribes to snapshots and events.
    let source = flockbook::source::LiveSource::from_args(args);
    let mut app = App::new(Box::new(source), Mode::Light, Screen::Conversation);
    // Read-only: no sender and no pane actions are installed at all.
    if !writes_enabled(args) {
        return app;
    }
    // The composer is the only mutating path (sends text to a pane). It is wired to the live source only.
    let env: std::collections::HashMap<String, String> = std::env::vars().collect();
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from).unwrap_or_default();
    let session = herdr_core::HerdrSession::resolve(args, &env, &home);
    flockbook::composer::install_live(&mut app, &session);
    // Allow, Deny and question answers send keys to a pane: live path only.
    flockbook::cards::install_live(&mut app, &session);
    app
}

#[cfg(not(unix))]
fn live_app(_args: &[String]) -> App {
    eprintln!("live herdr source is not available on this platform yet; showing demo data");
    App::demo(Mode::Light, Screen::Conversation)
}
