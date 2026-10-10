//! Composer: the floating reply card at the bottom of the conversation column. DESIGN.md section 8.
//!
//! Enter sends, Shift+Enter inserts a newline (same as the Swift app). The editor grows to `MAX_LINES` lines, then
//! scrolls. IME works through iced's own `text_editor`: preedit is shown but not committed, a commit lands at the caret.
//! Approval and question cards are not part of this module yet.
//!
//! # Sending
//!
//! Sending goes through the [`MessageSender`] trait. The real implementation, [`LiveSender`], writes to a herdr pane
//! (`pane.send_input`, text plus Enter). That is a MUTATING call. It is only installed by the live path in `main.rs`.
//! Tests never construct `LiveSender`: they use a fake that records calls. Live write tests target the named test
//! session `c9-input-test` only, never the default session.
//!
//! With no sender installed the composer is read-only ("Read-only: input is off"), like the Swift app.

use crate::{style, App, Message};
use fb_ui::icons::{icon, Icon, SIZE_DEFAULT, SIZE_INLINE};
use fb_ui::theme::*;
use iced::keyboard::{key::Named, Key};
use iced::widget::text_editor::{self, Action, Binding, Content};
use iced::widget::{button, column, container, row, text, text_editor as text_editor_fn, Space};
use iced::{Alignment, Background, Border, Element, Length, Task};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The editor grows up to this many lines, then scrolls.
pub const MAX_LINES: usize = 8;
const LINE_H: f32 = READING.size * READING.line;
const MIN_H: f32 = LINE_H + 8.0;
const MAX_H: f32 = LINE_H * MAX_LINES as f32 + 8.0;
/// Width cap of the card, same as the conversation column.
pub const CARD_MAX_W: f32 = 780.0;

/// Delivers a composer message to a pane. `Err` carries a short reason for the owner.
///
/// Implementations may block (the live one does a socket call), so `update` calls them off the UI thread.
pub trait MessageSender: Send + Sync {
    fn send(&self, pane_id: &str, text: &str) -> Result<(), String>;
}

/// Sends text and Enter to a herdr pane. MUTATING: never used in tests; live write tests target the
/// `c9-input-test` session only.
#[cfg(unix)]
pub struct LiveSender {
    client: herdr_core::client::HerdrClient<herdr_core::transport::UnixConnector>,
}

#[cfg(unix)]
impl LiveSender {
    pub fn new(session: &herdr_core::HerdrSession) -> LiveSender {
        LiveSender { client: herdr_core::client::HerdrClient::new(session) }
    }
}

#[cfg(unix)]
impl MessageSender for LiveSender {
    fn send(&self, pane_id: &str, text: &str) -> Result<(), String> {
        self.client
            .raw_request("pane.send_input", serde_json::json!({"pane_id": pane_id, "text": text, "keys": ["Enter"]}))
            .map(|_| ())
            .map_err(|e| e.to_string())
    }
}

#[derive(Default)]
pub struct ComposerState {
    pub content: Content,
    /// `None`: read-only.
    pub sender: Option<Arc<dyn MessageSender>>,
    /// Shown under the editor after a failed send; cleared on the next edit.
    pub error: Option<String>,
    /// Overrides the git lookup (tests and snapshots).
    pub branch_override: Option<String>,
    /// A send is on its way (blocks double sends of the same Enter).
    pub sending: bool,
    /// The pane the editor currently belongs to.
    pub pane: Option<String>,
    /// Unsent text of the panes that are not shown, by pane id. One draft per pane, like the Swift app.
    pub drafts: HashMap<String, String>,
}

impl ComposerState {
    pub fn text(&self) -> String {
        self.content.text().trim_end_matches('\n').to_string()
    }
    pub fn set_text(&mut self, s: &str) {
        self.content = Content::with_text(s);
        self.content.perform(Action::Move(text_editor::Motion::DocumentEnd));
    }
    /// Switches the editor to `pane`: the text on screen is kept as the old pane's draft, the new pane's draft
    /// (if any) comes back. Does nothing when the pane did not change.
    pub fn switch_pane(&mut self, pane: Option<&str>) {
        if self.pane.as_deref() == pane {
            return;
        }
        if let Some(old) = self.pane.take() {
            let text = self.text();
            if text.is_empty() {
                self.drafts.remove(&old);
            } else {
                self.drafts.insert(old, text);
            }
        }
        let draft = pane.and_then(|p| self.drafts.remove(p)).unwrap_or_default();
        self.error = None;
        if draft.is_empty() {
            self.content = Content::new();
        } else {
            self.set_text(&draft);
        }
        self.pane = pane.map(str::to_string);
    }

    pub fn can_send(&self) -> bool {
        self.sender.is_some() && !self.text().trim().is_empty()
    }
}

#[derive(Clone)]
pub enum ComposerMsg {
    Edit(Action),
    Submit,
    /// Result of a send. `text` is given back to an empty box on failure.
    Sent { pane: String, text: String, error: Option<String> },
    /// Buttons without a function yet (attach, dictate).
    Noop,
}

impl std::fmt::Debug for ComposerMsg {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ComposerMsg::Edit(_) => write!(f, "Edit"),
            ComposerMsg::Submit => write!(f, "Submit"),
            ComposerMsg::Sent { error, .. } => write!(f, "Sent({})", error.is_some()),
            ComposerMsg::Noop => write!(f, "Noop"),
        }
    }
}

pub fn update(app: &mut App, msg: ComposerMsg) -> Task<Message> {
    match msg {
        ComposerMsg::Edit(action) => {
            if app.state.composer.sender.is_none() && action.is_edit() {
                return Task::none();
            }
            if action.is_edit() {
                app.state.composer.error = None;
            }
            app.state.composer.content.perform(action);
            Task::none()
        }
        ComposerMsg::Submit => {
            let Some(sender) = app.state.composer.sender.clone() else { return Task::none() };
            let Some(pane) = app.state.selected_pane().map(|p| p.id.clone()) else { return Task::none() };
            let text = app.state.composer.text();
            let trimmed = text.trim().to_string();
            if trimmed.is_empty() {
                return Task::none();
            }
            app.state.composer.content = Content::new();
            app.state.composer.error = None;
            let (tx, rx) = iced::futures::channel::oneshot::channel();
            let sent = trimmed.clone();
            let pane_id = pane.clone();
            std::thread::spawn(move || {
                let _ = tx.send(sender.send(&pane, &sent).err());
            });
            Task::perform(
                async move { rx.await.unwrap_or_else(|_| Some("send thread stopped".to_string())) },
                move |error| Message::Composer(ComposerMsg::Sent { pane: pane_id.clone(), text: trimmed.clone(), error }),
            )
        }
        ComposerMsg::Sent { pane, text, error } => {
            if let Some(e) = error {
                let c = &mut app.state.composer;
                if c.pane.as_deref() == Some(pane.as_str()) {
                    // Give the text back unless the owner already typed something new.
                    if c.text().is_empty() {
                        c.set_text(&text);
                    }
                    c.error = Some(format!("Not sent: {e}. Press Enter to try again."));
                } else {
                    // The owner moved to another pane: the text goes back to the draft of the pane it was for.
                    c.drafts.entry(pane).or_insert(text);
                }
            }
            Task::none()
        }
        ComposerMsg::Noop => Task::none(),
    }
}

fn key_binding(kp: text_editor::KeyPress) -> Option<Binding<Message>> {
    if matches!(kp.key.as_ref(), Key::Named(Named::Enter)) && matches!(kp.status, text_editor::Status::Focused { .. }) {
        return if kp.modifiers.shift() { Some(Binding::Enter) } else { Some(Binding::Custom(Message::Composer(ComposerMsg::Submit))) };
    }
    Binding::from_key_press(kp)
}

pub fn view(app: &App) -> Element<'_, Message> {
    let t = app.tokens();
    let st = &app.state.composer;
    let read_only = st.sender.is_none();
    let agent = app.state.selected_pane().and_then(|p| p.agent.as_ref()).map(|a| a.name.clone()).unwrap_or_else(|| "agent".into());
    let placeholder = if read_only { "Read-only: input is off".to_string() } else { format!("Reply to {agent}") };

    let lines = st.content.line_count().clamp(1, MAX_LINES);
    let editor = text_editor_fn(&st.content)
        .placeholder(placeholder)
        .on_action(|a| Message::Composer(ComposerMsg::Edit(a)))
        .key_binding(key_binding)
        .font(READING.font())
        .size(READING.size)
        .line_height(READING.line_height())
        .padding([4, 0])
        .min_height(MIN_H)
        .max_height(MAX_H)
        .height(Length::Fixed((LINE_H * lines as f32 + 8.0).min(MAX_H)))
        .style(move |_, _| text_editor::Style {
            background: Background::Color(iced::Color::TRANSPARENT),
            border: Border::default(),
            placeholder: t.label_3,
            value: t.label,
            selection: iced::Color { a: 0.28, ..t.accent },
        });

    let can_send = st.can_send();
    // The svg renderer drops icon alpha, so translucent icon colors are blended with the surface by hand.
    let card_bg = if t.mode.is_dark() { rgba(48, 48, 52, 1.0) } else { rgba(255, 255, 255, 1.0) };
    let send_icon = if can_send { t.on_accent } else { over(t.label_3, over(t.fill_2, card_bg)) };
    let send_btn = button(container(icon(Icon::ArrowUp, SIZE_DEFAULT, send_icon)).center(Length::Fixed(28.0)))
        .padding(0)
        .on_press_maybe(can_send.then_some(Message::Composer(ComposerMsg::Submit)))
        .style(move |_, status| {
            let bg = if can_send {
                match status {
                    button::Status::Hovered | button::Status::Pressed => iced::Color { a: 0.88, ..t.accent },
                    _ => t.accent,
                }
            } else {
                t.fill_2
            };
            button::Style { background: Some(Background::Color(bg)), border: Border { radius: 14.0.into(), ..Default::default() }, ..Default::default() }
        });

    let ghost = move |ic: Icon, size: f32| {
        button(container(icon(ic, size, over(t.label_2, card_bg))).center(Length::Fixed(28.0)))
            .padding(0)
            .on_press_maybe((!read_only).then_some(Message::Composer(ComposerMsg::Noop)))
            .style(move |_, status| button::Style {
                background: matches!(status, button::Status::Hovered | button::Status::Pressed).then(|| Background::Color(t.fill_2)),
                border: Border { radius: 14.0.into(), ..Default::default() },
                ..Default::default()
            })
    };

    let mut controls = row![ghost(Icon::Plus, SIZE_DEFAULT + 2.0)].spacing(SP_8).align_y(Alignment::Center);
    if let Some(b) = branch_for(app) {
        controls = controls.push(
            row![icon(Icon::GitBranch, SIZE_INLINE, over(t.label_2, card_bg)), CAPTION.text(b).color(t.label_2).wrapping(text::Wrapping::None)]
                .spacing(4)
                .align_y(Alignment::Center),
        );
    }
    controls = controls.push(Space::new().width(Length::Fill)).push(ghost(Icon::Mic, SIZE_DEFAULT)).push(send_btn);

    let mut body = column![editor].spacing(SP_4);
    if let Some(e) = &st.error {
        body = body.push(CAPTION.text(e.clone()).color(t.blocked));
    }
    body = body.push(controls);

    let card = container(body.padding([12, 16])).width(Length::Fill).max_width(CARD_MAX_W).style(style::float_e2(t, R_COMPOSER));
    container(card).padding([SP_8, SP_24]).width(Length::Fill).align_x(Alignment::Center).into()
}

// ---------------------------------------------------------------- branch line

fn branch_for(app: &App) -> Option<String> {
    if let Some(b) = &app.state.composer.branch_override {
        return Some(b.clone());
    }
    let cwd = app.state.selected_pane().map(|p| p.cwd.clone())?;
    git_branch(&cwd)
}

type BranchCache = Mutex<HashMap<String, (Instant, Option<String>)>>;
fn cache() -> &'static BranchCache {
    static C: std::sync::OnceLock<BranchCache> = std::sync::OnceLock::new();
    C.get_or_init(Default::default)
}

/// Current git branch of the repo containing `cwd`. Read-only: reads `.git/HEAD`, never runs `git`.
/// Cached per cwd for 10 s (the view calls this on every frame). `None` outside a repo or on a detached HEAD.
pub fn git_branch(cwd: &str) -> Option<String> {
    if let Some((at, v)) = cache().lock().ok()?.get(cwd) {
        if at.elapsed() < Duration::from_secs(10) {
            return v.clone();
        }
    }
    let v = read_branch(cwd);
    if let Ok(mut c) = cache().lock() {
        c.insert(cwd.to_string(), (Instant::now(), v.clone()));
    }
    v
}

fn read_branch(cwd: &str) -> Option<String> {
    let mut dir = if let Some(rest) = cwd.strip_prefix('~') {
        std::path::PathBuf::from(std::env::var_os("HOME")?).join(rest.trim_start_matches('/'))
    } else {
        std::path::PathBuf::from(cwd)
    };
    loop {
        let git = dir.join(".git");
        if git.is_dir() {
            return parse_head(&std::fs::read_to_string(git.join("HEAD")).ok()?);
        }
        if git.is_file() {
            // Worktree: `gitdir: <path>`.
            let s = std::fs::read_to_string(&git).ok()?;
            let p = s.trim().strip_prefix("gitdir:")?.trim();
            let p = if std::path::Path::new(p).is_absolute() { std::path::PathBuf::from(p) } else { dir.join(p) };
            return parse_head(&std::fs::read_to_string(p.join("HEAD")).ok()?);
        }
        if !dir.pop() {
            return None;
        }
    }
}

pub fn parse_head(s: &str) -> Option<String> {
    s.trim().strip_prefix("ref: refs/heads/").map(str::to_string).filter(|b| !b.is_empty())
}

/// Installs the live sender for `session`. Only called from the live path in `main.rs`.
#[cfg(unix)]
pub fn install_live(app: &mut App, session: &herdr_core::HerdrSession) {
    app.state.composer.sender = Some(Arc::new(LiveSender::new(session)));
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn head_parsing() {
        assert_eq!(parse_head("ref: refs/heads/feature/x\n").as_deref(), Some("feature/x"));
        assert_eq!(parse_head("3f2a9c0d1e\n"), None);
    }
}
