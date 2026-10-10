//! Flockbook (iced): a reading view for Herdr agents. Unofficial; not affiliated with Herdr, Inc.
//!
//! # Contract for module builders
//!
//! ```text
//! App { state: State, source: Box<dyn DataSource> }
//! App::update(Message) -> Task<Message>        // routes to the module updates below
//! App::view() -> Element<Message>              // sidebar | (toprow / main area)
//! ```
//!
//! Layout: sidebar (fixed `SIDEBAR_W`) | right column = top row (`TOPROW_H` = 52) + main area. The main area shows
//! `state.screen`: Conversation (conversation + composer), Overview, NeedsYou or Search (stubs for step 3).
//!
//! Each module file owns ONE area and exposes exactly this shape:
//!
//! ```text
//! pub struct XState { .. }            // own state, `Default`; registered as ONE field in state.rs
//! pub enum XMsg { .. }                // own messages; wrapped as `Message::X(XMsg)`
//! pub fn view(app: &App) -> Element<'_, Message>
//! pub fn update(app: &mut App, msg: XMsg) -> Task<Message>
//! ```
//!
//! | file              | owns                                  | state field          | Message variant      |
//! |-------------------|---------------------------------------|----------------------|----------------------|
//! | `sidebar.rs`      | sidebar (nav, workspace rows)         | `state.sidebar`      | `Message::Sidebar`   |
//! | `toprow.rs`       | top row (tabs strip, actions)         | `state.toprow`       | `Message::TopRow`    |
//! | `overview.rs`     | Overview, NeedsYou, Search screens    | `state.overview`     | `Message::Overview`  |
//! | `conversation.rs` | conversation list                     | `state.conversation` | `Message::Conversation` |
//! | `composer.rs`     | composer and approval/question cards  | `state.composer`     | `Message::Composer`  |
//!
//! Shared and cross-cutting things live in `state.rs` (State, Screen, selection, helpers), `source.rs` (DataSource),
//! `style.rs` (container styles), `demo.rs` (demo data), `snapshot.rs` (headless render). Cross-module actions
//! (navigate, select a workspace or tab) are plain `Message` variants handled in `App::update`; a module sends them
//! instead of editing another module's state.
//!
//! Design tokens, fonts, icons and status symbols come from `fb-ui`. Never hard-code a color: use `Tokens`.

pub mod composer;
pub mod conversation;
pub mod demo;
pub mod overview;
pub mod sidebar;
pub mod snapshot;
pub mod source;
pub mod state;
pub mod style;
pub mod toprow;

use fb_ui::theme::{Tokens, SIDEBAR_W};
use fb_ui::Mode;
use iced::widget::{column, container, row, Space};
use iced::{Element, Length, Task, Theme};
use source::DataSource;
use state::{Screen, State};

pub use state::Screen as AppScreen;

#[derive(Debug, Clone)]
pub enum Message {
    /// Cross-cutting actions, handled in `App::update`.
    Navigate(Screen),
    SelectWorkspace(String),
    SelectTab { workspace: String, tab: String },
    SelectPane(String),
    SetMode(Mode),
    /// Polls the source. Fired by the subscription in `main.rs`.
    Tick,
    Noop,
    // One wrapper per module.
    Sidebar(sidebar::SidebarMsg),
    TopRow(toprow::TopRowMsg),
    Overview(overview::OverviewMsg),
    Conversation(conversation::ConversationMsg),
    Composer(composer::ComposerMsg),
}

pub struct App {
    pub state: State,
    pub source: Box<dyn DataSource>,
}

impl App {
    pub fn new(source: Box<dyn DataSource>, mode: Mode, screen: Screen) -> App {
        let mut state = State::new(mode, screen);
        state.session_label = source.label();
        let mut app = App { state, source };
        app.refresh();
        app
    }

    /// An app on the demo data with Quarry / ranking selected (what the snapshots show).
    pub fn demo(mode: Mode, screen: Screen) -> App {
        let demo = demo::DemoSource::new();
        let (ws, tab) = demo.default_selection();
        let mut app = App::new(Box::new(demo), mode, screen);
        app.state.select_tab(&ws, &tab);
        app.state.overview.clock = Some(overview::Clock::demo());
        app.refresh();
        app
    }

    pub fn tokens(&self) -> Tokens {
        Tokens::of(self.state.mode)
    }

    pub fn theme(&self) -> Theme {
        self.tokens().iced_theme()
    }

    pub fn title(&self) -> String {
        match (self.state.selected_workspace(), self.state.selected_tab()) {
            (Some(w), Some(t)) => format!("{} \u{2014} {}", w.label, t.label),
            _ => "Flockbook".to_string(),
        }
    }

    /// Pulls the tree and the selected conversation from the source.
    pub fn refresh(&mut self) {
        self.state.reload(self.source.as_ref());
        conversation::sync_markdown(self);
    }

    pub fn update(&mut self, message: Message) -> Task<Message> {
        match message {
            Message::Navigate(screen) => {
                self.state.screen = screen;
                Task::none()
            }
            Message::SelectWorkspace(id) => {
                self.state.select_workspace(&id);
                self.state.screen = Screen::Conversation;
                self.refresh();
                Task::none()
            }
            Message::SelectTab { workspace, tab } => {
                self.state.select_tab(&workspace, &tab);
                self.state.screen = Screen::Conversation;
                self.refresh();
                Task::none()
            }
            Message::SelectPane(id) => {
                self.state.selected_pane = Some(id);
                self.refresh();
                Task::none()
            }
            Message::SetMode(mode) => {
                self.state.mode = mode;
                Task::none()
            }
            Message::Tick => {
                self.refresh();
                Task::none()
            }
            Message::Noop => Task::none(),
            Message::Sidebar(m) => sidebar::update(self, m),
            Message::TopRow(m) => toprow::update(self, m),
            Message::Overview(m) => overview::update(self, m),
            Message::Conversation(m) => conversation::update(self, m),
            Message::Composer(m) => composer::update(self, m),
        }
    }

    pub fn view(&self) -> Element<'_, Message> {
        let t = self.tokens();
        let main: Element<Message> = match self.state.screen {
            Screen::Conversation => column![conversation::view(self), composer::view(self)].into(),
            Screen::Overview | Screen::NeedsYou | Screen::Search => overview::view(self),
        };
        let right = column![container(toprow::view(self)).height(Length::Fixed(fb_ui::theme::TOPROW_H)), container(main).width(Length::Fill).height(Length::Fill)];
        let body = row![
            container(sidebar::view(self)).width(Length::Fixed(SIDEBAR_W)).height(Length::Fill).style(style::sidebar(t)),
            container(right).width(Length::Fill).height(Length::Fill).style(style::content(t)),
        ];
        container(iced::widget::stack![body, toprow::menu_layer(self)]).width(Length::Fill).height(Length::Fill).style(style::content(t)).into()
    }
}

/// A placeholder body for a screen that is not built yet.
pub fn stub<'a>(app: &App, title: &'a str) -> Element<'a, Message> {
    let t = app.tokens();
    container(column![fb_ui::theme::TITLE_3.text(title).color(t.label), Space::new().height(4), fb_ui::theme::BODY.text("Not built yet.").color(t.label_2)]
        .align_x(iced::Alignment::Center))
    .center(Length::Fill)
    .into()
}

