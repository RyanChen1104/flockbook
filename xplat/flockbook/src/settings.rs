//! Settings (port of Swift `SettingsView`): window glass, reading width, and "Allow sending input to agents".
//!
//! Swift opens a separate fixed-size window; here it is a sheet over the app (one window). It opens with Cmd+,
//! (Ctrl+, on Windows and Linux) and from the gear at the bottom of the sidebar. Esc, the close button or a click
//! outside closes it.
//!
//! The values live in `settings.json` in the user's config folder. Tests and snapshots keep them in memory only
//! (`path` is `None`), so they never touch the real file. Not ported yet: the text size (the reading view's sizes
//! are fixed).
//!
//! When a change applies:
//! - Window glass: Opaque applies now. Glass needs a transparent window, which is made at launch: if the window was
//!   made opaque, Glass applies at the next launch.
//! - Width: now.
//! - Allow input: off applies now (the write paths are removed). On applies at the next launch: the write paths are
//!   made at launch, and turning them on is the riskier direction.

use std::path::{Path, PathBuf};

use fb_ui::icons::{icon, Icon, SIZE_INLINE};
use fb_ui::theme::*;
use iced::widget::{button, column, container, mouse_area, row, stack, text, toggler, Space};
use iced::{Alignment, Background, Border, Element, Length, Task};
use serde::{Deserialize, Serialize};

use crate::glass::{Backdrop, Os};
use crate::{style, App, Message};

/// The reading column (Swift `ReadingWidth`), in points.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReadingWidth {
    Narrow,
    #[default]
    Medium,
    Wide,
    Full,
}

impl ReadingWidth {
    pub const ALL: [ReadingWidth; 4] = [ReadingWidth::Narrow, ReadingWidth::Medium, ReadingWidth::Wide, ReadingWidth::Full];

    /// Full is "as wide as the pane": the pane clamps it.
    pub fn points(self) -> f32 {
        match self {
            ReadingWidth::Narrow => 600.0,
            ReadingWidth::Medium => 760.0,
            ReadingWidth::Wide => 920.0,
            ReadingWidth::Full => 2400.0,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            ReadingWidth::Narrow => "Narrow",
            ReadingWidth::Medium => "Medium",
            ReadingWidth::Wide => "Wide",
            ReadingWidth::Full => "Full",
        }
    }
}

/// The stored values. `None` is "not set": the default applies.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Prefs {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub glass: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reading_width: Option<ReadingWidth>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub allow_input: Option<bool>,
}

impl Prefs {
    /// A missing or unreadable file reads as "nothing set".
    pub fn load(path: &Path) -> Prefs {
        std::fs::read_to_string(path).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
    }

    /// Writes a temp file next to `path`, then renames it over `path`.
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_string_pretty(self).map_err(std::io::Error::other)?)?;
        std::fs::rename(&tmp, path)
    }
}

/// `<config dir>/flockbook/settings.json`: `~/Library/Application Support` on macOS, `%APPDATA%` on Windows,
/// `$XDG_CONFIG_HOME` or `~/.config` on Linux.
pub fn default_path() -> Option<PathBuf> {
    dirs::config_dir().map(|d| d.join("flockbook").join("settings.json"))
}

#[derive(Debug, Default)]
pub struct SettingsState {
    pub open: bool,
    pub prefs: Prefs,
    /// Where the values are saved. `None`: memory only (tests, snapshots, demo).
    pub path: Option<PathBuf>,
    /// Launched with `--read-only` (or `FLOCKBOOK_READ_ONLY`): input stays off whatever the setting says.
    pub read_only_launch: bool,
    /// A change that applies at the next launch, shown under the settings.
    pub pending: Option<&'static str>,
    /// The last save error.
    pub error: Option<String>,
}

impl SettingsState {
    pub fn reading_width(&self) -> ReadingWidth {
        self.prefs.reading_width.unwrap_or_default()
    }

    pub fn allow_input(&self) -> bool {
        self.prefs.allow_input.unwrap_or(true)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum SettingsMsg {
    Open,
    Close,
    Toggle,
    SetGlass(bool),
    SetWidth(ReadingWidth),
    SetAllowInput(bool),
}

pub const NEXT_LAUNCH_GLASS: &str = "Glass applies the next time Flockbook starts.";
pub const NEXT_LAUNCH_INPUT: &str = "Input turns on the next time Flockbook starts.";

pub fn update(app: &mut App, msg: SettingsMsg) -> Task<Message> {
    match msg {
        SettingsMsg::Open | SettingsMsg::Toggle => {
            app.state.settings.open = msg == SettingsMsg::Open || !app.state.settings.open;
            // One sheet at a time.
            if app.state.settings.open {
                app.state.shortcuts.open = false;
            }
        }
        SettingsMsg::Close => app.state.settings.open = false,
        SettingsMsg::SetGlass(on) => {
            if glass_note(app).1 {
                return Task::none();
            }
            app.state.settings.prefs.glass = Some(on);
            let launched_with_glass = app.state.glass.backdrop != Backdrop::Opaque;
            if on && launched_with_glass {
                app.state.glass.on = true;
                app.state.settings.pending = None;
            } else if on {
                app.state.settings.pending = Some(NEXT_LAUNCH_GLASS);
            } else {
                app.state.glass.on = false;
                if app.state.settings.pending == Some(NEXT_LAUNCH_GLASS) {
                    app.state.settings.pending = None;
                }
            }
            save(app);
        }
        SettingsMsg::SetWidth(w) => {
            app.state.settings.prefs.reading_width = Some(w);
            save(app);
        }
        SettingsMsg::SetAllowInput(on) => {
            if app.state.settings.read_only_launch {
                return Task::none();
            }
            let was = app.state.settings.allow_input();
            app.state.settings.prefs.allow_input = Some(on);
            if !on {
                crate::access::make_read_only(app);
                if app.state.settings.pending == Some(NEXT_LAUNCH_INPUT) {
                    app.state.settings.pending = None;
                }
            } else if !was || app.state.composer.sender.is_none() {
                app.state.settings.pending = Some(NEXT_LAUNCH_INPUT);
            }
            save(app);
        }
    }
    Task::none()
}

fn save(app: &mut App) {
    let s = &mut app.state.settings;
    if let Some(path) = &s.path {
        s.error = s.prefs.save(path).err().map(|e| format!("Could not save settings: {e}"));
    }
}

/// The note under the Window picker, and whether the picker is off.
fn glass_note(app: &App) -> (&'static str, bool) {
    if Os::current() == Os::Other {
        return ("Linux has no window glass: the window stays opaque.", true);
    }
    if app.state.glass.error.is_some() && app.state.glass.backdrop != Backdrop::Opaque {
        // Reduce Transparency, or an older Windows without Mica.
        return ("Opaque: the system turned window glass off.", true);
    }
    ("Glass lets the desktop show through, blurred.", false)
}

/// Glass is "on" in the picker when set on, or not set and the platform has it.
fn glass_selected(app: &App) -> bool {
    app.state.settings.prefs.glass.unwrap_or(Os::current() != Os::Other) && !glass_note(app).1
}

// ---------------------------------------------------------------------------------------------------------- view

pub const SHEET_W: f32 = 520.0;

fn segmented<'a, T: Copy + PartialEq + 'a>(t: Tokens, items: &[(T, &'static str)], selected: Option<T>, on: Option<fn(T) -> Message>) -> Element<'a, Message> {
    let mut r = row![].spacing(2);
    for &(value, label) in items {
        let sel = selected == Some(value);
        let color = if on.is_none() { t.label_3 } else { t.label };
        let mut b = button(container(text(label).size(CALLOUT.size).color(color)).center_x(Length::Fill)).width(Length::Fixed(66.0)).padding([3, 6]).style(move |_, st| button::Style {
            background: if sel {
                Some(Background::Color(t.bg))
            } else {
                matches!(st, button::Status::Hovered).then_some(Background::Color(t.fill_2))
            },
            border: Border { radius: 5.0.into(), width: if sel { 0.5 } else { 0.0 }, color: t.sep_strong },
            text_color: color,
            ..Default::default()
        });
        if let Some(f) = on {
            b = b.on_press(f(value));
        }
        r = r.push(b);
    }
    container(r).padding(2).style(style::fill(t.fill_1, 7.0)).into()
}

fn setting_row<'a>(t: Tokens, title: &'a str, note: String, control: Element<'a, Message>) -> Element<'a, Message> {
    container(
        row![column![BODY.text(title).color(t.label), CAPTION.text(note).color(t.label_2)].spacing(2).width(Length::Fill), control]
            .spacing(SP_12)
            .align_y(Alignment::Center),
    )
    .padding([10, 12])
    .into()
}

fn section<'a>(t: Tokens, title: &'a str, rows: Vec<Element<'a, Message>>) -> Element<'a, Message> {
    let mut col = column![].spacing(0);
    for (i, r) in rows.into_iter().enumerate() {
        if i > 0 {
            col = col.push(container(Space::new()).width(Length::Fill).height(Length::Fixed(1.0)).style(style::fill(t.sep, 0.0)));
        }
        col = col.push(r);
    }
    column![container(CAPTION.text(title).color(t.label_2)).padding([0, 12]), container(col).style(style::fill(t.fill_1, R_ROW + 4.0))].spacing(6).into()
}

/// The sheet, or nothing when closed.
pub fn layer(app: &App) -> Element<'_, Message> {
    if !app.state.settings.open {
        return Space::new().into();
    }
    let t = app.tokens();
    let s = &app.state.settings;

    let (note, glass_off) = glass_note(app);
    let glass = segmented(t, &[(true, "Glass"), (false, "Opaque")], Some(glass_selected(app)), (!glass_off).then_some(|v| Message::Settings(SettingsMsg::SetGlass(v))));
    let width = s.reading_width();
    let width_note = if width == ReadingWidth::Full { "The text fills the window.".to_string() } else { format!("Text column up to {} pt.", width.points() as u32) };
    let widths: Vec<(ReadingWidth, &'static str)> = ReadingWidth::ALL.iter().map(|w| (*w, w.label())).collect();
    let width_picker = segmented(t, &widths, Some(width), Some(|w| Message::Settings(SettingsMsg::SetWidth(w))));

    let input_on = s.allow_input() && !s.read_only_launch;
    let mut input_toggle = toggler(input_on).size(18.0);
    if !s.read_only_launch {
        input_toggle = input_toggle.on_toggle(|v| Message::Settings(SettingsMsg::SetAllowInput(v)));
    }
    let footer = if s.read_only_launch {
        "Launched with --read-only: the app only reads, whatever this says."
    } else if s.allow_input() {
        "Flockbook types into your agents' terminals. Turn this off to only read."
    } else {
        "Read only: typing, Allow and Deny, new tab, close tab and split are disabled."
    };
    let footer_color = if input_on { t.blocked } else { t.label_2 };
    let footer_row = row![icon(if input_on { Icon::Shield } else { Icon::Eye }, SIZE_INLINE, footer_color), CAPTION.text(footer).color(t.label_2)].spacing(6).align_y(Alignment::Center);

    let mut body = column![
        section(t, "Appearance", vec![setting_row(t, "Window", note.to_string(), glass)]),
        section(t, "Reading", vec![setting_row(t, "Width", width_note, width_picker)]),
        column![
            section(t, "Input", vec![setting_row(t, "Allow sending input to agents", "Typing, Allow and Deny, new tab, close tab and split.".into(), input_toggle.into())]),
            container(footer_row).padding([0, 12]),
        ]
        .spacing(6),
    ]
    .spacing(SP_16);
    for line in [s.pending.map(str::to_string), s.error.clone()].into_iter().flatten() {
        body = body.push(container(CAPTION.text(line).color(t.label_2)).padding([0, 12]));
    }

    let close = button(container(icon(Icon::X, SIZE_INLINE, t.label_2)).center(Length::Fixed(28.0))).padding(0).on_press(Message::Settings(SettingsMsg::Close)).style(move |_, st| button::Style {
        background: matches!(st, button::Status::Hovered).then_some(Background::Color(t.fill_2)),
        border: Border { radius: 14.0.into(), ..Default::default() },
        ..Default::default()
    });
    let header = row![HEADLINE.text("Settings").color(t.label), Space::new().width(Length::Fill), close].align_y(Alignment::Center);
    let card = container(column![header, body].spacing(SP_12)).padding(SP_16).width(Length::Fixed(SHEET_W)).style(style::float_e2(t, R_CARD));
    // The card swallows its own clicks; the scrim around it closes the sheet.
    let card = mouse_area(card).on_press(Message::Noop);
    let scrim = mouse_area(container(Space::new()).width(Length::Fill).height(Length::Fill).style(style::fill(iced::Color { a: 0.18, ..iced::Color::BLACK }, 0.0))).on_press(Message::Settings(SettingsMsg::Close));
    let placed = container(card).width(Length::Fill).height(Length::Fill).align_x(Alignment::Center).padding(iced::Padding { top: TOPROW_H + 24.0, ..iced::Padding::ZERO });
    stack![scrim, placed].into()
}
