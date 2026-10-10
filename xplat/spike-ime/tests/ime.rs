//! Headless IME flow tests. A small harness drives iced's `UserInterface`
//! directly (the `Simulator` throws away the `InputMethod` request, which is
//! exactly what we want to inspect).

use iced::advanced::input_method::{self, InputMethod};
use iced::keyboard::{self, key::Named};
use iced::{mouse, Event, Font, Pixels, Point, Size, Theme};
use iced_test::core::clipboard;
use iced_test::core::renderer::Headless;
use iced_test::runtime::user_interface::{Cache, State, UserInterface};
use spike_ime::{Composer, Message, EDITOR_HEIGHT, OUTER_PADDING};

const SIZE: Size = Size::new(480.0, 260.0);
/// A point inside the single-line input.
const INPUT_POINT: Point = Point::new(60.0, 25.0);
/// A point inside the multi-line editor.
const EDITOR_POINT: Point = Point::new(60.0, 90.0);

struct Harness {
    app: Composer,
    cache: Option<Cache>,
    renderer: iced::Renderer,
    cursor: mouse::Cursor,
    /// Input-method request from the most recent update.
    ime: InputMethod,
}

impl Harness {
    fn new() -> Self {
        let renderer = iced_test::futures::futures::executor::block_on(
            <iced::Renderer as Headless>::new(
                Font::with_name("Fira Sans"),
                Pixels(16.0),
                Some("tiny-skia"),
            ),
        )
        .expect("headless renderer");
        let mut h = Self {
            app: Composer::default(),
            cache: Some(Cache::default()),
            renderer,
            cursor: mouse::Cursor::Unavailable,
            ime: InputMethod::Disabled,
        };
        // Tell the widgets the window has focus (needed for IME requests).
        h.send(Event::Window(iced::window::Event::Focused));
        h
    }

    /// Feeds one event through a fresh UI built from the current app state.
    fn send(&mut self, event: Event) {
        let mut messages = Vec::new();
        let mut ui = UserInterface::build(
            self.app.view(),
            SIZE,
            self.cache.take().unwrap_or_default(),
            &mut self.renderer,
        );
        let (state, _) = ui.update(
            &[event],
            self.cursor,
            &mut self.renderer,
            &mut clipboard::Null,
            &mut messages,
        );
        let _ = state;
        // The real shell redraws after every event, and widgets only publish
        // their `InputMethod` request while handling `RedrawRequested`.
        let (state, _) = ui.update(
            &[Event::Window(iced::window::Event::RedrawRequested(
                std::time::Instant::now(),
            ))],
            self.cursor,
            &mut self.renderer,
            &mut clipboard::Null,
            &mut messages,
        );
        if let State::Updated { input_method, .. } = state {
            self.ime = input_method;
        }
        self.cache = Some(ui.into_cache());
        for m in messages {
            self.app.update(m);
        }
    }

    fn click(&mut self, at: Point) {
        self.cursor = mouse::Cursor::Available(at);
        self.send(Event::Mouse(mouse::Event::ButtonPressed(
            mouse::Button::Left,
        )));
        self.send(Event::Mouse(mouse::Event::ButtonReleased(
            mouse::Button::Left,
        )));
        // A redraw lets widgets refresh their IME request after focus change.
        self.send(Event::Window(iced::window::Event::RedrawRequested(
            std::time::Instant::now(),
        )));
    }

    fn ime(&mut self, e: input_method::Event) {
        self.send(Event::InputMethod(e));
    }

    fn type_ascii(&mut self, s: &str) {
        for ev in iced_test::simulator::typewrite(s) {
            self.send(ev);
        }
    }

    fn backspace(&mut self) {
        for ev in iced_test::simulator::tap_key(Named::Backspace, None) {
            self.send(ev);
        }
    }

    fn arrow_left(&mut self) {
        for ev in iced_test::simulator::tap_key(Named::ArrowLeft, None) {
            self.send(ev);
        }
    }

    fn notes(&self) -> String {
        self.app.notes.text().trim_end_matches('\n').to_string()
    }

    /// Returns (preedit text, preedit range, caret rectangle) if IME is enabled.
    fn requested(&self) -> Option<(String, Option<std::ops::Range<usize>>, iced::Rectangle)> {
        match &self.ime {
            InputMethod::Enabled { cursor, preedit, .. } => Some((
                preedit.as_ref().map(|p| p.content.clone()).unwrap_or_default(),
                preedit.as_ref().and_then(|p| p.selection.clone()),
                *cursor,
            )),
            InputMethod::Disabled => None,
        }
    }
}

/// One composition scenario: raw keys -> intermediate preedit -> final commit.
struct Scenario {
    name: &'static str,
    first: &'static str,
    second: &'static str,
    commit: &'static str,
}

const SCENARIOS: &[Scenario] = &[
    // zh-TW Zhuyin: ㄏㄢˋ -> 漢字
    Scenario { name: "zh-TW", first: "ㄏㄢˋ", second: "漢字", commit: "漢字" },
    // ja: kana -> kanji conversion
    Scenario { name: "ja", first: "かんじ", second: "漢字", commit: "漢字" },
    // ko: Hangul jamo assembling into syllables
    Scenario { name: "ko", first: "ㅎ", second: "한", commit: "한글" },
];

fn full(s: &str) -> Option<std::ops::Range<usize>> {
    Some(s.len()..s.len())
}

fn run_flow(h: &mut Harness, at: Point, value: impl Fn(&Harness) -> String) {
    for sc in SCENARIOS {
        // Fresh state for every scenario.
        *h = Harness::new();
        h.click(at);
        h.type_ascii("hi ");
        let before = value(h);
        assert_eq!(before, "hi ", "{}: ascii typing", sc.name);

        h.ime(input_method::Event::Opened);
        h.ime(input_method::Event::Preedit(sc.first.into(), full(sc.first)));
        assert_eq!(value(h), before, "{}: preedit must not enter the value", sc.name);
        let (pre, range, _) = h.requested().expect("IME enabled while focused");
        assert_eq!(pre, sc.first, "{}: widget reports preedit text", sc.name);
        assert_eq!(range, full(sc.first));

        h.ime(input_method::Event::Preedit(sc.second.into(), full(sc.second)));
        assert_eq!(value(h), before, "{}: still uncommitted", sc.name);
        assert_eq!(h.requested().unwrap().0, sc.second);

        // Winit sends an empty preedit right before the commit.
        h.ime(input_method::Event::Preedit(String::new(), None));
        h.ime(input_method::Event::Commit(sc.commit.into()));
        assert_eq!(value(h), format!("hi {}", sc.commit), "{}: commit inserts at caret", sc.name);
        assert_eq!(h.requested().unwrap().0, "", "{}: preedit cleared after commit", sc.name);

        // More ASCII after the commit, then backspace removes one char.
        h.type_ascii("ab");
        assert_eq!(value(h), format!("hi {}ab", sc.commit));
        h.backspace();
        h.backspace();
        h.backspace();
        let mut expect = format!("hi {}", sc.commit);
        expect.pop();
        assert_eq!(value(h), expect, "{}: backspace removes a whole CJK char", sc.name);

        h.ime(input_method::Event::Closed);
    }
}

#[test]
fn text_input_preedit_and_commit() {
    let mut h = Harness::new();
    run_flow(&mut h, INPUT_POINT, |h| h.app.reply.clone());
}

#[test]
fn text_editor_preedit_and_commit() {
    let mut h = Harness::new();
    run_flow(&mut h, EDITOR_POINT, |h| h.notes());
}

#[test]
fn unfocused_widget_ignores_ime() {
    let mut h = Harness::new();
    // Nothing focused: no IME request, and a stray commit changes nothing.
    h.ime(input_method::Event::Opened);
    h.ime(input_method::Event::Preedit("かな".into(), None));
    h.ime(input_method::Event::Commit("漢".into()));
    assert!(h.app.reply.is_empty());
    assert!(h.notes().is_empty());
    assert!(h.requested().is_none());
}

#[test]
fn commit_lands_at_caret_in_the_middle() {
    let mut h = Harness::new();
    h.click(INPUT_POINT);
    h.type_ascii("abcd");
    h.arrow_left();
    h.arrow_left();
    h.ime(input_method::Event::Commit("漢字".into()));
    assert_eq!(h.app.reply, "ab漢字cd");

    let mut h = Harness::new();
    h.click(EDITOR_POINT);
    h.type_ascii("abcd");
    h.arrow_left();
    h.arrow_left();
    h.ime(input_method::Event::Commit("漢字".into()));
    assert_eq!(h.notes(), "ab漢字cd");
}

#[test]
fn candidate_window_position_follows_the_caret() {
    let mut h = Harness::new();

    // text_input: caret rect sits inside the input, to the right of the left
    // edge, and moves right as text grows.
    h.click(INPUT_POINT);
    let (_, _, r0) = h.requested().expect("enabled");
    h.type_ascii("hello");
    h.ime(input_method::Event::Preedit("かんじ".into(), full("かんじ")));
    let (pre, _, r1) = h.requested().unwrap();
    assert_eq!(pre, "かんじ");
    assert!(r1.x > r0.x, "caret moved right after typing: {r0:?} -> {r1:?}");
    assert!(r1.y >= OUTER_PADDING && r1.y + r1.height <= 60.0, "caret inside input row: {r1:?}");
    assert!(r1.height > 8.0 && r1.height < 50.0, "caret has a line height: {r1:?}");

    // text_editor: caret rect is inside the editor area, which is below the input.
    let mut h = Harness::new();
    h.click(EDITOR_POINT);
    h.type_ascii("hello");
    h.ime(input_method::Event::Preedit("ㄏㄢˋ".into(), full("ㄏㄢˋ")));
    let (pre, _, e1) = h.requested().unwrap();
    assert_eq!(pre, "ㄏㄢˋ");
    let editor_top = SIZE.height - OUTER_PADDING - EDITOR_HEIGHT;
    assert!(e1.y >= editor_top - 80.0 && e1.y < SIZE.height, "caret inside editor: {e1:?}");
    assert!(e1.y > r1.y, "editor caret is below input caret");

    // A second line moves the editor caret down.
    for ev in iced_test::simulator::tap_key(Named::Enter, None) {
        h.send(ev);
    }
    h.type_ascii("x");
    let (_, _, e2) = h.requested().unwrap();
    assert!(e2.y > e1.y, "caret moves down on a new line: {e1:?} -> {e2:?}");
}

#[test]
fn closed_event_drops_the_preedit() {
    let mut h = Harness::new();
    h.click(INPUT_POINT);
    h.ime(input_method::Event::Opened);
    h.ime(input_method::Event::Preedit("한".into(), full("한")));
    assert_eq!(h.requested().unwrap().0, "한");
    h.ime(input_method::Event::Closed);
    assert_eq!(h.requested().unwrap().0, "", "Closed clears the preedit");
    assert!(h.app.reply.is_empty());
}

/// Renders a PNG with a committed CJK line, a pending preedit and the overlay.
/// Written to `evidence/` so a human can check for tofu boxes.
#[test]
fn snapshot_with_preedit_and_cjk() {
    let mut h = Harness::new();
    h.click(INPUT_POINT);
    h.type_ascii("reply: ");
    h.ime(input_method::Event::Commit("漢字 かんじ 한글 ㄏㄢˋ".into()));
    h.ime(input_method::Event::Preedit("へんかん".into(), Some(0..6)));
    let ime = h.ime.clone();

    // Notes editor: committed multi-script text.
    h.app.update(Message::NotesEdited(iced::widget::text_editor::Action::Edit(
        iced::widget::text_editor::Edit::Paste(std::sync::Arc::new(
            "繁體中文 注音 ㄅㄆㄇㄈ\n日本語のテキスト\n한국어 입력".to_string(),
        )),
    )));

    let ui = UserInterface::build(
        h.app.view_with_overlay(&ime),
        SIZE,
        Cache::default(),
        &mut h.renderer,
    );
    let mut ui = ui;
    let _ = ui.update(
        &[Event::Window(iced::window::Event::RedrawRequested(
            std::time::Instant::now(),
        ))],
        mouse::Cursor::Unavailable,
        &mut h.renderer,
        &mut clipboard::Null,
        &mut Vec::new(),
    );
    let theme = Theme::Light;
    ui.draw(
        &mut h.renderer,
        &theme,
        &iced_test::core::renderer::Style { text_color: iced::Color::BLACK },
        mouse::Cursor::Unavailable,
    );
    let scale = 2.0;
    let phys = Size::new((SIZE.width * scale) as u32, (SIZE.height * scale) as u32);
    let rgba = h.renderer.screenshot(phys, scale, iced::Color::WHITE);
    assert_eq!(rgba.len(), (phys.width * phys.height * 4) as usize);

    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("evidence/preedit-cjk.png");
    write_png(&path, phys.width, phys.height, &rgba);
    // Not blank: some dark pixels exist.
    assert!(rgba.chunks(4).any(|p| p[0] < 100 && p[1] < 100 && p[2] < 100));
}

fn write_png(path: &std::path::Path, w: u32, h: u32, rgba: &[u8]) {
    let file = std::fs::File::create(path).expect("create png");
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), w, h);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header().unwrap().write_image_data(rgba).unwrap();
}

#[allow(dead_code)]
fn _unused(_: keyboard::Key) {}
