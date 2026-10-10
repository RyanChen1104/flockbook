//! Minimal Elm-style app around the selectable document, used by tests and
//! (later) by a real window. State owns the selection, the widget only mirrors it.

use iced::widget::{markdown, scrollable};
use iced::{Color, Element, Length, Theme};

use super::model::{build_blocks, Block, Message as ChatMessage, Selection};
use super::widget::SelectableDoc;

#[derive(Debug, Clone)]
pub enum Message {
    SelectionChanged(Option<Selection>),
    Copied(String),
}

pub struct App {
    pub blocks: Vec<Block>,
    pub selection: Option<Selection>,
    /// Last text the user copied. A real app would also have it on the system clipboard.
    pub last_copied: Option<String>,
    pub theme: Theme,
}

impl App {
    pub fn new(messages: &[ChatMessage]) -> Self {
        Self {
            blocks: build_blocks(messages),
            selection: None,
            last_copied: None,
            theme: Theme::Light,
        }
    }

    pub fn update(&mut self, message: Message) {
        match message {
            Message::SelectionChanged(selection) => self.selection = selection,
            Message::Copied(text) => self.last_copied = Some(text),
        }
    }

    pub fn style(&self) -> markdown::Style {
        let mut style = markdown::Style::from_palette(self.theme.palette());
        // The default inline code color is white and relies on a dark
        // background that this widget does not draw. Use a readable accent.
        style.inline_code_color = Color::from_rgb8(0xA8, 0x2E, 0x5C);
        style
    }

    pub fn view(&self) -> Element<'_, Message> {
        scrollable(
            SelectableDoc::new(&self.blocks, self.style())
                .selection(self.selection)
                .on_selection(Message::SelectionChanged)
                .on_copy(Message::Copied),
        )
        .width(Length::Fill)
        .height(Length::Fill)
        .into()
    }
}
