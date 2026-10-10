//! Headless proof of cross-block drag selection and copy.
//! Uses `iced_test::Simulator` with the tiny-skia renderer. No window opens.

use iced::advanced::mouse;
use iced::keyboard::{self, key};
use iced::{Event, Point, Size, Theme};
use iced_test::Simulator;

use fb_ui::selectable::demo_app::{App, Message};
use fb_ui::selectable::model::{synthetic_conversation, Block, Kind, Pos, Selection};
use fb_ui::selectable::Geometry;

const WIDTH: f32 = 800.0;
const HEIGHT: f32 = 900.0;

fn app() -> App {
    // 40 messages: about 20 assistant messages with mixed Markdown and CJK.
    App::new(&synthetic_conversation(40))
}

fn simulator(app: &App) -> Simulator<'_, Message> {
    // Force the CPU renderer: no GPU, no window.
    std::env::set_var("ICED_TEST_BACKEND", "tiny-skia");
    Simulator::with_size(
        iced::Settings::default(),
        Size::new(WIDTH, HEIGHT),
        app.view(),
    )
}

fn geometry(app: &App) -> Geometry {
    Geometry::build(&app.blocks, &app.style(), WIDTH)
}

/// Index of the first block after `from` whose plain text starts with `prefix`.
fn find_block(blocks: &[Block], from: usize, prefix: &str) -> usize {
    blocks
        .iter()
        .enumerate()
        .skip(from)
        .find(|(_, b)| b.plain.starts_with(prefix))
        .unwrap_or_else(|| panic!("no block starting with {prefix:?}"))
        .0
}

/// Screen point just inside the glyph at `offset` of `block`.
fn point(geom: &Geometry, block: usize, offset: usize) -> Point {
    let p = geom.point_of(block, offset).expect("block laid out");
    Point::new(p.x + 1.0, p.y)
}

fn drag(sim: &mut Simulator<'_, Message>, from: Point, to: Point) {
    sim.point_at(from);
    sim.simulate([Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Left))]);
    // A few intermediate moves, like a real drag.
    for step in 1..=4 {
        let t = step as f32 / 4.0;
        let p = Point::new(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
        sim.point_at(p);
        sim.simulate([Event::Mouse(mouse::Event::CursorMoved { position: p })]);
    }
    sim.simulate([Event::Mouse(mouse::Event::ButtonReleased(mouse::Button::Left))]);
}

fn key_event(ch: &str) -> Event {
    let k = keyboard::Key::Character(ch.into());
    Event::Keyboard(keyboard::Event::KeyPressed {
        key: k.clone(),
        modified_key: k,
        physical_key: key::Physical::Unidentified(key::NativeCode::Unidentified),
        location: keyboard::Location::Standard,
        modifiers: keyboard::Modifiers::COMMAND,
        repeat: false,
        text: None,
    })
}

/// Builds a fresh interface from `app`, plays `script` on it, then feeds the
/// produced messages back into `app`. One interface per gesture keeps the
/// widget's drag state alive between events.
fn run(app: &mut App, script: impl FnOnce(&mut Simulator<'_, Message>)) {
    let messages: Vec<Message> = {
        let mut sim = simulator(app);
        script(&mut sim);
        sim.into_messages().collect()
    };
    for message in messages {
        app.update(message);
    }
}

#[test]
fn conversation_has_40_messages_and_mixed_blocks() {
    let app = app();
    let kinds = |pred: fn(&Kind) -> bool| app.blocks.iter().filter(|b| pred(&b.kind)).count();
    assert!(kinds(|k| matches!(k, Kind::Role)) == 40);
    assert!(kinds(|k| matches!(k, Kind::Code)) >= 20);
    assert!(kinds(|k| matches!(k, Kind::ListItem { .. })) >= 60);
    assert!(kinds(|k| matches!(k, Kind::Heading(_))) >= 20);
    // Plain text carries no Markdown syntax.
    for b in &app.blocks {
        assert!(!b.plain.contains("**") && !b.plain.contains("]("), "{:?}", b.plain);
    }
}

#[test]
fn drag_across_paragraph_list_and_code_copies_plain_text() {
    let mut app = app();
    let a = find_block(&app.blocks, 0, "The parser reads each line");
    let first_item = find_block(&app.blocks, a, "First, load");
    let code = find_block(&app.blocks, a, "fn render_");
    assert_eq!(first_item, a + 1);
    assert_eq!(code, a + 4, "A, three list items, then code");

    let geom = geometry(&app);
    let start_off = app.blocks[a].plain.find("keeps").unwrap();
    let end_off = app.blocks[code].plain.find("let").unwrap() + 3;
    let from = point(&geom, a, start_off);
    let to = point(&geom, code, end_off);

    run(&mut app, |sim| {
    drag(sim, from, to);
    sim.simulate([key_event("c")]);
    });

    let selection = app.selection.expect("selection published");
    assert_eq!(selection.anchor, Pos { block: a, offset: start_off });
    assert_eq!(selection.focus, Pos { block: code, offset: end_off });

    let expected = concat!(
        "keeps state_1 in sync. See the notes for the full story, ",
        "including why the cache is not cleared on reload.",
        "\n\n",
        "First, load the session file number 1\n",
        "Then, split it into turns\n",
        "Finally, render each turn as a block",
        "\n\n",
        "fn render_1(turn: &Turn) -> Block {\n    let",
    );
    assert_eq!(app.last_copied.as_deref(), Some(expected));
}

#[test]
fn drag_inside_one_block_and_backwards() {
    let mut app = app();
    let a = find_block(&app.blocks, 0, "The parser reads each line");
    let geom = geometry(&app);
    let plain = app.blocks[a].plain.clone();
    let s = plain.find("reads").unwrap();
    let e = s + "reads each line".len();

    // Forward.
    run(&mut app, |sim| {
    drag(sim, point(&geom, a, s), point(&geom, a, e));
    sim.simulate([key_event("c")]);
    });
    assert_eq!(app.last_copied.as_deref(), Some("reads each line"));

    // Backward (focus before anchor) gives the same text.
    app.last_copied = None;
    run(&mut app, |sim| {
    drag(sim, point(&geom, a, e), point(&geom, a, s));
    sim.simulate([key_event("c")]);
    });
    assert_eq!(app.last_copied.as_deref(), Some("reads each line"));
}

#[test]
fn cjk_selection() {
    let mut app = app();
    let b = find_block(&app.blocks, 0, "這是一段中文測試文字");
    let geom = geometry(&app);
    let plain = app.blocks[b].plain.clone();
    let s = plain.find("中文").unwrap();
    let e = plain.find("文字").unwrap();

    run(&mut app, |sim| {
    drag(sim, point(&geom, b, s), point(&geom, b, e));
    sim.simulate([key_event("c")]);
    });
    assert_eq!(app.last_copied.as_deref(), Some("中文測試"));
}

#[test]
fn cjk_user_message_to_assistant_heading_crosses_messages() {
    let mut app = app();
    // Message 0 (user, CJK tail) to message 1 heading: crosses a role label.
    let user = find_block(&app.blocks, 0, "Please fix issue 0");
    let heading = find_block(&app.blocks, user, "Step 1: check");
    let geom = geometry(&app);
    let s = app.blocks[user].plain.find("請幫我").unwrap();
    let e = "Step 1".len();

    run(&mut app, |sim| {
    drag(sim, point(&geom, user, s), point(&geom, heading, e));
    sim.simulate([key_event("c")]);
    });
    assert_eq!(
        app.last_copied.as_deref(),
        Some("請幫我修正第 0 個問題，並說明原因。\n\nAssistant\n\nStep 1")
    );
}

#[test]
fn click_without_drag_clears_selection() {
    let mut app = app();
    let a = find_block(&app.blocks, 0, "The parser reads each line");
    let geom = geometry(&app);
    app.selection = Some(Selection {
        anchor: Pos { block: a, offset: 4 },
        focus: Pos { block: a, offset: 20 },
    });

    let at = point(&geom, a, 30);
    run(&mut app, |sim| {
    sim.point_at(at);
    sim.simulate([
        Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Left)),
        Event::Mouse(mouse::Event::ButtonReleased(mouse::Button::Left)),
    ]);
    // Copy after the click has nothing to copy.
    sim.simulate([key_event("c")]);
    });

    assert_eq!(app.selection, None);
    assert_eq!(app.last_copied, None);
}

#[test]
fn click_outside_the_text_area_clears_selection() {
    let mut app = app();
    let a = find_block(&app.blocks, 0, "The parser reads each line");
    app.selection = Some(Selection {
        anchor: Pos { block: a, offset: 4 },
        focus: Pos { block: a, offset: 20 },
    });
    // Cursor unavailable (outside the window): a press must still clear.
    run(&mut app, |sim| {
    sim.simulate([Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Left))]);
    });
    assert_eq!(app.selection, None);
}

#[test]
fn select_all_then_copy_returns_every_block() {
    let mut app = app();
    run(&mut app, |sim| {
    sim.simulate([key_event("a"), key_event("c")]);
    });

    let copied = app.last_copied.expect("copied");
    assert!(copied.starts_with("You\n\nPlease fix issue 0."));
    assert!(copied.ends_with("Remember: keep the diff small."));
    assert_eq!(copied.matches("Assistant").count(), 20);
    assert!(copied.contains("第 39 步完成後"));
}

#[test]
fn drag_below_the_last_block_selects_to_the_end() {
    let mut app = app();
    let last = app.blocks.len() - 1;
    let a = find_block(&app.blocks, 0, "The parser reads each line");
    let geom = geometry(&app);

    // Drag from the first paragraph to a point below the document's visible
    // area. Scrolling is not simulated, so the focus clamps to the visible
    // bottom; this only checks that leaving the text area keeps the drag alive.
    run(&mut app, |sim| {
    drag(
        sim,
        point(&geom, a, 10),
        Point::new(WIDTH - 2.0, HEIGHT - 2.0),
    );
    });
    let sel = app.selection.expect("selection");
    assert!(sel.focus.block > a && sel.focus.block <= last);
}

/// Decodes a PNG into RGBA bytes.
fn read_png(path: &std::path::Path) -> (u32, u32, Vec<u8>) {
    let decoder = png::Decoder::new(std::io::BufReader::new(std::fs::File::open(path).unwrap()));
    let mut reader = decoder.read_info().unwrap();
    let mut buf = vec![0; reader.output_buffer_size().unwrap()];
    let info = reader.next_frame(&mut buf).unwrap();
    buf.truncate(info.buffer_size());
    (info.width, info.height, buf)
}

#[test]
fn snapshot_shows_highlight_spanning_blocks() {
    let mut app = app();
    let a = find_block(&app.blocks, 0, "The parser reads each line");
    let code = find_block(&app.blocks, a, "fn render_");
    let cjk = find_block(&app.blocks, code, "這是一段中文");
    let geom = geometry(&app);
    let start = app.blocks[a].plain.find("keeps").unwrap();
    let end = app.blocks[cjk].plain.find("請再").unwrap();
    app.selection = Some(Selection {
        anchor: Pos { block: a, offset: start },
        focus: Pos { block: cjk, offset: end },
    });
    // Sanity: the geometry puts the focus inside the visible window.
    assert!(geom.point_of(cjk, end).unwrap().y < HEIGHT);

    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join("snap");
    let _ = std::fs::remove_dir_all(&dir);
    let snapshot = simulator(&app).snapshot(&Theme::Light).expect("snapshot");
    assert!(snapshot.matches_image(dir.join("cross-block")).unwrap());

    let png_path = std::fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .find(|p| p.extension().is_some_and(|e| e == "png"))
        .expect("png written");
    let (w, h, rgba) = read_png(&png_path);
    assert_eq!((w, h), ((WIDTH * 2.0) as u32, (HEIGHT * 2.0) as u32));

    // Count pixels of the highlight color (primary.weak of the Light theme).
    let c = Theme::Light.extended_palette().primary.weak.color.into_rgba8();
    let highlighted = rgba
        .chunks_exact(4)
        .filter(|p| p[0] == c[0] && p[1] == c[1] && p[2] == c[2])
        .count();
    assert!(highlighted > 5_000, "only {highlighted} highlight pixels");

    // Same view without selection has (almost) none of that color.
    app.selection = None;
    let plain_dir = dir.join("none");
    simulator(&app)
        .snapshot(&Theme::Light)
        .unwrap()
        .matches_image(plain_dir.join("plain"))
        .unwrap();
    let plain_png = std::fs::read_dir(&plain_dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .find(|p| p.extension().is_some_and(|e| e == "png"))
        .unwrap();
    let (_, _, plain_rgba) = read_png(&plain_png);
    let baseline = plain_rgba
        .chunks_exact(4)
        .filter(|p| p[0] == c[0] && p[1] == c[1] && p[2] == c[2])
        .count();
    assert!(baseline < highlighted / 20, "baseline {baseline} vs {highlighted}");
    eprintln!("highlight pixels: {highlighted}, without selection: {baseline}");

    if std::env::var_os("FB_WRITE_EVIDENCE").is_some() {
        let evidence = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("evidence");
        std::fs::create_dir_all(&evidence).unwrap();
        std::fs::copy(&png_path, evidence.join("cross-block-selection.png")).unwrap();
    }
}

#[test]
fn layout_cost_of_40_and_400_messages() {
    for count in [40, 400] {
        let app = App::new(&synthetic_conversation(count));
        let start = std::time::Instant::now();
        let geom = Geometry::build(&app.blocks, &app.style(), WIDTH);
        eprintln!(
            "{count} messages, {} blocks: shaped in {:?} (debug build), height {:.0}px",
            app.blocks.len(),
            start.elapsed(),
            geom.total.height
        );
    }
}

#[test]
fn empty_document_does_not_panic_on_layout_draw_click_or_copy() {
    let mut app = App::new(&[]);
    assert!(app.blocks.is_empty());
    // Layout.
    let geom = Geometry::build(&app.blocks, &app.style(), WIDTH);
    assert!(geom.point_of(0, 0).is_none());
    // Draw, click, drag, select all, copy, all on the empty document.
    run(&mut app, |sim| {
        let p = Point::new(100.0, 100.0);
        sim.point_at(p);
        sim.simulate([Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Left))]);
        sim.simulate([Event::Mouse(mouse::Event::CursorMoved { position: Point::new(300.0, 400.0) })]);
        sim.simulate([Event::Mouse(mouse::Event::ButtonReleased(mouse::Button::Left))]);
        sim.simulate([key_event("a")]);
        sim.simulate([key_event("c")]);
        let _ = sim.snapshot(&Theme::Light).expect("draws an empty document");
    });
    assert!(app.selection.is_none());
    assert!(app.last_copied.is_none());
}
