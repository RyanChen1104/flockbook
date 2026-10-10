//! The app model: blocks, the window, scroll state, and the view.
//!
//! Rule inherited from rmdv: the window is rebuilt only in `update()`. `view()`
//! reads `VirtWindow` and never mutates it.

use crate::chat::{self, Block, Kind, Message};
use crate::keyed_body::{KeyedBody, MeasureSink, RowKey};
use crate::virt::{VirtWindow, BLOCK_GAP_PX};
use iced::widget::{column, container, scrollable, text, Column, Space};
use iced::{font, Element, Font, Length, Pixels};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

pub type Renderer = iced::Renderer;

/// Beyond this many px from the bottom the view is no longer "pinned".
const PIN_SLACK_PX: f32 = 2.0;
/// Estimate vs measured deltas smaller than this are ignored.
const MEASURE_EPS_PX: f32 = 0.5;

#[derive(Clone, Debug)]
pub enum Msg {
    /// The scrollable reported its state.
    Scrolled {
        offset: f32,
        viewport_h: f32,
        content_h: f32,
    },
    /// Laid-out heights of block rows, drained from the measure sink.
    Measured(Vec<(RowKey, f32)>),
    /// A new message arrived at the end.
    Append(Message),
}

/// How the body column is built.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Windowed, `KeyedBody` in reorder mode (the default).
    Windowed,
    /// Windowed, `KeyedBody` in fresh mode (drops child trees on key change).
    WindowedFresh,
    /// No virtualisation: every block is a widget, plain column.
    Baseline,
}

#[derive(Default, Clone, Debug)]
pub struct Stats {
    /// Window rebuilds that changed the rendered range.
    pub rebuilds: u64,
    /// Blocks whose measured height differed from the estimate.
    pub corrections: u64,
    pub measured: u64,
    /// Sum of |measured - estimate| over all measured blocks.
    pub abs_err_px: f64,
}

pub struct Model {
    pub mode: Mode,
    pub blocks: Vec<Block>,
    index: HashMap<u64, usize>,
    pub win: VirtWindow,
    pub offset: f32,
    pub viewport_h: f32,
    pub pinned: bool,
    pub stats: Stats,
    pub scroll_id: iced_test::core::widget::Id,
    sink: MeasureSink,
    /// Monotonic counter, used as the `KeyedBody` generation in fresh mode.
    generation: u64,
}

/// A command `update()` hands back to the runtime: scroll to this offset.
pub type ScrollCmd = Option<f32>;

impl Model {
    pub fn new(messages: &[Message], mode: Mode, viewport_h: f32) -> Self {
        let min_blocks = match mode {
            Mode::Baseline => usize::MAX,
            _ => crate::virt::VIRT_MIN_BLOCKS,
        };
        let mut m = Self {
            mode,
            blocks: Vec::new(),
            index: HashMap::new(),
            win: VirtWindow::with_min_blocks(min_blocks),
            offset: 0.0,
            viewport_h,
            pinned: false,
            stats: Stats::default(),
            scroll_id: iced_test::core::widget::Id::new("chat"),
            sink: Rc::new(RefCell::new(Vec::new())),
            generation: 0,
        };
        for msg in messages {
            m.push_message(msg);
        }
        m.win.rebuild_at(0.0, viewport_h);
        m
    }

    fn push_message(&mut self, msg: &Message) {
        for b in chat::split_message(msg) {
            self.index.insert(b.key, self.blocks.len());
            self.win.push(b.estimate_height());
            self.blocks.push(b);
        }
    }

    pub fn drain_measure(&self) -> Vec<(RowKey, f32)> {
        std::mem::take(&mut *self.sink.borrow_mut())
    }

    fn rewindow(&mut self) {
        if self.win.rebuild_at(self.offset, self.viewport_h) {
            self.stats.rebuilds += 1;
            self.generation += 1;
        }
    }

    /// Would `update(msg)` change nothing? Pure; lets the runtime skip a
    /// rebuild when events and measurements only confirm the current state.
    pub fn is_noop(&self, msg: &Msg) -> bool {
        match msg {
            Msg::Scrolled { offset, viewport_h, content_h } => {
                (offset - self.offset).abs() < 0.01
                    && (viewport_h - self.viewport_h).abs() < 0.01
                    && (offset + viewport_h >= content_h - PIN_SLACK_PX) == self.pinned
                    && !self.win.needs_rebuild(*offset)
            }
            Msg::Measured(rows) => rows.iter().all(|(key, height)| {
                let RowKey::Block(k) = key else { return true };
                match self.index.get(k) {
                    Some(&i) => (height - self.win.block_height(i)).abs() <= MEASURE_EPS_PX,
                    None => true,
                }
            }),
            Msg::Append(_) => false,
        }
    }

    pub fn update(&mut self, msg: Msg) -> ScrollCmd {
        match msg {
            Msg::Scrolled {
                offset,
                viewport_h,
                content_h,
            } => {
                self.offset = offset;
                self.viewport_h = viewport_h;
                self.pinned = offset + viewport_h >= content_h - PIN_SLACK_PX;
                if self.win.needs_rebuild(offset) {
                    self.rewindow();
                }
                None
            }
            Msg::Measured(rows) => self.apply_measured(rows),
            Msg::Append(message) => {
                self.push_message(&message);
                if self.pinned {
                    self.offset = (self.win.total_height() - self.viewport_h).max(0.0);
                    self.rewindow();
                    Some(self.offset)
                } else {
                    // Same offset: only the bottom spacer grew. The window
                    // may still need to turn active or extend to the new end.
                    if !self.win.active || self.win.range.1 + 1 >= self.win.len() {
                        self.rewindow();
                    }
                    None
                }
            }
        }
    }

    fn apply_measured(&mut self, rows: Vec<(RowKey, f32)>) -> ScrollCmd {
        let mut anchor_shift = 0.0f32;
        let mut changed = false;
        for (key, height) in rows {
            let RowKey::Block(k) = key else { continue };
            let Some(&i) = self.index.get(&k) else { continue };
            let current = self.win.block_height(i);
            self.stats.measured += 1;
            let delta = height - current;
            self.stats.abs_err_px += delta.abs() as f64;
            if delta.abs() <= MEASURE_EPS_PX {
                continue;
            }
            // A block fully above the viewport top pushes the content down:
            // shift the scroll offset by the same amount (scroll anchoring).
            if self.win.block_top(i) + current <= self.offset {
                anchor_shift += delta;
            }
            self.win.apply_height_delta(i, delta);
            self.stats.corrections += 1;
            changed = true;
        }
        if !changed {
            return None;
        }
        if self.pinned {
            self.offset = (self.win.total_height() - self.viewport_h).max(0.0);
            self.rewindow();
            return Some(self.offset);
        }
        if anchor_shift != 0.0 {
            self.offset = (self.offset + anchor_shift).max(0.0);
            self.rewindow();
            return Some(self.offset);
        }
        None
    }

    pub fn view(&self) -> Element<'_, Msg, iced::Theme, Renderer> {
        let windowed = self.mode != Mode::Baseline;
        let (start, end) = self.win.range;
        let mut keys = Vec::with_capacity(end - start + 2);
        let mut col: Column<'_, Msg> = Column::new().spacing(BLOCK_GAP_PX).width(Length::Fill);

        if let Some(h) = self.win.top_spacer() {
            keys.push(RowKey::TopSpacer);
            col = col.push(Space::new().height(Length::Fixed(h)));
        }
        for b in &self.blocks[start..end] {
            keys.push(RowKey::Block(b.key));
            col = col.push(block_view(b));
        }
        if let Some(h) = self.win.bottom_spacer() {
            keys.push(RowKey::BottomSpacer);
            col = col.push(Space::new().height(Length::Fixed(h)));
        }

        let body: Element<'_, Msg> = match self.mode {
            Mode::Baseline => col.into(),
            Mode::Windowed => KeyedBody::new(keys, col)
                .measure_into(self.sink.clone())
                .into(),
            Mode::WindowedFresh => KeyedBody::new_fresh(keys, col, (0, self.generation))
                .measure_into(self.sink.clone())
                .into(),
        };
        let _ = windowed;

        scrollable(body)
            .id(self.scroll_id.clone())
            .width(Length::Fill)
            .height(Length::Fill)
            .on_scroll(|v| Msg::Scrolled {
                offset: v.absolute_offset().y,
                viewport_h: v.bounds().height,
                content_h: v.content_bounds().height,
            })
            .into()
    }
}

fn block_view(b: &Block) -> Element<'_, Msg> {
    let line = |px: f32| text::LineHeight::Absolute(Pixels(px));
    let body: Element<'_, Msg> = match b.kind {
        Kind::Prose => text(b.text.as_str())
            .size(chat::PROSE_SIZE)
            .line_height(line(chat::PROSE_LINE_PX))
            .into(),
        Kind::Code => container(
            text(b.text.as_str())
                .font(Font {
                    family: font::Family::Monospace,
                    ..Font::DEFAULT
                })
                .size(chat::CODE_SIZE)
                .line_height(line(chat::CODE_LINE_PX))
                .wrapping(text::Wrapping::None),
        )
        .padding(chat::CODE_PAD_PX)
        .width(Length::Fill)
        .style(container::rounded_box)
        .into(),
    };
    let inner: Element<'_, Msg> = if b.first {
        column![
            text(b.role.label())
                .size(chat::HEADER_SIZE)
                .line_height(line(chat::HEADER_LINE_PX)),
            body
        ]
        .spacing(chat::HEADER_GAP_PX)
        .into()
    } else {
        body
    };
    container(inner)
        .padding([chat::PAD_Y, chat::PAD_X])
        .width(Length::Fill)
        .into()
}
