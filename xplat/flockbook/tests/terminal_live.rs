//! The terminal sheet against a real herdr terminal. Ignored by default: it WRITES to a terminal.
//!
//! Run it only against a named test session and a pane made for it:
//! `FLOCKBOOK_LIVE_SESSION=<test session> FLOCKBOOK_LIVE_TERMINAL=<terminal id> cargo test -p flockbook --test terminal_live -- --ignored`
//! It refuses to run without both, and never touches the default session. Headless: no window.

use fb_ui::Mode;
use flockbook::state::Screen;
use flockbook::terminal::{self, TerminalMsg};
use flockbook::{App, Message};
use herdr_core::HerdrSession;
use std::time::{Duration, Instant};

fn target() -> (HerdrSession, String) {
    let session = std::env::var("FLOCKBOOK_LIVE_SESSION").unwrap_or_default();
    let terminal = std::env::var("FLOCKBOOK_LIVE_TERMINAL").unwrap_or_default();
    assert!(!session.is_empty() && session != "default", "set FLOCKBOOK_LIVE_SESSION to a named test session");
    assert!(!terminal.is_empty(), "set FLOCKBOOK_LIVE_TERMINAL to a terminal made for this test");
    let home = std::path::PathBuf::from(std::env::var("HOME").unwrap());
    (HerdrSession::named(&session, &home), terminal)
}

/// The demo app with its selected pane pointed at the live terminal.
fn live_app(session: &HerdrSession, terminal_id: &str, writable: bool) -> App {
    let mut app = App::demo(Mode::Light, Screen::Conversation);
    let pane_id = app.state.selected_pane().unwrap().id.clone();
    for ws in &mut app.state.workspaces {
        for tab in &mut ws.tabs {
            for p in &mut tab.panes {
                if p.id == pane_id {
                    p.terminal_id = terminal_id.to_string();
                }
            }
        }
    }
    app.state.selected_pane = Some(pane_id);
    terminal::install_live(&mut app, session);
    app.state.terminal.writable = writable;
    app
}

fn msg(app: &mut App, m: TerminalMsg) {
    let _ = app.update(Message::Terminal(m));
}

fn screen_text(app: &App) -> String {
    let s = &app.state.terminal.sheet.as_ref().expect("sheet open").snap;
    (0..s.rows).map(|r| s.row_text(r)).collect::<Vec<_>>().join("\n")
}

/// Polls until `pred` holds on the screen text, or panics with the last screen after `secs`.
fn wait_for(app: &mut App, secs: u64, what: &str, pred: impl Fn(&str) -> bool) {
    let end = Instant::now() + Duration::from_secs(secs);
    loop {
        msg(app, TerminalMsg::Poll);
        let text = screen_text(app);
        if pred(&text) {
            return;
        }
        assert!(Instant::now() < end, "timed out waiting for {what}. Screen:\n{text}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn size(app: &App) -> (usize, usize) {
    let s = &app.state.terminal.sheet.as_ref().unwrap().snap;
    (s.cols, s.rows)
}

#[test]
#[ignore = "writes to a real terminal: run with FLOCKBOOK_LIVE_SESSION and FLOCKBOOK_LIVE_TERMINAL"]
fn control_types_resizes_and_releases_on_a_live_terminal() {
    let (session, tid) = target();
    let mut app = live_app(&session, &tid, true);
    msg(&mut app, TerminalMsg::Toggle);
    assert!(app.state.terminal.is_open());
    msg(&mut app, TerminalMsg::Focus(true));
    wait_for(&mut app, 10, "the first frame", |t| !t.trim().is_empty());

    // Keys: a marker the shell can only print if the bytes arrived. `$((6*7))` proves the shell ran it.
    msg(&mut app, TerminalMsg::Input(b"echo fb-live-$((6*7))\r".to_vec()));
    wait_for(&mut app, 10, "the echo output", |t| t.lines().any(|l| l.trim() == "fb-live-42"));

    // Paste: bracketed or not, the text reaches the shell as typed.
    msg(&mut app, TerminalMsg::Paste("echo fb-paste-$((5+5))".into()));
    msg(&mut app, TerminalMsg::Input(b"\r".to_vec()));
    wait_for(&mut app, 10, "the pasted command output", |t| t.lines().any(|l| l.trim() == "fb-paste-10"));

    // Resize: debounced, then the program sees the new size (stty size prints rows cols).
    msg(&mut app, TerminalMsg::Resized(70, 18));
    std::thread::sleep(Duration::from_millis(250));
    msg(&mut app, TerminalMsg::Poll);
    msg(&mut app, TerminalMsg::Input(b"stty size\r".to_vec()));
    wait_for(&mut app, 10, "stty size 18 70", |t| t.lines().any(|l| l.trim() == "18 70"));
    let deadline = Instant::now() + Duration::from_secs(5);
    while size(&app) != (70, 18) && Instant::now() < deadline {
        msg(&mut app, TerminalMsg::Poll);
        std::thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(size(&app), (70, 18), "the grid follows herdr's size");

    // Close releases control.
    msg(&mut app, TerminalMsg::Close);
    assert!(!app.state.terminal.is_open());
    std::thread::sleep(Duration::from_millis(300));
}

#[test]
#[ignore = "reads a real terminal: run with FLOCKBOOK_LIVE_SESSION and FLOCKBOOK_LIVE_TERMINAL"]
fn read_only_observes_a_live_terminal_and_sends_nothing() {
    let (session, tid) = target();
    let mut app = live_app(&session, &tid, false);
    msg(&mut app, TerminalMsg::Toggle);
    msg(&mut app, TerminalMsg::Focus(true));
    wait_for(&mut app, 10, "the first frame", |t| !t.trim().is_empty());
    let before = screen_text(&app);
    // Observe has no input path: these must not reach the shell.
    msg(&mut app, TerminalMsg::Input(b"echo fb-ro-$((2*21))\r".to_vec()));
    msg(&mut app, TerminalMsg::Paste("echo fb-ro-paste".into()));
    let end = Instant::now() + Duration::from_secs(2);
    while Instant::now() < end {
        msg(&mut app, TerminalMsg::Poll);
        std::thread::sleep(Duration::from_millis(50));
    }
    let after = screen_text(&app);
    assert!(!after.contains("fb-ro-"), "read-only sent input. Before:\n{before}\nAfter:\n{after}");
    msg(&mut app, TerminalMsg::Close);
}
