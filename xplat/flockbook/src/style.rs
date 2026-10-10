//! Small container styles shared by the modules. Add to it freely; keep each style a pure function of `Tokens`.

use fb_ui::theme::*;
use iced::widget::container;
use iced::{Background, Border, Color, Theme};

pub fn solid(c: Color) -> container::Style {
    container::Style { background: Some(Background::Color(c)), ..Default::default() }
}

/// The opaque content color of the main area.
pub fn content(t: Tokens) -> impl Fn(&Theme) -> container::Style {
    move |_| solid(t.bg)
}

pub fn sidebar(t: Tokens) -> impl Fn(&Theme) -> container::Style {
    move |_| container::Style {
        background: Some(Background::Color(t.sidebar)),
        border: Border { color: t.sep, width: 0.0, radius: 0.0.into() },
        ..Default::default()
    }
}

/// A filled rounded box (chips, selected rows, user bubble).
pub fn fill(color: Color, radius: f32) -> impl Fn(&Theme) -> container::Style {
    move |_| container::Style { background: Some(Background::Color(color)), border: Border { radius: radius.into(), ..Default::default() }, ..Default::default() }
}

/// e1 card: content color, hairline, soft shadow.
pub fn card_e1(t: Tokens, radius: f32) -> impl Fn(&Theme) -> container::Style {
    move |_| container::Style {
        background: Some(Background::Color(t.bg)),
        border: Border { color: t.sep, width: 1.0, radius: radius.into() },
        shadow: shadow_e1(&t),
        ..Default::default()
    }
}

/// e2 floating surface (composer, approval card, menus).
pub fn float_e2(t: Tokens, radius: f32) -> impl Fn(&Theme) -> container::Style {
    move |_| container::Style {
        background: Some(Background::Color(if t.mode.is_dark() { rgba(48, 48, 52, 1.0) } else { rgba(255, 255, 255, 1.0) })),
        border: Border { color: t.sep, width: 1.0, radius: radius.into() },
        shadow: shadow_e2(&t),
        ..Default::default()
    }
}
