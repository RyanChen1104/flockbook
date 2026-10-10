//! Headless frame driver. Builds the real `UserInterface` (same code path as a
//! window, minus the window) and keeps the widget-tree cache between frames,
//! so `KeyedBody`'s diff runs against real stale state like in the app.
//!
//! Frame = events + `update()` + `view()` + layout + `draw()` + rasterise.
//! The renderer is tiny-skia (CPU). No window is ever created.

use crate::app::{Model, Msg, ScrollCmd};
use crate::chat::Message;
use iced_test::core::widget::operation::scrollable::{scroll_to, AbsoluteOffset};
use iced_test::core::clipboard;
use iced_test::core::renderer::Headless;
use iced_test::core::widget::Operation;
use iced_test::core::{mouse, renderer, Event, Font, Pixels, Point, Rectangle, Size, Vector};
use iced_test::runtime::user_interface::Cache;
use iced_test::runtime::UserInterface;
use std::time::{Duration, Instant};

type Ui<'a> = UserInterface<'a, Msg, iced::Theme, iced::Renderer>;

/// Safety valve: a frame settles within a few passes (event, window rebuild,
/// measure, anchor). More than this means a feedback loop.
pub const MAX_PASSES: usize = 8;

#[derive(Clone, Copy, Debug, Default)]
pub struct FrameStats {
    pub total: Duration,
    /// Events + `Model::update`.
    pub update: Duration,
    /// `view()` + diff + layout.
    pub build: Duration,
    /// `draw()` into primitives.
    pub draw: Duration,
    /// tiny-skia rasterisation.
    pub raster: Duration,
    pub passes: usize,
    pub settled: bool,
}

/// Reads the scrollable's true state through a widget operation.
#[derive(Default)]
struct Probe {
    found: Option<(f32, f32, f32)>,
}

impl Operation for Probe {
    fn traverse(&mut self, operate: &mut dyn FnMut(&mut dyn Operation)) {
        operate(self);
    }

    fn scrollable(
        &mut self,
        _id: Option<&iced_test::core::widget::Id>,
        bounds: Rectangle,
        content_bounds: Rectangle,
        translation: Vector,
        _state: &mut dyn iced_test::core::widget::operation::Scrollable,
    ) {
        self.found = Some((translation.y, bounds.height, content_bounds.height));
    }
}

pub struct Harness {
    pub model: Model,
    cache: Option<Cache>,
    renderer: iced::Renderer,
    pub size: Size,
    theme: iced::Theme,
    cursor: mouse::Cursor,
    pending_scroll: ScrollCmd,
    /// Rasterise every frame (the real cost). Tests may turn it off.
    pub rasterise: bool,
}

impl Harness {
    pub fn new(model: Model, size: Size) -> Self {
        // CPU renderer on purpose: deterministic, no GPU, no window.
        let renderer = iced_test::futures::futures::executor::block_on(
            <iced::Renderer as Headless>::new(Font::DEFAULT, Pixels(16.0), Some("tiny-skia")),
        )
        .expect("headless renderer");
        Self {
            model,
            cache: Some(Cache::default()),
            renderer,
            size,
            theme: iced::Theme::Dark,
            cursor: mouse::Cursor::Available(Point::new(size.width / 2.0, size.height / 2.0)),
            pending_scroll: None,
            rasterise: true,
        }
    }

    pub fn renderer_name(&self) -> String {
        use iced_test::core::renderer::Headless as _;
        self.renderer.name()
    }

    /// True scroll state: `(offset, viewport_h, content_h)`.
    pub fn probe(&mut self) -> Option<(f32, f32, f32)> {
        let mut out = None;
        let cache = self.cache.take().unwrap_or_default();
        {
            let mut ui: Ui<'_> =
                UserInterface::build(self.model.view(), self.size, cache, &mut self.renderer);
            let mut probe = Probe::default();
            ui.operate(
                &self.renderer,
                &mut iced_test::core::widget::operation::black_box(&mut probe),
            );
            out = out.or(probe.found);
            self.cache = Some(ui.into_cache());
        }
        out
    }

    /// Run one frame with `events`; messages are applied until the UI settles.
    pub fn frame(&mut self, events: Vec<Event>) -> FrameStats {
        let started = Instant::now();
        let mut stats = FrameStats::default();
        let mut events = Some(events);

        for pass in 0..MAX_PASSES {
            stats.passes = pass + 1;

            let t = Instant::now();
            let cache = self.cache.take().unwrap_or_default();
            let mut ui: Ui<'_> =
                UserInterface::build(self.model.view(), self.size, cache, &mut self.renderer);
            stats.build += t.elapsed();

            let t = Instant::now();
            let mut msgs: Vec<Msg> = Vec::new();
            if let Some(cmd) = self.pending_scroll.take() {
                let mut op = scroll_to::<()>(
                    self.model.scroll_id.clone(),
                    AbsoluteOffset { x: None, y: Some(cmd) },
                );
                ui.operate(
                    &self.renderer,
                    &mut iced_test::core::widget::operation::black_box(&mut op),
                );
            }
            let evs = events.take().unwrap_or_default();
            if !evs.is_empty() {
                ui.update(&evs, self.cursor, &mut self.renderer, &mut clipboard::Null, &mut msgs);
            }
            // The scrollable's true state is the source of truth for scroll.
            let mut probe = Probe::default();
            ui.operate(
                &self.renderer,
                &mut iced_test::core::widget::operation::black_box(&mut probe),
            );
            if let Some((offset, viewport_h, content_h)) = probe.found {
                msgs.push(Msg::Scrolled { offset, viewport_h, content_h });
            }
            // Layout ran during `build`: heights are waiting in the sink.
            let measured = self.model.drain_measure();
            if !measured.is_empty() {
                msgs.push(Msg::Measured(measured));
            }
            msgs.retain(|m| !self.model.is_noop(m));
            stats.update += t.elapsed();

            if msgs.is_empty() {
                let t = Instant::now();
                ui.draw(
                    &mut self.renderer,
                    &self.theme,
                    &renderer::Style { text_color: iced::Color::WHITE },
                    self.cursor,
                );
                stats.draw += t.elapsed();
                if self.rasterise {
                    let t = Instant::now();
                    let phys = Size::new(self.size.width as u32, self.size.height as u32);
                    let _ = self.renderer.screenshot(phys, 1.0, iced::Color::BLACK);
                    stats.raster += t.elapsed();
                }
                self.cache = Some(ui.into_cache());
                stats.settled = true;
                break;
            }

            self.cache = Some(ui.into_cache());
            let t = Instant::now();
            for m in msgs {
                if let Some(target) = self.model.update(m) {
                    self.pending_scroll = Some(target);
                }
            }
            stats.update += t.elapsed();
        }
        stats.total = started.elapsed();
        stats
    }

    /// Mouse wheel scroll by `dy` px (positive = content moves up = go down).
    pub fn wheel(&mut self, dy: f32) -> FrameStats {
        self.frame(vec![Event::Mouse(mouse::Event::WheelScrolled {
            delta: mouse::ScrollDelta::Pixels { x: 0.0, y: -dy },
        })])
    }

    /// Jump the scrollable to an absolute offset (scrollbar drag / goto).
    pub fn jump(&mut self, offset: f32) -> FrameStats {
        self.pending_scroll = Some(offset.max(0.0));
        self.frame(Vec::new())
    }

    /// Append a message as the runtime would after a `Msg::Append`.
    pub fn append(&mut self, message: Message) -> FrameStats {
        if let Some(target) = self.model.update(Msg::Append(message)) {
            self.pending_scroll = Some(target);
        }
        self.frame(Vec::new())
    }

    /// Does the rendered range cover the true viewport right now?
    pub fn covers_viewport(&mut self) -> bool {
        match self.probe() {
            Some((offset, vh, _)) => self.model.win.covers(offset, vh),
            None => false,
        }
    }
}
