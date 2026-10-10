//! Needs you screen: list, selection, keys, badge, empty state, and the pane-action gate. Headless (iced_test
//! Simulator, tiny-skia); no window. Pane actions are a recording fake: no herdr is ever called.

use fb_ui::Mode;
use flockbook::actions::RecordingActions;
use flockbook::cards::{Card, CardsMsg};
use flockbook::needs_you::{items, selected_index, NeedsYouMsg};
use flockbook::snapshot::{distinct_colors, render_app, write_png};
use flockbook::source::{DataSource, DemoSource};
use flockbook::state::Screen;
use flockbook::{App, Message};
use herdr_core::{AgentStatus, ConversationItem, Pane, Workspace};
use iced::{Settings, Size};
use iced_test::Simulator;
use std::sync::Arc;

/// Demo data with every blocked tab turned into a done one.
struct Calm(DemoSource);

impl DataSource for Calm {
    fn label(&self) -> String {
        "calm".into()
    }
    fn workspaces(&self) -> Vec<Workspace> {
        let mut w = self.0.workspaces();
        for ws in &mut w {
            for t in &mut ws.tabs {
                if t.status == AgentStatus::Blocked {
                    t.status = AgentStatus::Done;
                    for p in &mut t.panes {
                        if let Some(a) = p.agent.as_mut() {
                            a.status = AgentStatus::Done;
                        }
                    }
                }
            }
        }
        w
    }
    fn connected(&self) -> bool {
        true
    }
    fn conversation(&self, pane: &Pane) -> Vec<ConversationItem> {
        self.0.conversation(pane)
    }
}

fn app(mode: Mode) -> App {
    App::demo(mode, Screen::NeedsYou)
}

fn sim(app: &App) -> Simulator<'_, Message> {
    std::env::set_var("ICED_TEST_BACKEND", "tiny-skia");
    let settings = Settings { fonts: fb_ui::fonts::bytes(), default_font: fb_ui::fonts::default_font(), ..Settings::default() };
    Simulator::with_size(settings, Size::new(1280.0, 852.0), app.view())
}

fn run(a: &mut App, msg: NeedsYouMsg) {
    let _ = a.update(Message::NeedsYou(msg));
}

#[test]
fn sidebar_badge_count_equals_list_length() {
    let a = app(Mode::Light);
    assert_eq!(items(&a).len(), 2);
    assert_eq!(a.state.blocked_tabs().len(), items(&a).len(), "the sidebar badge counts blocked_tabs()");
    let mut s = sim(&a);
    for name in ["harbor-deploy-ops", "lighthouse-start-docs", "Needs you"] {
        assert!(s.find(name).is_ok(), "{name} missing");
    }
}

#[test]
fn detail_shows_the_selected_request() {
    let mut a = app(Mode::Light);
    {
        let mut s = sim(&a);
        assert!(s.find("Wants to run a command").is_ok());
        assert!(s.find("./scripts/deploy.sh --env staging").is_ok());
    }
    let second = items(&a)[1].tab.id.clone();
    run(&mut a, NeedsYouMsg::Select(second));
    let mut s = sim(&a);
    // The second blocked demo pane asks a question: the real question card shows.
    assert!(matches!(a.state.cards.card, Some(Card::Question { .. })), "{:?}", a.state.cards.card);
    assert!(s.find("Send").is_ok());
}

#[test]
fn arrows_move_and_clamp() {
    let mut a = app(Mode::Light);
    assert_eq!(selected_index(&a), Some(0));
    run(&mut a, NeedsYouMsg::Move(-1));
    assert_eq!(selected_index(&a), Some(0));
    run(&mut a, NeedsYouMsg::Move(1));
    assert_eq!(selected_index(&a), Some(1));
    run(&mut a, NeedsYouMsg::Move(1));
    assert_eq!(selected_index(&a), Some(1));
}

#[test]
fn enter_opens_the_selected_conversation() {
    // Item 0 is an approval; Enter on a question card belongs to the card.
    let mut a = app(Mode::Light);
    let want = items(&a)[0].tab.id.clone();
    run(&mut a, NeedsYouMsg::OpenSelected);
    assert_eq!(a.state.screen, Screen::Conversation);
    assert_eq!(a.state.selected_tab.as_deref(), Some(want.as_str()));
}

#[test]
fn clicking_a_row_selects_it() {
    let mut a = app(Mode::Light);
    let msgs: Vec<Message> = {
        let mut s = sim(&a);
        s.click("lighthouse-start-docs").expect("row");
        s.into_messages().collect()
    };
    assert!(msgs.iter().any(|m| matches!(m, Message::NeedsYou(NeedsYouMsg::Select(_)))), "{msgs:?}");
    for m in msgs {
        let _ = a.update(m);
    }
    assert_eq!(selected_index(&a), Some(1));
}

#[test]
fn selecting_an_item_targets_its_pane_and_shows_the_real_card() {
    let mut a = app(Mode::Light);
    let first_pane = items(&a)[0].blocked_pane().unwrap().id.clone();
    assert_eq!(a.state.selected_pane().map(|p| p.id.clone()), Some(first_pane));
    assert!(matches!(a.state.cards.card, Some(Card::Approval(_))));
    run(&mut a, NeedsYouMsg::Move(1));
    let second = items(&a)[1].blocked_pane().unwrap().id.clone();
    assert_eq!(a.state.selected_pane().map(|p| p.id.clone()), Some(second));
    assert_eq!(a.state.screen, Screen::NeedsYou, "selecting does not leave the screen");
}

#[test]
fn allow_and_deny_go_through_the_card_and_the_fake() {
    let mut a = app(Mode::Light);
    let pane = items(&a)[0].blocked_pane().unwrap().id.clone();
    let command = match &a.state.cards.card {
        Some(Card::Approval(x)) => x.command.clone(),
        other => panic!("{other:?}"),
    };
    let rec = Arc::new(RecordingActions::new(&format!("Bash command\n  {command}\n\nDo you want to proceed?\n \u{276F} 1. Yes\n   2. No\n")));
    a.state.cards.actions = Some(rec.clone());
    // The fake's screen replaces the demo screen the card was first seen with: start the card's "seen prompt" afresh.
    a.state.cards.pinned = None;
    flockbook::cards::read_now(&mut a);
    assert!(matches!(&a.state.cards.card, Some(Card::Approval(x)) if x.can_act), "{:?}", a.state.cards.card);
    // The update spawns a worker thread; wait for the send.
    let _ = a.update(Message::Cards(CardsMsg::Deny));
    for _ in 0..100 {
        if !rec.mutations().is_empty() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    let calls = format!("{:?} card={:?} all={:?}", rec.mutations(), a.state.cards.card, rec.calls());
    assert!(calls.contains(&pane) && calls.contains("Escape"), "{calls}");
}

#[test]
fn a_question_card_owns_enter() {
    let mut a = app(Mode::Light);
    run(&mut a, NeedsYouMsg::Move(1));
    assert!(matches!(a.state.cards.card, Some(Card::Question { .. })));
    run(&mut a, NeedsYouMsg::OpenSelected);
    assert_eq!(a.state.screen, Screen::NeedsYou);
}

#[test]
fn empty_state_says_all_caught_up() {
    let a = App::new(Box::new(Calm(DemoSource::new())), Mode::Light, Screen::NeedsYou);
    assert!(items(&a).is_empty());
    let mut s = sim(&a);
    assert!(s.find("All caught up").is_ok());
    assert!(s.find("harbor-deploy-ops").is_err());
}

fn shot(a: &App, name: &str) {
    let img = render_app(a, (1280, 852));
    assert!(distinct_colors(&img) > 20, "{name} looks blank");
    write_png(&img, &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("evidence").join(name)).unwrap();
}

#[test]
fn snapshots() {
    for (mode, tag) in [(Mode::Light, "light"), (Mode::Dark, "dark")] {
        let mut a = app(mode);
        shot(&a, &format!("needs-you-{tag}.png"));
    }
    let mut a = App::new(Box::new(Calm(DemoSource::new())), Mode::Light, Screen::NeedsYou);
    a.state.overview.clock = Some(flockbook::overview::Clock::demo());
    shot(&a, "needs-you-empty-light.png");
}
