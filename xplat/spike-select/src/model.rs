//! Flat block model of a rendered conversation, and the selection types.
//!
//! A conversation is a list of messages. Each message is parsed as Markdown and
//! flattened into an ordered list of [`Block`]s (role label, heading, paragraph,
//! list item, code block, quote line). Selection is expressed against that
//! flat list: a [`Pos`] is a block index plus a byte offset into the block's
//! plain text. That makes selection independent of any widget state, so an app
//! can keep it in its own state (needed for virtualized lists).

use std::cmp::Ordering;

use iced::widget::markdown::{self, Item};

/// Who wrote a message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    User,
    Assistant,
}

impl Role {
    pub fn label(self) -> &'static str {
        match self {
            Role::User => "You",
            Role::Assistant => "Assistant",
        }
    }
}

/// One conversation message with Markdown source.
#[derive(Debug, Clone)]
pub struct Message {
    pub role: Role,
    pub markdown: String,
}

/// What a block is, which decides its look and spacing.
#[derive(Debug, Clone, PartialEq)]
pub enum Kind {
    Role,
    Heading(u8),
    Paragraph,
    /// A list item. `marker` is drawn in the gutter and is not selectable text.
    ListItem { marker: String, depth: usize },
    Code,
    Quote,
}

/// Styled content of a block.
#[derive(Debug, Clone)]
pub enum Content {
    Rich(markdown::Text),
    Plain(String),
}

/// One selectable text block.
#[derive(Debug, Clone)]
pub struct Block {
    /// Stable id, unique in the conversation. Selection keys can use it.
    pub id: u64,
    pub kind: Kind,
    pub content: Content,
    /// Plain text with no Markdown syntax. This is what copy returns.
    pub plain: String,
    /// Text put between the previous block and this one when copying.
    pub separator: &'static str,
}

/// A point in the document: block index and byte offset in `Block::plain`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Pos {
    pub block: usize,
    pub offset: usize,
}

impl PartialOrd for Pos {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Pos {
    fn cmp(&self, other: &Self) -> Ordering {
        self.block
            .cmp(&other.block)
            .then(self.offset.cmp(&other.offset))
    }
}

/// A selection: where the drag started and where it is now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Selection {
    pub anchor: Pos,
    pub focus: Pos,
}

impl Selection {
    pub fn is_empty(&self) -> bool {
        self.anchor == self.focus
    }

    /// `(start, end)` in document order.
    pub fn ordered(&self) -> (Pos, Pos) {
        if self.anchor <= self.focus {
            (self.anchor, self.focus)
        } else {
            (self.focus, self.anchor)
        }
    }

    /// The selected plain text of `blocks`, blocks joined by their separators.
    pub fn text(&self, blocks: &[Block]) -> String {
        let (start, end) = self.ordered();
        let mut out = String::new();

        for index in start.block..=end.block.min(blocks.len().saturating_sub(1)) {
            let Some(block) = blocks.get(index) else { break };
            let from = if index == start.block { start.offset } else { 0 };
            let to = if index == end.block {
                end.offset
            } else {
                block.plain.len()
            };
            let from = clamp_boundary(&block.plain, from);
            let to = clamp_boundary(&block.plain, to);

            if index != start.block {
                out.push_str(block.separator);
            }
            if from < to {
                out.push_str(&block.plain[from..to]);
            }
        }

        out
    }
}

/// Moves `offset` down to the nearest char boundary inside `text`.
pub fn clamp_boundary(text: &str, offset: usize) -> usize {
    let mut offset = offset.min(text.len());
    while !text.is_char_boundary(offset) {
        offset -= 1;
    }
    offset
}

/// Parses every message and flattens it to blocks. Ids are assigned in order.
pub fn build_blocks(messages: &[Message]) -> Vec<Block> {
    let mut blocks = Vec::new();

    for message in messages {
        push(
            &mut blocks,
            Kind::Role,
            Content::Plain(message.role.label().to_owned()),
            message.role.label().to_owned(),
            "\n\n",
        );

        let items: Vec<Item> = markdown::parse(&message.markdown).collect();
        flatten(&mut blocks, &items, 0, false);
    }

    blocks
}

fn push(
    blocks: &mut Vec<Block>,
    kind: Kind,
    content: Content,
    plain: String,
    separator: &'static str,
) {
    let id = blocks.len() as u64;
    blocks.push(Block {
        id,
        kind,
        content,
        plain,
        separator,
    });
}

fn plain_of(text: &markdown::Text) -> String {
    let style = markdown::Style::from_palette(iced::Theme::Light.palette());
    text.spans(style).iter().map(|s| s.text.as_ref()).collect()
}

fn flatten(blocks: &mut Vec<Block>, items: &[Item], depth: usize, quote: bool) {
    for item in items {
        match item {
            Item::Heading(level, text) => {
                let n = *level as u8;
                push(
                    blocks,
                    Kind::Heading(n),
                    Content::Rich(text.clone()),
                    plain_of(text),
                    "\n\n",
                );
            }
            Item::Paragraph(text) => {
                let kind = if quote { Kind::Quote } else { Kind::Paragraph };
                push(
                    blocks,
                    kind,
                    Content::Rich(text.clone()),
                    plain_of(text),
                    "\n\n",
                );
            }
            Item::CodeBlock { code, .. } => {
                let code = code.trim_end_matches('\n').to_owned();
                push(blocks, Kind::Code, Content::Plain(code.clone()), code, "\n\n");
            }
            Item::List { start, bullets } => {
                for (index, bullet) in bullets.iter().enumerate() {
                    let (items, marker) = match bullet {
                        markdown::Bullet::Point { items } => (
                            items,
                            match start {
                                Some(first) => format!("{}.", first + index as u64),
                                None => "\u{2022}".to_owned(),
                            },
                        ),
                        markdown::Bullet::Task { items, done } => (
                            items,
                            if *done { "\u{2611}" } else { "\u{2610}" }.to_owned(),
                        ),
                    };
                    let first_of_item = blocks.len();
                    flatten(blocks, items, depth + 1, quote);

                    // The first text block of the bullet carries the marker.
                    if let Some(block) = blocks.get_mut(first_of_item) {
                        if matches!(block.kind, Kind::Paragraph | Kind::Quote) {
                            block.kind = Kind::ListItem {
                                marker,
                                depth: depth + 1,
                            };
                            if index > 0 {
                                block.separator = "\n";
                            }
                        }
                    }
                }
            }
            Item::Quote(inner) => flatten(blocks, inner, depth, true),
            Item::Image { alt, .. } => {
                push(
                    blocks,
                    Kind::Paragraph,
                    Content::Rich(alt.clone()),
                    plain_of(alt),
                    "\n\n",
                );
            }
            Item::Rule | Item::Table { .. } => {}
        }
    }
}

/// Deterministic synthetic conversation: `count` messages with mixed Markdown
/// and CJK text. It stands in for real session content.
pub fn synthetic_conversation(count: usize) -> Vec<Message> {
    let assistant = |n: usize| -> String {
        format!(
            "## Step {n}: check the parser\n\n\
             The parser reads each line and keeps `state_{n}` in sync. \
             See [the notes](https://example.com/notes/{n}) for the **full** story, \
             including why the cache is _not_ cleared on reload.\n\n\
             - First, load the session file number {n}\n\
             - Then, split it into turns\n\
             - Finally, render each turn as a block\n\n\
             ```rust\n\
             fn render_{n}(turn: &Turn) -> Block {{\n    \
             let text = turn.text();\n    \
             Block::new(text)\n}}\n\
             ```\n\n\
             這是一段中文測試文字。第 {n} 步完成後，請再檢查一次輸出是否正確。\n\n\
             > Remember: keep the diff small.\n"
        )
    };
    let user = |n: usize| -> String {
        format!("Please fix issue {n}. 請幫我修正第 {n} 個問題，並說明原因。")
    };

    (0..count)
        .map(|n| {
            if n % 2 == 0 {
                Message { role: Role::User, markdown: user(n) }
            } else {
                Message { role: Role::Assistant, markdown: assistant(n) }
            }
        })
        .collect()
}
