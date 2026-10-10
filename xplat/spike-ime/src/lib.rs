//! spike-ime: a chat-style composer (single-line `text_input` plus multi-line
//! `text_editor`) used to check how iced 0.14 handles CJK input-method events.
//!
//! In iced 0.14 the widgets do NOT draw the preedit themselves. They only
//! report it through `InputMethod::Enabled { cursor, preedit, .. }`; the winit
//! shell then draws an "over-the-spot" overlay under the caret and tells the OS
//! where the candidate window goes (`set_ime_cursor_area`). [`Composer::view_with_overlay`]
//! reproduces that overlay so headless snapshots can show it.

use iced::advanced::input_method::{InputMethod, Preedit};
use iced::widget::{column, container, stack, text, text_editor, text_input};
use iced::{Element, Length, Padding};

/// Id of the single-line input.
pub const INPUT_ID: &str = "reply";

/// Fixed height of the multi-line editor, so tests can click it reliably.
pub const EDITOR_HEIGHT: f32 = 120.0;
/// Outer padding of the whole composer.
pub const OUTER_PADDING: f32 = 10.0;

#[derive(Debug, Clone)]
pub enum Message {
    ReplyChanged(String),
    NotesEdited(text_editor::Action),
}

#[derive(Default)]
pub struct Composer {
    pub reply: String,
    pub notes: text_editor::Content,
}

impl Composer {
    pub fn update(&mut self, message: Message) {
        match message {
            Message::ReplyChanged(value) => self.reply = value,
            Message::NotesEdited(action) => self.notes.perform(action),
        }
    }

    pub fn view(&self) -> Element<'_, Message> {
        column![
            text_input("Reply to the agent", &self.reply)
                .id(INPUT_ID)
                .on_input(Message::ReplyChanged),
            text_editor(&self.notes)
                .placeholder("Notes")
                .height(Length::Fixed(EDITOR_HEIGHT))
                .on_action(Message::NotesEdited),
        ]
        .spacing(10)
        .padding(OUTER_PADDING)
        .into()
    }

    /// Same as [`Composer::view`], plus the over-the-spot preedit overlay that
    /// the winit shell would draw for the given input-method request.
    pub fn view_with_overlay<'a>(
        &'a self,
        ime: &'a InputMethod,
    ) -> Element<'a, Message> {
        let base = self.view();
        let InputMethod::Enabled {
            cursor,
            preedit: Some(Preedit { content, .. }),
            ..
        } = ime
        else {
            return base;
        };
        if content.is_empty() {
            return base;
        }
        // The shell places the overlay at the caret's bottom-left corner.
        let overlay = container(
            container(text(content.as_str()))
                .padding(2)
                .style(container::bordered_box),
        )
        .padding(Padding {
            top: cursor.y + cursor.height,
            left: cursor.x,
            ..Padding::ZERO
        });
        stack![base, overlay].into()
    }
}
