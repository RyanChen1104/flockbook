//! Evidence for the evaluation: `iced_selection` selects inside one widget only.
//! A drag from the first text widget into the second highlights the first and
//! leaves the second untouched.

use iced::advanced::mouse;
use iced::widget::{column, space};
use iced::{Element, Event, Length, Point, Size, Theme};
use iced_test::Simulator;

fn view<'a>() -> Element<'a, ()> {
    column![
        iced_selection::text("first widget with some words to select").size(18),
        space().height(Length::Fixed(200.0)),
        iced_selection::text("second widget with other words").size(18),
    ]
    .padding(10)
    .into()
}

fn highlight_rows(rgba: &[u8], width: u32, color: [u8; 4]) -> Vec<u32> {
    let mut rows = Vec::new();
    for (i, p) in rgba.chunks_exact(4).enumerate() {
        if p[0] == color[0] && p[1] == color[1] && p[2] == color[2] {
            rows.push(i as u32 / width);
        }
    }
    rows
}

#[test]
fn drag_from_first_to_second_widget_highlights_only_the_first() {
    std::env::set_var("ICED_TEST_BACKEND", "tiny-skia");
    let mut sim = Simulator::with_size(iced::Settings::default(), Size::new(400.0, 300.0), view());
    sim.point_at(Point::new(12.0, 20.0));
    sim.simulate([Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Left))]);
    for p in [Point::new(100.0, 100.0), Point::new(150.0, 235.0)] {
        sim.point_at(p);
        sim.simulate([Event::Mouse(mouse::Event::CursorMoved { position: p })]);
    }
    sim.simulate([Event::Mouse(mouse::Event::ButtonReleased(mouse::Button::Left))]);

    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join("single");
    let _ = std::fs::remove_dir_all(&dir);
    sim.snapshot(&Theme::Light)
        .unwrap()
        .matches_image(dir.join("single"))
        .unwrap();
    let path = std::fs::read_dir(&dir).unwrap().next().unwrap().unwrap().path();
    let decoder = png::Decoder::new(std::io::BufReader::new(std::fs::File::open(path).unwrap()));
    let mut reader = decoder.read_info().unwrap();
    let mut buf = vec![0; reader.output_buffer_size().unwrap()];
    let info = reader.next_frame(&mut buf).unwrap();

    let c = Theme::Light.extended_palette().primary.weak.color.into_rgba8();
    let rows = highlight_rows(&buf[..info.buffer_size()], info.width, c);
    let first = rows.iter().filter(|r| **r < 120).count();
    let second = rows.iter().filter(|r| **r >= 400).count();
    eprintln!("highlight pixels first widget: {first}, second widget: {second}");
    assert!(first > 0, "first widget should show a selection");
    assert_eq!(second, 0, "iced_selection does not extend into another widget");
}
