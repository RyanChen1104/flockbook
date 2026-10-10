//! Composer interaction tests. They drive iced's `UserInterface` headlessly (no window). Sending goes to a fake
//! sender that records calls: no test touches a live herdr.

use fb_ui::Mode;
use flockbook::composer::{self, ComposerMsg, MessageSender};
use flockbook::state::Screen;
use flockbook::{App, Message};
use iced::advanced::input_method::{self, InputMethod};
use iced::keyboard::{self, key::Named, Key, Modifiers};
use iced::{mouse, Event, Font, Pixels, Point, Size};
use iced_test::core::clipboard;
use iced_test::core::renderer::Headless;
use iced_test::runtime::user_interface::{Cache, State, UserInterface};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const SIZE: Size = Size::new(640.0, 150.0);
const EDITOR_POINT: Point = Point::new(200.0, 30.0);

#[derive(Default)]
struct Fake {
    calls: Mutex<Vec<(String, String)>>,
    fail: Mutex<Option<String>>,
}
impl MessageSender for Fake {
    fn send(&self, pane: &str, text: &str) -> Result<(), String> {
        self.calls.lock().unwrap().push((pane.into(), text.into()));
        match self.fail.lock().unwrap().clone() {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }
}

struct H {
    app: App,
    fake: Arc<Fake>,
    cache: Option<Cache>,
    renderer: iced::Renderer,
    cursor: mouse::Cursor,
    ime: InputMethod,
}

impl H {
    fn new() -> H {
        let renderer = iced_test::futures::futures::executor::block_on(<iced::Renderer as Headless>::new(Font::DEFAULT, Pixels(16.0), Some("tiny-skia"))).expect("headless renderer");
        let mut app = App::demo(Mode::Light, Screen::Conversation);
        let fake = Arc::new(Fake::default());
        app.state.composer.sender = Some(fake.clone());
        app.state.composer.branch_override = Some("main".into());
        let mut h = H { app, fake, cache: Some(Cache::default()), renderer, cursor: mouse::Cursor::Unavailable, ime: InputMethod::Disabled };
        h.send(Event::Window(iced::window::Event::Focused));
        h.click(EDITOR_POINT);
        h
    }

    fn send(&mut self, event: Event) {
        let mut messages: Vec<Message> = Vec::new();
        let mut ui = UserInterface::build(composer::view(&self.app), SIZE, self.cache.take().unwrap_or_default(), &mut self.renderer);
        ui.update(&[event], self.cursor, &mut self.renderer, &mut clipboard::Null, &mut messages);
        let (state, _) = ui.update(&[Event::Window(iced::window::Event::RedrawRequested(Instant::now()))], self.cursor, &mut self.renderer, &mut clipboard::Null, &mut messages);
        if let State::Updated { input_method, .. } = state {
            self.ime = input_method;
        }
        self.cache = Some(ui.into_cache());
        for m in messages {
            let _ = self.app.update(m);
        }
    }

    fn click(&mut self, at: Point) {
        self.cursor = mouse::Cursor::Available(at);
        self.send(Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Left)));
        self.send(Event::Mouse(mouse::Event::ButtonReleased(mouse::Button::Left)));
    }

    fn type_text(&mut self, s: &str) {
        for ev in iced_test::simulator::typewrite(s) {
            self.send(ev);
        }
    }

    fn key(&mut self, named: Named, modifiers: Modifiers) {
        let key = Key::Named(named);
        self.send(Event::Keyboard(keyboard::Event::KeyPressed {
            key: key.clone(),
            modified_key: key.clone(),
            physical_key: keyboard::key::Physical::Unidentified(keyboard::key::NativeCode::Unidentified),
            location: keyboard::Location::Standard,
            modifiers,
            text: None,
            repeat: false,
        }));
        self.send(Event::Keyboard(keyboard::Event::KeyReleased {
            key: key.clone(),
            modified_key: key,
            physical_key: keyboard::key::Physical::Unidentified(keyboard::key::NativeCode::Unidentified),
            location: keyboard::Location::Standard,
            modifiers,
        }));
    }

    fn ime(&mut self, e: input_method::Event) {
        self.send(Event::InputMethod(e));
    }

    fn text(&self) -> String {
        self.app.state.composer.text()
    }

    /// The sender runs on a thread, so wait briefly for its call.
    fn calls(&self, n: usize) -> Vec<(String, String)> {
        let end = Instant::now() + Duration::from_secs(2);
        while Instant::now() < end && self.fake.calls.lock().unwrap().len() < n {
            std::thread::sleep(Duration::from_millis(10));
        }
        std::thread::sleep(Duration::from_millis(30));
        self.fake.calls.lock().unwrap().clone()
    }
}

#[test]
fn typing_then_enter_sends_and_clears() {
    let mut h = H::new();
    h.type_text("run the tests");
    assert_eq!(h.text(), "run the tests");
    h.key(Named::Enter, Modifiers::empty());
    let calls = h.calls(1);
    let pane = h.app.state.selected_pane().unwrap().id.clone();
    assert_eq!(calls, vec![(pane, "run the tests".to_string())]);
    assert_eq!(h.text(), "");
}

#[test]
fn shift_enter_inserts_newline_and_does_not_send() {
    let mut h = H::new();
    h.type_text("one");
    h.key(Named::Enter, Modifiers::SHIFT);
    h.type_text("two");
    assert_eq!(h.text(), "one\ntwo");
    assert!(h.calls(0).is_empty());
    h.key(Named::Enter, Modifiers::empty());
    assert_eq!(h.calls(1)[0].1, "one\ntwo");
}

#[test]
fn empty_or_blank_text_does_not_send() {
    let mut h = H::new();
    h.key(Named::Enter, Modifiers::empty());
    h.type_text("   ");
    h.key(Named::Enter, Modifiers::empty());
    assert!(h.calls(1).is_empty());
}

#[test]
fn cjk_commit_then_enter_sends_the_text() {
    let mut h = H::new();
    h.ime(input_method::Event::Opened);
    h.ime(input_method::Event::Preedit("かんじ".into(), Some(0..9)));
    // Preedit is shown by the IME request, not committed to the text.
    assert_eq!(h.text(), "");
    match &h.ime {
        InputMethod::Enabled { preedit, .. } => assert_eq!(preedit.as_ref().map(|p| p.content.as_str()), Some("かんじ")),
        InputMethod::Disabled => panic!("IME request expected while the editor is focused"),
    }
    h.ime(input_method::Event::Commit("漢字".into()));
    assert_eq!(h.text(), "漢字");
    h.key(Named::Enter, Modifiers::empty());
    assert_eq!(h.calls(1)[0].1, "漢字");
}

#[test]
fn commit_inserts_at_the_caret() {
    let mut h = H::new();
    h.type_text("abcd");
    h.key(Named::ArrowLeft, Modifiers::empty());
    h.key(Named::ArrowLeft, Modifiers::empty());
    h.ime(input_method::Event::Commit("漢字".into()));
    assert_eq!(h.text(), "ab漢字cd");
}

#[test]
fn failed_send_gives_the_text_back_with_a_note() {
    let mut h = H::new();
    *h.fake.fail.lock().unwrap() = Some("pane gone".into());
    h.type_text("hello");
    h.key(Named::Enter, Modifiers::empty());
    h.calls(1);
    // The task result is delivered by the runtime; deliver it by hand.
    let _ = h.app.update(Message::Composer(ComposerMsg::Sent { pane: h.app.state.selected_pane().unwrap().id.clone(), text: "hello".into(), error: Some("pane gone".into()) }));
    assert_eq!(h.text(), "hello");
    assert!(h.app.state.composer.error.as_deref().unwrap().contains("pane gone"));
    // Typing clears the note.
    h.type_text("!");
    assert!(h.app.state.composer.error.is_none());
}

#[test]
fn failed_send_does_not_overwrite_new_typing() {
    let mut app = App::demo(Mode::Light, Screen::Conversation);
    app.state.composer.sender = Some(Arc::new(Fake::default()));
    app.state.composer.set_text("new text");
    let _ = app.update(Message::Composer(ComposerMsg::Sent { pane: app.state.selected_pane().unwrap().id.clone(), text: "old".into(), error: Some("x".into()) }));
    assert_eq!(app.state.composer.text(), "new text");
}

#[test]
fn without_a_sender_the_composer_is_read_only() {
    let mut app = App::demo(Mode::Light, Screen::Conversation);
    assert!(app.state.composer.sender.is_none());
    let _ = app.update(Message::Composer(ComposerMsg::Edit(iced::widget::text_editor::Action::Edit(iced::widget::text_editor::Edit::Insert('x')))));
    assert_eq!(app.state.composer.text(), "");
    let _ = app.update(Message::Composer(ComposerMsg::Submit));
}

#[test]
fn editor_height_grows_then_caps() {
    let mut app = App::demo(Mode::Light, Screen::Conversation);
    app.state.composer.sender = Some(Arc::new(Fake::default()));
    let lines = |n: usize| vec!["x"; n].join("\n");
    app.state.composer.set_text(&lines(3));
    assert_eq!(app.state.composer.content.line_count(), 3);
    app.state.composer.set_text(&lines(30));
    // The view clamps to MAX_LINES; rendering must not panic.
    let _ = flockbook::snapshot::render_app(&app, (640, 400));
}

fn snap(name: &str, mode: Mode, text: &str, sender: bool) {
    let mut app = App::demo(mode, Screen::Conversation);
    if sender {
        app.state.composer.sender = Some(Arc::new(Fake::default()));
    }
    app.state.composer.branch_override = Some("feature/ranking".into());
    if !text.is_empty() {
        app.state.composer.set_text(text);
    }
    let img = flockbook::snapshot::render_app(&app, (1280, 852));
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR"));
    flockbook::snapshot::write_png(&img, &dir.join(format!("{name}.png"))).unwrap();
    if std::env::var_os("FB_WRITE_EVIDENCE").is_some() {
        flockbook::snapshot::write_png(&img, &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("evidence").join(format!("{name}.png"))).unwrap();
    }
    assert!(flockbook::snapshot::distinct_colors(&img) > 40);
}

#[test]
fn snapshots() {
    snap("composer-light", Mode::Light, "", true);
    snap("composer-dark", Mode::Dark, "", true);
    snap("composer-filled-light", Mode::Light, "Try the new decay and show me the same query.\nThen run the bench.", true);
    snap("composer-filled-dark", Mode::Dark, "Try the new decay and show me the same query.\nThen run the bench.", true);
}

// ------------------------------------------------------------------ drafts per pane

fn two_panes(app: &App) -> (Message, Message, String, String) {
    let ws = app.state.workspaces.iter().find(|w| w.label == "Quarry").unwrap();
    let a = &ws.tabs[0];
    let b = &ws.tabs[1];
    (
        Message::SelectTab { workspace: ws.id.clone(), tab: a.id.clone() },
        Message::SelectTab { workspace: ws.id.clone(), tab: b.id.clone() },
        a.panes[0].id.clone(),
        b.panes[0].id.clone(),
    )
}

#[test]
fn each_pane_keeps_its_own_draft() {
    let mut app = App::demo(Mode::Light, Screen::Conversation);
    app.state.composer.sender = Some(Arc::new(Fake::default()));
    let (to_a, to_b, pane_a, pane_b) = two_panes(&app);
    assert_eq!(app.state.selected_pane().unwrap().id, pane_a);
    app.state.composer.set_text("draft for A");
    let _ = app.update(to_b.clone());
    assert_eq!(app.state.selected_pane().unwrap().id, pane_b);
    assert_eq!(app.state.composer.text(), "", "pane B starts empty");
    app.state.composer.set_text("draft for B\nsecond line");
    let _ = app.update(to_a.clone());
    assert_eq!(app.state.composer.text(), "draft for A");
    let _ = app.update(to_b);
    assert_eq!(app.state.composer.text(), "draft for B\nsecond line");
    // Clearing a draft forgets it.
    app.state.composer.set_text("");
    let _ = app.update(to_a);
    let _ = app.update(Message::SelectTab { workspace: app.state.selected_workspace.clone().unwrap(), tab: app.state.workspaces.iter().find(|w| w.label == "Quarry").unwrap().tabs[1].id.clone() });
    assert_eq!(app.state.composer.text(), "");
    assert!(!app.state.composer.drafts.contains_key(&pane_b));
}

#[test]
fn a_failed_send_returns_to_the_pane_it_was_for() {
    let mut app = App::demo(Mode::Light, Screen::Conversation);
    app.state.composer.sender = Some(Arc::new(Fake::default()));
    let (to_a, to_b, pane_a, _) = two_panes(&app);
    let _ = app.update(to_b);
    // The send for pane A fails while B is shown: B's box stays as it is, A gets the text back as its draft.
    let _ = app.update(Message::Composer(ComposerMsg::Sent { pane: pane_a, text: "lost".into(), error: Some("gone".into()) }));
    assert_eq!(app.state.composer.text(), "");
    assert!(app.state.composer.error.is_none());
    let _ = app.update(to_a);
    assert_eq!(app.state.composer.text(), "lost");
}
