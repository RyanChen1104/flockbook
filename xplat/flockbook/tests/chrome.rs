//! Window chrome: the title bar per platform and the drag areas that replace it on macOS.
//! Headless (iced_test Simulator, tiny-skia). The real window is checked by the owner.

use fb_ui::theme::{SIDEBAR_W, TOPROW_H};
use fb_ui::Mode;
use flockbook::chrome::{self, ChromeMsg, TitleBar};
use flockbook::glass::Os;
use flockbook::state::Screen;
use flockbook::{App, Message};
use iced::{Point, Settings, Size};
use iced_test::{simulator, Simulator};

const SIZE: (f32, f32) = (1280.0, 852.0);

fn app(title_bar: TitleBar) -> App {
    let mut app = App::demo(Mode::Light, Screen::Conversation);
    app.state.chrome.title_bar = title_bar;
    app
}

/// Presses (or double-clicks) at `at` and returns the chrome messages.
fn press(app: &App, at: Point, double: bool) -> Vec<ChromeMsg> {
    std::env::set_var("ICED_TEST_BACKEND", "tiny-skia");
    let settings = Settings { fonts: fb_ui::fonts::bytes(), default_font: fb_ui::fonts::default_font(), ..Settings::default() };
    let mut sim: Simulator<'_, Message> = Simulator::with_size(settings, Size::new(SIZE.0, SIZE.1), app.view());
    sim.point_at(at);
    sim.simulate(simulator::click());
    if double {
        sim.simulate(simulator::click());
    }
    sim.into_messages().filter_map(|m| if let Message::Chrome(c) = m { Some(c) } else { None }).collect()
}

/// The empty top of the sidebar, right of the traffic lights.
const SIDEBAR_TOP: Point = Point::new(180.0, 20.0);
/// The empty middle of the top row in the demo (the tabs end well before it, the actions after it).
const TOPROW_GAP: Point = Point::new(SIDEBAR_W + 820.0, TOPROW_H / 2.0);

#[test]
fn only_macos_hides_the_title_bar() {
    assert_eq!(chrome::choose(Os::MacOs), TitleBar::Hidden);
    assert_eq!(chrome::choose(Os::Windows), TitleBar::Native);
    assert_eq!(chrome::choose(Os::Other), TitleBar::Native);
    assert_eq!(App::demo(Mode::Light, Screen::Conversation).state.chrome.title_bar, TitleBar::Native, "tests and snapshots keep the default");
}

#[cfg(target_os = "macos")]
#[test]
fn macos_window_is_transparent_full_size_and_untitled() {
    let s = chrome::window_settings(TitleBar::Hidden, iced::window::Settings::default());
    assert!(s.platform_specific.title_hidden && s.platform_specific.titlebar_transparent && s.platform_specific.fullsize_content_view);
    let native = chrome::window_settings(TitleBar::Native, iced::window::Settings::default());
    assert_eq!(native.platform_specific, Default::default());
}

#[test]
fn the_empty_top_moves_and_zooms_the_window_when_the_title_bar_is_hidden() {
    let a = app(TitleBar::Hidden);
    assert_eq!(press(&a, SIDEBAR_TOP, false), vec![ChromeMsg::Drag]);
    assert_eq!(press(&a, TOPROW_GAP, false), vec![ChromeMsg::Drag]);
    assert!(press(&a, TOPROW_GAP, true).contains(&ChromeMsg::Zoom));
}

#[test]
fn a_native_title_bar_leaves_the_content_alone() {
    let a = app(TitleBar::Native);
    assert!(press(&a, SIDEBAR_TOP, false).is_empty());
    assert!(press(&a, TOPROW_GAP, true).is_empty());
}

#[test]
fn controls_in_the_top_row_still_get_their_clicks() {
    // The tab pill and the nav rows are not drag areas.
    let a = app(TitleBar::Hidden);
    std::env::set_var("ICED_TEST_BACKEND", "tiny-skia");
    let settings = Settings { fonts: fb_ui::fonts::bytes(), default_font: fb_ui::fonts::default_font(), ..Settings::default() };
    let mut sim: Simulator<'_, Message> = Simulator::with_size(settings, Size::new(SIZE.0, SIZE.1), a.view());
    sim.click("ranking").expect("tab pill");
    sim.click("Overview").expect("nav row");
    let msgs: Vec<Message> = sim.into_messages().collect();
    assert!(!msgs.iter().any(|m| matches!(m, Message::Chrome(_))), "{msgs:?}");
    assert!(msgs.iter().any(|m| matches!(m, Message::Navigate(Screen::Overview))));
}

#[test]
fn drag_and_zoom_do_nothing_with_a_native_title_bar() {
    let mut a = app(TitleBar::Native);
    assert_eq!(a.update(Message::Chrome(ChromeMsg::Drag)).units(), 0);
    let mut a = app(TitleBar::Hidden);
    assert!(a.update(Message::Chrome(ChromeMsg::Drag)).units() > 0);
}
