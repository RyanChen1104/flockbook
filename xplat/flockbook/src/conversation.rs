//! Conversation view: user bubbles, agent prose, tool chips, code, tables, footers.
//!
//! The list is one `fb_ui::selectable::flow::Flow` widget over a flat list of rows (`Doc`). The window math is
//! `fb_ui::virt::VirtWindow` (estimates, measured heights, full render below 256 rows, anchor to the bottom while
//! pinned). Selection (`SelState`) lives in app state keyed by stable row id plus byte offset, so it survives rows
//! being unmounted. Copy is built from the model. Drag past the top or bottom edge auto-scrolls on a timer
//! subscription and keeps extending the selection.
//!
//! Why no `KeyedBody`: the rows are not child widgets. `Flow` shapes and draws the mounted slice itself (cached per
//! row id), so there is no per-row widget tree to diff when the window slides.

mod build;
mod markdown;

use crate::{App, Message};
use fb_ui::icons::Icon;
use fb_ui::selectable::flow::{Doc, Flow, FlowEvent, FlowKey, MeasureSink, Probe, SelState, PAD_TOP};
use fb_ui::theme::*;
use iced::widget::{column, container, Space};
use iced::{Alignment, Element, Length, Size, Subscription, Task};
use std::cell::RefCell;
use std::collections::HashSet;
use std::rc::Rc;
use std::time::Duration;

/// Widest the reading column gets, in points.
pub const COLUMN_MAX: f32 = 760.0;
/// Auto-scroll timer period while a drag is past an edge.
pub const AUTOSCROLL_MS: u64 = 16;

pub struct ConversationState {
    pub doc: Doc,
    pub sel: SelState,
    /// Scroll offset in document coordinates (px of the viewport top). Ignored while `pinned`.
    pub offset: f32,
    /// Following the bottom: new rows stay in view.
    pub pinned: bool,
    /// Last known size of the list widget.
    pub viewport: Size,
    /// The pane the rows belong to. A change resets everything.
    pub pane: Option<String>,
    /// Chip ids that are expanded.
    pub expanded: HashSet<String>,
    cache: build::RowCache,
    /// Auto-scroll speed in px per tick while a drag is beyond an edge.
    pub edge: Option<f32>,
    pub sink: MeasureSink,
    pub more_earlier: bool,
    pub loading_earlier: bool,
    /// Number of "load earlier" reads started. A result with an older number is stale.
    pub earlier_seq: u64,
    /// How many times the rows were rebuilt (tests: an idle tick must not rebuild).
    pub rebuilds: u64,
    /// Last text copied (also written to the clipboard).
    pub last_copied: Option<String>,
    /// Last link the user clicked (handed to `App::opener`).
    pub last_link: Option<String>,
    /// Layout facts for tests.
    pub probe: Option<Rc<RefCell<Probe>>>,
}

impl Default for ConversationState {
    fn default() -> Self {
        ConversationState {
            doc: Doc::default(),
            sel: SelState::default(),
            offset: 0.0,
            pinned: true,
            viewport: Size::new(1000.0, 640.0),
            pane: None,
            expanded: HashSet::new(),
            cache: Default::default(),
            edge: None,
            sink: Default::default(),
            more_earlier: false,
            loading_earlier: false,
            earlier_seq: 0,
            rebuilds: 0,
            last_copied: None,
            last_link: None,
            probe: None,
        }
    }
}

#[derive(Debug, Clone)]
pub enum ConversationMsg {
    Flow(FlowEvent),
    /// Timer tick of the drag auto-scroll.
    AutoScroll,
    /// A "load earlier" read finished. `more`: older content remains (`None`: the worker died).
    EarlierLoaded { pane: String, ticket: u64, more: Option<bool> },
}

/// Lucide icon for a herdr tool chip symbol (the symbols are SF Symbol names kept from the Swift model).
pub fn icon_for_symbol(symbol: &str) -> Icon {
    match symbol {
        "terminal" => Icon::SquareTerminal,
        "pencil" => Icon::Pencil,
        "doc.text" => Icon::FileText,
        "globe" => Icon::Globe,
        "magnifyingglass" => Icon::Search,
        "square.and.pencil" => Icon::SquarePen,
        "person.2" => Icon::Layers,
        "checklist" => Icon::Check,
        "wrench" => Icon::Hammer,
        _ => Icon::Sparkles,
    }
}

// ---------------------------------------------------------------------------------------------------- scrolling

fn max_offset(cs: &ConversationState) -> f32 {
    let total = {
        let s = cs.sink.borrow().total;
        if s > 0.0 {
            s
        } else {
            cs.doc.total_height()
        }
    };
    (total - cs.viewport.height).max(0.0)
}

/// The offset the widget really shows: while pinned that is the bottom, which only the widget knows exactly.
fn current_offset(cs: &ConversationState) -> f32 {
    if cs.pinned {
        let eff = cs.sink.borrow().eff;
        if eff > 0.0 {
            return eff;
        }
        return max_offset(cs);
    }
    cs.offset
}

/// Re-windows the mounted rows around the offset (or the end while pinned).
fn rewindow(cs: &mut ConversationState) {
    let off = if cs.pinned { f32::MAX } else { (cs.offset - PAD_TOP).max(0.0) };
    cs.doc.window.rebuild_at(off, cs.viewport.height);
}

fn set_offset(cs: &mut ConversationState, off: f32) {
    let max = max_offset(cs);
    cs.offset = off.clamp(0.0, max);
    cs.pinned = cs.offset >= max - 2.0;
    rewindow(cs);
}

fn scroll_by(cs: &mut ConversationState, dy: f32) {
    let base = current_offset(cs);
    set_offset(cs, base + dy);
}

/// Applies the heights the widget measured. Rows above the viewport that change size move the offset, so the
/// content under the reader's eyes stays put.
fn drain(cs: &mut ConversationState) {
    let measures = std::mem::take(&mut cs.sink.borrow_mut().measures);
    if measures.is_empty() {
        return;
    }
    let first_visible = cs.doc.window.index_at((cs.offset - PAD_TOP).max(0.0)).unwrap_or(0);
    for m in measures {
        if let Some((idx, delta)) = cs.doc.apply_measure(m) {
            if !cs.pinned && idx < first_visible {
                cs.offset += delta;
            }
        }
    }
    rewindow(cs);
}

// ---------------------------------------------------------------------------------------------------- update

pub fn update(app: &mut App, msg: ConversationMsg) -> Task<Message> {
    match msg {
        ConversationMsg::AutoScroll => {
            let cs = &mut app.state.conversation;
            drain(cs);
            if let Some(v) = cs.edge {
                scroll_by(cs, v);
            }
            Task::none()
        }
        ConversationMsg::Flow(ev) => flow_event(app, ev),
        ConversationMsg::EarlierLoaded { pane, ticket, more } => {
            earlier_loaded(app, pane, ticket, more);
            Task::none()
        }
    }
}

fn flow_event(app: &mut App, ev: FlowEvent) -> Task<Message> {
    let mut task = Task::none();
    let (mut scrolled, mut resync, mut load) = (false, false, false);
    let mut link: Option<String> = None;
    {
        let cs = &mut app.state.conversation;
        match ev {
            FlowEvent::Press { at, point, shift } => cs.sel.press(&cs.doc, at, point, shift),
            FlowEvent::Drag { at, edge } => {
                cs.sel.drag_to(&cs.doc, at);
                cs.edge = edge;
            }
            FlowEvent::Release => {
                cs.sel.release();
                cs.edge = None;
            }
            FlowEvent::Blur => {
                cs.sel.blur();
                cs.edge = None;
            }
            FlowEvent::Link(url) => link = Some(url),
            FlowEvent::Chip(id) => {
                if !cs.expanded.remove(&id) {
                    cs.expanded.insert(id);
                }
                resync = true;
            }
            FlowEvent::LoadEarlier => load = true,
            FlowEvent::Wheel(dy) => {
                drain(cs);
                scroll_by(cs, dy);
                scrolled = true;
            }
            FlowEvent::ScrollTo(off) => {
                set_offset(cs, off);
                scrolled = true;
            }
            FlowEvent::Key(k) => match k {
                FlowKey::Copy => {
                    if let Some(text) = cs.sel.text(&cs.doc) {
                        cs.last_copied = Some(text.clone());
                        task = iced::clipboard::write(text);
                    }
                }
                FlowKey::SelectAll => cs.sel.select_all(&cs.doc),
                FlowKey::Escape => cs.sel.clear(),
                FlowKey::PageUp => {
                    scroll_by(cs, -cs.viewport.height * 0.9);
                    scrolled = true;
                }
                FlowKey::PageDown => {
                    scroll_by(cs, cs.viewport.height * 0.9);
                    scrolled = true;
                }
                FlowKey::LineUp => {
                    scroll_by(cs, -48.0);
                    scrolled = true;
                }
                FlowKey::LineDown => {
                    scroll_by(cs, 48.0);
                    scrolled = true;
                }
                FlowKey::Home => {
                    set_offset(cs, 0.0);
                    scrolled = true;
                }
                FlowKey::End => {
                    let max = max_offset(cs);
                    set_offset(cs, max);
                    scrolled = true;
                }
            },
            FlowEvent::Settle => drain(cs),
            FlowEvent::Viewport(size) => {
                cs.viewport = size;
                rewindow(cs);
            }
        }
        // Scrolled to the top of what is loaded: read an older part of the log.
        if scrolled && cs.offset <= 40.0 && cs.more_earlier && !cs.loading_earlier && !cs.doc.rows.is_empty() {
            load = true;
        }
    }
    if let Some(url) = link {
        open_link(app, &url);
    }
    if resync {
        sync_markdown(app);
    }
    if load {
        task = Task::batch([task, load_earlier(app)]);
    }
    let cs = &mut app.state.conversation;
    cs.sel.validate(&cs.doc);
    task
}

fn open_link(app: &mut App, url: &str) {
    app.state.conversation.last_link = Some(url.to_string());
    if crate::links::allowed(url) {
        app.opener.open(url);
    }
}

/// Reads an older part of the pane's log. A source with a job runs it on a blocking thread; the result comes back
/// as `EarlierLoaded`, which is dropped when the pane changed or a newer load started in the meantime. A source
/// without a job reads on the UI thread. The reader's place stays: rows added above move the offset by their height.
fn load_earlier(app: &mut App) -> Task<Message> {
    let Some(pane) = app.state.selected_pane().cloned() else { return Task::none() };
    if app.state.conversation.loading_earlier {
        return Task::none();
    }
    let cs = &mut app.state.conversation;
    cs.loading_earlier = true;
    cs.earlier_seq += 1;
    let ticket = cs.earlier_seq;
    match app.source.load_earlier_job(&pane) {
        Some(job) => {
            sync_markdown(app); // shows "Loading earlier..."
            let pane_id = pane.id.clone();
            Task::perform(
                async move {
                    let (tx, rx) = iced::futures::channel::oneshot::channel();
                    std::thread::spawn(move || {
                        let _ = tx.send(job());
                    });
                    rx.await.ok()
                },
                move |more| Message::Conversation(ConversationMsg::EarlierLoaded { pane: pane_id.clone(), ticket, more }),
            )
        }
        None => {
            let more = app.source.load_earlier(&pane);
            earlier_loaded(app, pane.id, ticket, Some(more));
            Task::none()
        }
    }
}

fn earlier_loaded(app: &mut App, pane: String, ticket: u64, more: Option<bool>) {
    let cs = &mut app.state.conversation;
    if cs.pane.as_deref() != Some(pane.as_str()) || cs.earlier_seq != ticket {
        return; // stale: another pane is shown, or a newer load owns the flags
    }
    cs.loading_earlier = false;
    if let Some(m) = more {
        cs.more_earlier = m;
    }
    app.state.invalidate(&pane);
    app.refresh();
    sync_markdown(app);
}

// ---------------------------------------------------------------------------------------------------- sync

/// Rebuilds the rows of the selected pane from `state.conversations`. Call after `App::refresh`. Items that did not
/// change keep their rows (cached per item), so a poll tick costs hashing, not parsing.
pub fn sync_markdown(app: &mut App) {
    let Some(pane) = app.state.selected_pane().cloned() else { return };
    let can_more = app.source.can_load_earlier(&pane);
    let st = &mut app.state;
    let cs = &mut st.conversation;
    if cs.pane.as_deref() != Some(pane.id.as_str()) {
        *cs = ConversationState { probe: cs.probe.take(), viewport: cs.viewport, sink: cs.sink.clone(), pane: Some(pane.id.clone()), more_earlier: can_more, earlier_seq: cs.earlier_seq + 1, rebuilds: cs.rebuilds, ..Default::default() };
        cs.sink.borrow_mut().measures.clear();
    }
    let items: &[herdr_core::ConversationItem] = st.conversations.get(&pane.id).map(|v| v.as_slice()).unwrap_or(&[]);
    cs.rebuilds += 1;
    let rows = build::build_rows(items, &cs.expanded, &mut cs.cache, cs.more_earlier, cs.loading_earlier);
    match cs.doc.set_rows(rows) {
        fb_ui::selectable::flow::Change::Prepended(k) => {
            if !cs.pinned {
                cs.offset += cs.doc.window.prefix_at(k);
            }
        }
        _ => {}
    }
    cs.sel.validate(&cs.doc);
    rewindow(cs);
}

pub fn subscription(app: &App) -> Subscription<Message> {
    if app.state.conversation.edge.is_some() {
        iced::time::every(Duration::from_millis(AUTOSCROLL_MS)).map(|_| Message::Conversation(ConversationMsg::AutoScroll))
    } else {
        Subscription::none()
    }
}

// ---------------------------------------------------------------------------------------------------- view

pub fn view(app: &App) -> Element<'_, Message> {
    let t = app.tokens();
    let cs = &app.state.conversation;
    if app.state.conversation_items().is_empty() {
        let agent = app.state.selected_pane().and_then(|p| p.agent.as_ref()).map(|a| a.name.clone()).unwrap_or_else(|| "The agent".into());
        let detail = format!("{agent} has not written anything yet.");
        return container(column![TITLE_3.text("No messages yet").color(t.label_2), Space::new().height(SP_4), BODY.text(detail).color(t.label_3)].align_x(Alignment::Center))
            .center(Length::Fill)
            .into();
    }
    let mut flow = Flow::new(&cs.doc, t, |e| Message::Conversation(ConversationMsg::Flow(e)))
        .col_max(COLUMN_MAX)
        .offset(cs.offset, cs.pinned)
        .selection(cs.sel.sel)
        .focused(cs.sel.focused)
        .dragging(cs.sel.dragging())
        .viewport(cs.viewport)
        .measure_into(cs.sink.clone());
    if let Some(p) = &cs.probe {
        flow = flow.probe(p.clone());
    }
    Element::from(flow)
}
