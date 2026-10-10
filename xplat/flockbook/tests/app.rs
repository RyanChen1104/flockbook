//! Integration of Needs you, Search and the cards at app level. Headless; nothing is sent to a live herdr.
//! Evidence PNGs go to `evidence/app-*.png`.

use fb_ui::Mode;
use flockbook::cards::{self, Card};
use flockbook::search::{self, on_key, SearchMsg};
use flockbook::snapshot::{distinct_colors, render_app, write_png};
use flockbook::state::Screen;
use flockbook::{App, Message};
use iced::keyboard::{Key, Modifiers};
use iced::{Settings, Size};
use iced_test::Simulator;

fn sim(app: &App) -> Simulator<'_, Message> {
    std::env::set_var("ICED_TEST_BACKEND", "tiny-skia");
    let settings = Settings { fonts: fb_ui::fonts::bytes(), default_font: fb_ui::fonts::default_font(), ..Settings::default() };
    Simulator::with_size(settings, Size::new(1280.0, 852.0), app.view())
}

fn shot(a: &App, name: &str) {
    let img = render_app(a, (1280, 852));
    assert!(distinct_colors(&img) > 20, "{name} looks blank");
    write_png(&img, &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("evidence").join(name)).unwrap();
}

fn searching(mode: Mode, q: &str) -> App {
    let mut a = App::demo(mode, Screen::Search);
    search::preload_all(&mut a);
    let _ = a.update(Message::Search(SearchMsg::Open));
    let _ = a.update(Message::Search(SearchMsg::Input(q.to_string())));
    a
}

#[test]
fn sidebar_items_route_to_their_screens() {
    let a = App::demo(Mode::Light, Screen::Conversation);
    let msgs: Vec<Message> = {
        let mut s = sim(&a);
        s.click("Search").expect("search row");
        s.into_messages().collect()
    };
    assert!(msgs.iter().any(|m| matches!(m, Message::Search(SearchMsg::Open))), "{msgs:?}");
    let mut a = a;
    for m in msgs {
        let _ = a.update(m);
    }
    assert_eq!(a.state.screen, Screen::Search);

    let mut a = App::demo(Mode::Light, Screen::Conversation);
    let msgs: Vec<Message> = {
        let mut s = sim(&a);
        s.click("Needs you").expect("needs you row");
        s.into_messages().collect()
    };
    for m in msgs {
        let _ = a.update(m);
    }
    assert_eq!(a.state.screen, Screen::NeedsYou);
    assert!(matches!(a.state.cards.card, Some(Card::Approval(_))), "the first blocked request shows its real card");
}

#[test]
fn cmd_f_opens_search_from_any_screen() {
    for on_screen in [false, true] {
        let m = on_key(Key::Character("f".into()), Modifiers::COMMAND, on_screen);
        assert!(m.is_some() || on_screen, "Cmd+F opens Search from a non-search screen");
    }
    let mut a = App::demo(Mode::Light, Screen::Overview);
    let m = on_key(Key::Character("f".into()), Modifiers::COMMAND, false).expect("Cmd+F");
    let _ = a.update(m);
    assert_eq!(a.state.screen, Screen::Search);
}

#[test]
fn a_message_result_reveals_the_conversation() {
    let mut a = searching(Mode::Light, "ranking");
    assert!(!a.state.search.messages.is_empty(), "demo conversations contain the word");
    let i = a.state.search.tabs.len();
    let hit = a.state.search.messages[0].clone();
    let _ = a.update(Message::Search(SearchMsg::Click(i)));
    assert_eq!(a.state.screen, Screen::Conversation);
    assert_eq!(a.state.selected_tab.as_deref(), Some(hit.tab.as_str()));
    assert_eq!(a.state.selected_pane().map(|p| p.id.clone()), Some(hit.pane));
}

#[test]
fn blocked_panes_show_a_card_in_the_conversation() {
    let a = cards::demo_app_on_tab(Mode::Light, Screen::Conversation, "deploy");
    assert!(matches!(a.state.cards.card, Some(Card::Approval(_))));
    let a = cards::demo_app_on_tab(Mode::Light, Screen::Conversation, "getting started");
    assert!(matches!(a.state.cards.card, Some(Card::Question { .. })));
    let a = cards::demo_app_on_tab(Mode::Light, Screen::Conversation, "ranking");
    assert!(a.state.cards.card.is_none());
}

#[test]
fn app_snapshots() {
    for (mode, tag) in [(Mode::Light, "light"), (Mode::Dark, "dark")] {
        shot(&App::demo(mode, Screen::NeedsYou), &format!("app-needs-you-{tag}.png"));
        shot(&searching(mode, "ranking"), &format!("app-search-{tag}.png"));
        shot(&cards::demo_app_on_tab(mode, Screen::Conversation, "deploy"), &format!("app-approval-{tag}.png"));
        shot(&cards::demo_app_on_tab(mode, Screen::Conversation, "getting started"), &format!("app-question-{tag}.png"));
    }
    let mut a = App::demo(Mode::Light, Screen::NeedsYou);
    let _ = a.update(Message::NeedsYou(flockbook::needs_you::NeedsYouMsg::Move(1)));
    shot(&a, "app-needs-you-question-light.png");
}

/// The log's command is not the one the screen asks about: the card stays, its buttons are off, and it says to open
/// the terminal. Evidence: `app-approval-mismatch-light.png`.
#[test]
fn a_mismatched_prompt_shows_the_open_the_terminal_state() {
    let mut a = cards::demo_app_on_tab(Mode::Light, Screen::Conversation, "deploy");
    let other = "Bash command\n  ./scripts/deploy.sh --env production; rm -rf build\n\nDo you want to proceed?\n \u{276F} 1. Yes\n   2. No\n";
    a.state.cards.actions = Some(std::sync::Arc::new(flockbook::actions::RecordingActions::new(other)));
    a.refresh();
    match &a.state.cards.card {
        Some(Card::Approval(c)) => assert!(c.unbound && !c.can_act, "{c:?}"),
        other => panic!("approval card expected, got {other:?}"),
    }
    assert!(sim(&a).find(flockbook::actions::PROMPT_MISMATCH).is_ok(), "the card says to open the terminal");
    shot(&a, "app-approval-mismatch-light.png");
}
