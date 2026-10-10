//! Chat data model: messages, the blocks they split into, and the cheap
//! height estimate the window math starts from.

/// Chat width used by the estimate (px). The bench window is 1200 wide.
pub const CONTENT_WIDTH_PX: f32 = 1200.0 - 2.0 * PAD_X - 12.0;
pub const PAD_X: f32 = 16.0;
pub const PAD_Y: f32 = 4.0;
pub const PROSE_SIZE: f32 = 14.0;
pub const PROSE_LINE_PX: f32 = 20.0;
pub const CODE_SIZE: f32 = 13.0;
pub const CODE_LINE_PX: f32 = 18.0;
pub const CODE_PAD_PX: f32 = 6.0;
pub const HEADER_SIZE: f32 = 11.0;
pub const HEADER_LINE_PX: f32 = 14.0;
pub const HEADER_GAP_PX: f32 = 2.0;
/// A message part taller than this many lines splits into several blocks, so
/// no single block is taller than a viewport (~900px / 20px = 45 lines).
pub const MAX_BLOCK_LINES: usize = 30;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Prose,
    Code,
}

#[derive(Clone, Debug)]
pub struct Message {
    /// Stable message id; block keys derive from it.
    pub id: u32,
    pub role: Role,
    pub parts: Vec<(Kind, String)>,
}

/// The unit of virtualisation: a whole short message, or one slice of a part
/// of a long message.
#[derive(Clone, Debug)]
pub struct Block {
    pub key: u64,
    pub role: Role,
    pub kind: Kind,
    /// First block of its message: carries the role header.
    pub first: bool,
    pub text: String,
    pub lines: usize,
}

impl Block {
    pub fn estimate_height(&self) -> f32 {
        estimate_height(self.kind, &self.text, self.lines, self.first)
    }
}

pub fn block_key(message_id: u32, ordinal: u32) -> u64 {
    ((message_id as u64) << 16) | ordinal as u64
}

/// Split one message into blocks of at most `MAX_BLOCK_LINES` lines.
pub fn split_message(m: &Message) -> Vec<Block> {
    let mut out: Vec<Block> = Vec::new();
    for (kind, text) in &m.parts {
        let lines: Vec<&str> = text.split('\n').collect();
        for chunk in lines.chunks(MAX_BLOCK_LINES) {
            let ordinal = out.len() as u32;
            out.push(Block {
                key: block_key(m.id, ordinal),
                role: m.role,
                kind: *kind,
                first: ordinal == 0,
                text: chunk.join("\n"),
                lines: chunk.len(),
            });
        }
    }
    out
}

/// Display width of one char in px at the prose size (CJK is double width).
fn char_px(c: char) -> f32 {
    if (c as u32) >= 0x2E80 {
        PROSE_SIZE
    } else {
        PROSE_SIZE * 0.52
    }
}

fn wrapped_lines(text: &str) -> usize {
    text.split('\n')
        .map(|l| {
            let w: f32 = l.chars().map(char_px).sum();
            ((w / CONTENT_WIDTH_PX).ceil() as usize).max(1)
        })
        .sum()
}

/// Estimated height of a block's row (without the gap below it).
pub fn estimate_height(kind: Kind, text: &str, lines: usize, first: bool) -> f32 {
    let header = if first {
        HEADER_LINE_PX + HEADER_GAP_PX
    } else {
        0.0
    };
    let body = match kind {
        Kind::Prose => wrapped_lines(text) as f32 * PROSE_LINE_PX,
        Kind::Code => lines as f32 * CODE_LINE_PX + 2.0 * CODE_PAD_PX,
    };
    2.0 * PAD_Y + header + body
}

#[cfg(test)]
mod tests {
    use super::*;

    fn msg(lines: usize) -> Message {
        Message {
            id: 7,
            role: Role::Assistant,
            parts: vec![(Kind::Prose, vec!["line"; lines].join("\n"))],
        }
    }

    #[test]
    fn short_message_is_one_block() {
        let b = split_message(&msg(5));
        assert_eq!(b.len(), 1);
        assert!(b[0].first);
        assert_eq!(b[0].key, block_key(7, 0));
    }

    #[test]
    fn long_message_splits_under_viewport_height() {
        let b = split_message(&msg(200));
        assert_eq!(b.len(), 7);
        assert!(b.iter().all(|x| x.lines <= MAX_BLOCK_LINES));
        assert_eq!(b.iter().map(|x| x.lines).sum::<usize>(), 200);
        assert!(b.iter().filter(|x| x.first).count() == 1);
        let keys: std::collections::HashSet<_> = b.iter().map(|x| x.key).collect();
        assert_eq!(keys.len(), b.len());
        assert!(b.iter().all(|x| x.estimate_height() < 900.0));
    }

    #[test]
    fn cjk_wraps_earlier_than_ascii() {
        let ascii = "a".repeat(100);
        let cjk = "字".repeat(100);
        assert!(wrapped_lines(&cjk) > wrapped_lines(&ascii));
    }
}
