//! `SelectableDoc`: one widget that lays out an ordered list of text blocks and
//! owns a single selection across all of them.
//!
//! Why a custom widget: `iced_selection` selects inside one text widget only.
//! Here one controller sees every block, so a drag can start in one block and
//! end in another. Text shaping, hit testing and highlight geometry come from
//! the renderer's own `Paragraph` (cosmic-text under iced), so wrapping, CJK
//! and inline code behave as they do in normal iced text. The structure of the
//! per-glyph highlight code follows `iced_selection` (MIT).

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use iced::advanced::clipboard::{self, Clipboard};
use iced::advanced::graphics::text::{cosmic_text, Paragraph};
use iced::advanced::layout::{self, Layout};
use iced::advanced::renderer::{self, Renderer as _};
use iced::advanced::text::paragraph::Paragraph as _;
use iced::advanced::text::{self, Renderer as _, Shaping, Span, Wrapping};
use iced::advanced::widget::tree::{self, Tree};
use iced::advanced::widget::Widget;
use iced::advanced::{mouse, Shell};
use iced::keyboard;
use iced::widget::markdown;
use iced::{
    alignment, border, Border, Element, Event, Font, Length, Pixels,
    Point, Rectangle, Size, Theme,
};

use super::model::{clamp_boundary, Block, Content, Kind, Pos, Selection};

const SIDE: f32 = 16.0;
const CODE_PAD: f32 = 10.0;
const BASE_SIZE: f32 = 16.0;

type Callback<'a, Message, T> = Option<Box<dyn Fn(T) -> Message + 'a>>;

/// A scrollable-friendly document of selectable text blocks.
pub struct SelectableDoc<'a, Message> {
    blocks: &'a [Block],
    style: markdown::Style,
    selection: Option<Selection>,
    on_selection: Callback<'a, Message, Option<Selection>>,
    on_copy: Callback<'a, Message, String>,
}

impl<'a, Message> SelectableDoc<'a, Message> {
    pub fn new(blocks: &'a [Block], style: markdown::Style) -> Self {
        Self {
            blocks,
            style,
            selection: None,
            on_selection: None,
            on_copy: None,
        }
    }

    /// The selection held by the application (controlled input).
    pub fn selection(mut self, selection: Option<Selection>) -> Self {
        self.selection = selection;
        self
    }

    /// Called whenever mouse or keyboard changes the selection.
    pub fn on_selection(
        mut self,
        f: impl Fn(Option<Selection>) -> Message + 'a,
    ) -> Self {
        self.on_selection = Some(Box::new(f));
        self
    }

    /// Called with the plain text when the user copies. The text is also
    /// written to the system clipboard.
    pub fn on_copy(mut self, f: impl Fn(String) -> Message + 'a) -> Self {
        self.on_copy = Some(Box::new(f));
        self
    }
}

/// Laid out block: shaped paragraph plus geometry relative to the widget origin.
struct Item {
    paragraph: Paragraph,
    /// Full-width row, used for hit testing and background.
    rect: Rectangle,
    /// Top-left of the text.
    text_pos: Point,
    /// Byte offset of each logical line start in the block's plain text.
    line_starts: Vec<usize>,
    wraps: bool,
}

/// Shaped paragraphs and positions of every block at one width. Pure data:
/// the widget uses it, and tests use it to find where a character is on screen.
#[derive(Default)]
pub struct Geometry {
    items: Vec<Item>,
    signature: u64,
    /// Size of the whole document.
    pub total: Size,
}

#[derive(Default)]
struct State {
    geom: Geometry,
    /// Selection shown now. Authoritative while the widget is alive.
    selection: Option<Selection>,
    /// Last selection prop value seen, to detect outside changes.
    prop_seen: Option<Selection>,
    drag_anchor: Option<Pos>,
    hovered: bool,
}

impl Geometry {
    /// Shapes all blocks for the given width.
    pub fn build(blocks: &[Block], style: &markdown::Style, width: f32) -> Self {
        let mut y = 0.0_f32;
        let mut items = Vec::with_capacity(blocks.len());
        for (index, block) in blocks.iter().enumerate() {
            let m = metrics(blocks, index);
            let text_x = SIDE + m.indent + m.pad;
            let avail = (width - text_x - SIDE - m.pad).max(40.0);
            let (paragraph, wraps) = shape(block, style, &m, avail);
            let text_h = paragraph.min_bounds().height;
            let top = if index == 0 { m.gap_before } else { y + m.gap_before };
            let height = text_h + 2.0 * m.pad;
            items.push(Item {
                paragraph,
                rect: Rectangle::new(Point::new(0.0, top), Size::new(width, height)),
                text_pos: Point::new(text_x, top + m.pad),
                line_starts: line_starts(&block.plain),
                wraps,
            });
            y = top + height;
        }
        Self {
            items,
            signature: block_signature(blocks, width),
            total: Size::new(width, y + 16.0),
        }
    }

    /// Widget-relative point at the vertical middle of the glyph at `offset`
    /// in `block`, if that block has been laid out.
    pub fn point_of(&self, block: usize, offset: usize) -> Option<Point> {
        let item = self.items.get(block)?;
        let (line, idx) = line_and_index(&item.line_starts, offset);
        let cursor = cosmic_text::Cursor::new(line, idx);
        item.paragraph
            .buffer()
            .layout_runs()
            .filter(|run| run.line_i == line)
            .find_map(|run| {
                run.highlight(cursor, cursor).map(|(x, _)| {
                    Point::new(
                        item.text_pos.x + x,
                        item.text_pos.y + run.line_top + run.line_height / 2.0,
                    )
                })
            })
    }

    /// Document position under `point` (widget-relative). Points outside blocks
    /// clamp to the nearest edge, so a drag can leave the widget.
    fn hit(&self, blocks: &[Block], point: Point) -> Option<Pos> {
        // An empty document (or one not laid out yet) has no position to return.
        let first_item = self.items.first()?;
        let last = self.items.len() - 1;
        if point.y < first_item.rect.y {
            return Some(Pos { block: 0, offset: 0 });
        }

        // First block whose bottom edge is below the point.
        let index = self
            .items
            .partition_point(|item| item.rect.y + item.rect.height <= point.y);
        if index > last {
            return Some(Pos {
                block: last,
                offset: blocks[last].plain.len(),
            });
        }

        let item = &self.items[index];
        if point.y < item.rect.y {
            // In the gap above `index`: snap to the nearer block edge.
            let prev = &self.items[index - 1];
            let prev_bottom = prev.rect.y + prev.rect.height;
            return Some(if point.y - prev_bottom < item.rect.y - point.y {
                Pos {
                    block: index - 1,
                    offset: blocks[index - 1].plain.len(),
                }
            } else {
                Pos { block: index, offset: 0 }
            });
        }

        let buffer = item.paragraph.buffer();
        let height = item.paragraph.min_bounds().height;
        let x = point.x - item.text_pos.x;
        let y = (point.y - item.text_pos.y).clamp(0.0, (height - 1.0).max(0.0));
        let offset = buffer
            .hit(x.max(0.0), y)
            .map(|cursor| {
                item.line_starts
                    .get(cursor.line)
                    .copied()
                    .unwrap_or(0)
                    + cursor.index
            })
            .unwrap_or(blocks[index].plain.len());

        Some(Pos {
            block: index,
            offset: clamp_boundary(&blocks[index].plain, offset),
        })
    }

    /// Highlight rectangles (widget-relative) for the selected part of block `index`.
    fn highlight(
        &self,
        blocks: &[Block],
        selection: &Selection,
        index: usize,
    ) -> Vec<Rectangle> {
        let (start, end) = selection.ordered();
        if index < start.block || index > end.block {
            return Vec::new();
        }
        let plain = &blocks[index].plain;
        let item = &self.items[index];
        let from = if index == start.block { start.offset } else { 0 };
        let to = if index == end.block { end.offset } else { plain.len() };
        let (from_line, from_idx) = line_and_index(&item.line_starts, from);
        let (to_line, to_idx) = line_and_index(&item.line_starts, to);

        let mut rects = Vec::new();
        for run in item.paragraph.buffer().layout_runs() {
            if run.line_i < from_line || run.line_i > to_line {
                continue;
            }
            let run_from = if run.line_i == from_line { from_idx } else { 0 };
            let run_to = if run.line_i == to_line {
                to_idx
            } else {
                run.text.len()
            };
            let start = cosmic_text::Cursor::new(run.line_i, run_from);
            let end = cosmic_text::Cursor::new(run.line_i, run_to);

            // An interior blank or fully covered line is shown as a thin stub
            // so the user sees that the newline is selected.
            let span = run.highlight(start, end).or_else(|| {
                (run.line_i < to_line && run.glyphs.is_empty()).then_some((0.0, 4.0))
            });

            if let Some((x, width)) = span {
                if width > 0.0 {
                    rects.push(Rectangle {
                        x: item.text_pos.x + x,
                        y: item.text_pos.y + run.line_top,
                        width,
                        height: run.line_height,
                    });
                }
            }
        }
        rects
    }
}

fn line_and_index(line_starts: &[usize], offset: usize) -> (usize, usize) {
    let line = line_starts
        .partition_point(|&start| start <= offset)
        .saturating_sub(1);
    (line, offset - line_starts[line])
}

fn line_starts(plain: &str) -> Vec<usize> {
    std::iter::once(0)
        .chain(plain.match_indices('\n').map(|(i, _)| i + 1))
        .collect()
}

fn block_signature(blocks: &[Block], width: f32) -> u64 {
    let mut hasher = DefaultHasher::new();
    width.to_bits().hash(&mut hasher);
    for block in blocks {
        block.id.hash(&mut hasher);
        block.plain.hash(&mut hasher);
        std::mem::discriminant(&block.kind).hash(&mut hasher);
    }
    hasher.finish()
}

struct Metrics {
    size: f32,
    gap_before: f32,
    indent: f32,
    pad: f32,
}

fn metrics(blocks: &[Block], index: usize) -> Metrics {
    let prev_is_list = index
        .checked_sub(1)
        .map(|i| matches!(blocks[i].kind, Kind::ListItem { .. }))
        .unwrap_or(false);
    match &blocks[index].kind {
        Kind::Role => Metrics {
            size: 13.0,
            gap_before: if index == 0 { 8.0 } else { 26.0 },
            indent: 0.0,
            pad: 0.0,
        },
        Kind::Heading(level) => Metrics {
            size: match level {
                1 => 28.0,
                2 => 23.0,
                3 => 19.0,
                _ => 17.0,
            },
            gap_before: 12.0,
            indent: 0.0,
            pad: 0.0,
        },
        Kind::Paragraph => Metrics {
            size: BASE_SIZE,
            gap_before: 10.0,
            indent: 0.0,
            pad: 0.0,
        },
        Kind::ListItem { depth, .. } => Metrics {
            size: BASE_SIZE,
            gap_before: if prev_is_list { 4.0 } else { 10.0 },
            indent: 22.0 + 20.0 * (*depth as f32 - 1.0),
            pad: 0.0,
        },
        Kind::Code => Metrics {
            size: 14.0,
            gap_before: 12.0,
            indent: 0.0,
            pad: CODE_PAD,
        },
        Kind::Quote => Metrics {
            size: BASE_SIZE,
            gap_before: 10.0,
            indent: 16.0,
            pad: 0.0,
        },
    }
}

fn shape(
    block: &Block,
    style: &markdown::Style,
    metrics: &Metrics,
    width: f32,
) -> (Paragraph, bool) {
    let spans: Vec<Span<'static, markdown::Uri>> = match &block.content {
        Content::Rich(text) => text.spans(*style).iter().cloned().collect(),
        Content::Plain(text) => {
            let mut span = Span::new(text.clone());
            match block.kind {
                Kind::Code => span = span.font(style.code_block_font),
                Kind::Role => {
                    span = span.font(Font {
                        weight: iced::font::Weight::Bold,
                        ..style.font
                    })
                }
                _ => {}
            }
            vec![span]
        }
    };
    let wraps = !matches!(block.kind, Kind::Code);
    let paragraph = Paragraph::with_spans(text::Text {
        content: spans.as_slice(),
        bounds: Size::new(width, f32::INFINITY),
        size: Pixels(metrics.size),
        line_height: text::LineHeight::default(),
        font: if matches!(block.kind, Kind::Heading(_)) {
            Font {
                weight: iced::font::Weight::Bold,
                ..style.font
            }
        } else {
            style.font
        },
        align_x: text::Alignment::Default,
        align_y: alignment::Vertical::Top,
        shaping: Shaping::Advanced,
        wrapping: if wraps {
            Wrapping::WordOrGlyph
        } else {
            Wrapping::None
        },
    });
    (paragraph, wraps)
}

impl<'a, Message> Widget<Message, Theme, iced::Renderer> for SelectableDoc<'a, Message> {
    fn tag(&self) -> tree::Tag {
        tree::Tag::of::<State>()
    }

    fn state(&self) -> tree::State {
        tree::State::new(State::default())
    }

    fn size(&self) -> Size<Length> {
        Size::new(Length::Fill, Length::Shrink)
    }

    fn layout(
        &mut self,
        tree: &mut Tree,
        _renderer: &iced::Renderer,
        limits: &layout::Limits,
    ) -> layout::Node {
        let state = tree.state.downcast_mut::<State>();
        let width = limits.max().width;

        // Adopt a selection the app changed from outside.
        if self.selection != state.prop_seen {
            state.selection = self.selection;
            state.prop_seen = self.selection;
        }

        let signature = block_signature(self.blocks, width);
        if signature != state.geom.signature
            || state.geom.items.len() != self.blocks.len()
        {
            state.geom = Geometry::build(self.blocks, &self.style, width);
        }

        layout::Node::new(state.geom.total)
    }

    fn update(
        &mut self,
        tree: &mut Tree,
        event: &Event,
        layout: Layout<'_>,
        cursor: mouse::Cursor,
        _renderer: &iced::Renderer,
        clipboard: &mut dyn Clipboard,
        shell: &mut Shell<'_, Message>,
        _viewport: &Rectangle,
    ) {
        let state = tree.state.downcast_mut::<State>();
        let bounds = layout.bounds();
        let origin = bounds.position() - Point::ORIGIN;
        state.hovered = cursor.position_over(bounds).is_some();

        let publish = |shell: &mut Shell<'_, Message>,
                       callback: &Callback<'a, Message, Option<Selection>>,
                       value: Option<Selection>| {
            if let Some(callback) = callback {
                shell.publish(callback(value));
            }
        };

        match event {
            Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Left)) => {
                let Some(position) = cursor.position_over(bounds) else {
                    // A click elsewhere clears the selection.
                    if state.selection.take().is_some() {
                        publish(shell, &self.on_selection, None);
                    }
                    return;
                };
                if let Some(pos) = state.geom.hit(self.blocks, position - origin) {
                    state.drag_anchor = Some(pos);
                    if state.selection.take().is_some() {
                        publish(shell, &self.on_selection, None);
                    }
                    shell.capture_event();
                    shell.request_redraw();
                }
            }
            Event::Mouse(mouse::Event::CursorMoved { .. }) => {
                let (Some(anchor), Some(position)) =
                    (state.drag_anchor, cursor.land().position())
                else {
                    return;
                };
                if let Some(focus) = state.geom.hit(self.blocks, position - origin) {
                    let next = (focus != anchor).then_some(Selection { anchor, focus });
                    if next != state.selection {
                        state.selection = next;
                        publish(shell, &self.on_selection, next);
                        shell.request_redraw();
                    }
                    shell.capture_event();
                }
            }
            Event::Mouse(mouse::Event::ButtonReleased(mouse::Button::Left)) => {
                if state.drag_anchor.take().is_some() {
                    shell.capture_event();
                }
            }
            Event::Keyboard(keyboard::Event::KeyPressed { key, modifiers, .. })
                if modifiers.command() =>
            {
                let keyboard::Key::Character(c) = key.as_ref() else { return };
                match c.to_ascii_lowercase().as_str() {
                    "c" => {
                        if let Some(selection) = state.selection {
                            let text = selection.text(self.blocks);
                            clipboard.write(clipboard::Kind::Standard, text.clone());
                            if let Some(on_copy) = &self.on_copy {
                                shell.publish(on_copy(text));
                            }
                            shell.capture_event();
                        }
                    }
                    "a" if !self.blocks.is_empty() => {
                        let last = self.blocks.len() - 1;
                        let all = Selection {
                            anchor: Pos { block: 0, offset: 0 },
                            focus: Pos {
                                block: last,
                                offset: self.blocks[last].plain.len(),
                            },
                        };
                        state.selection = Some(all);
                        publish(shell, &self.on_selection, Some(all));
                        shell.request_redraw();
                        shell.capture_event();
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }

    fn draw(
        &self,
        tree: &Tree,
        renderer: &mut iced::Renderer,
        theme: &Theme,
        defaults: &renderer::Style,
        layout: Layout<'_>,
        _cursor: mouse::Cursor,
        viewport: &Rectangle,
    ) {
        let state = tree.state.downcast_ref::<State>();
        let origin = layout.bounds().position() - Point::ORIGIN;
        let palette = theme.extended_palette();
        let selection_color = palette.primary.weak.color;

        for (index, item) in state.geom.items.iter().enumerate() {
            let rect = item.rect + origin;
            if !rect.intersects(viewport) {
                continue;
            }
            let block = &self.blocks[index];
            let text_color = match block.kind {
                Kind::Role => palette.primary.strong.color,
                Kind::Quote => palette.background.strong.text.scale_alpha(0.75),
                _ => defaults.text_color,
            };

            match &block.kind {
                Kind::Code => {
                    let body = Rectangle {
                        x: rect.x + SIDE,
                        width: rect.width - 2.0 * SIDE,
                        ..rect
                    };
                    renderer.fill_quad(
                        renderer::Quad {
                            bounds: body,
                            border: Border {
                                radius: border::radius(6),
                                ..Border::default()
                            },
                            ..renderer::Quad::default()
                        },
                        palette.background.weak.color,
                    );
                }
                Kind::Quote => {
                    renderer.fill_quad(
                        renderer::Quad {
                            bounds: Rectangle {
                                x: rect.x + SIDE,
                                width: 3.0,
                                ..rect
                            },
                            ..renderer::Quad::default()
                        },
                        palette.background.strong.color,
                    );
                }
                Kind::ListItem { marker, .. } => {
                    renderer.fill_text(
                        text::Text {
                            content: marker.clone(),
                            bounds: Size::new(40.0, item.paragraph.min_bounds().height),
                            size: Pixels(BASE_SIZE),
                            line_height: text::LineHeight::default(),
                            font: Font::DEFAULT,
                            align_x: text::Alignment::Default,
                            align_y: alignment::Vertical::Top,
                            shaping: Shaping::Advanced,
                            wrapping: Wrapping::None,
                        },
                        Point::new(item.text_pos.x - 20.0, item.text_pos.y) + origin,
                        palette.background.strong.text,
                        *viewport,
                    );
                }
                _ => {}
            }

            if let Some(selection) = &state.selection {
                for r in state.geom.highlight(self.blocks, selection, index) {
                    renderer.fill_quad(
                        renderer::Quad {
                            bounds: r + origin,
                            ..renderer::Quad::default()
                        },
                        selection_color,
                    );
                }
            }

            let text_pos = item.text_pos + origin;
            let clip = if item.wraps {
                *viewport
            } else {
                // Long code lines are clipped at the code box edge.
                Rectangle {
                    x: rect.x + SIDE,
                    width: rect.width - 2.0 * SIDE,
                    ..rect
                }
                .intersection(viewport)
                .unwrap_or(*viewport)
            };
            renderer.fill_paragraph(&item.paragraph, text_pos, text_color, clip);
        }
    }

    fn mouse_interaction(
        &self,
        tree: &Tree,
        _layout: Layout<'_>,
        _cursor: mouse::Cursor,
        _viewport: &Rectangle,
        _renderer: &iced::Renderer,
    ) -> mouse::Interaction {
        let state = tree.state.downcast_ref::<State>();
        if state.hovered || state.drag_anchor.is_some() {
            mouse::Interaction::Text
        } else {
            mouse::Interaction::default()
        }
    }
}

impl<'a, Message: 'a> From<SelectableDoc<'a, Message>> for Element<'a, Message> {
    fn from(doc: SelectableDoc<'a, Message>) -> Self {
        Element::new(doc)
    }
}

