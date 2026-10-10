//! Deterministic synthetic chat generator (no external RNG crate).

use crate::chat::{Kind, Message, Role};

/// xorshift64*: small, fast, fixed sequence for a fixed seed.
#[derive(Clone, Debug)]
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }

    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// Uniform in `lo..=hi`.
    pub fn range(&mut self, lo: usize, hi: usize) -> usize {
        lo + (self.next_u64() % (hi - lo + 1) as u64) as usize
    }

    pub fn chance(&mut self, percent: u64) -> bool {
        self.next_u64() % 100 < percent
    }

    /// Uniform f32 in 0..1.
    pub fn unit(&mut self) -> f32 {
        (self.next_u64() >> 40) as f32 / (1u64 << 24) as f32
    }
}

const WORDS: &[&str] = &[
    "the", "agent", "pane", "session", "build", "failed", "passed", "workspace", "output",
    "reading", "view", "message", "token", "stream", "scroll", "layout", "render", "window",
    "cache", "index", "update", "queue", "socket", "event", "state", "patch", "commit", "test",
    "fixture", "length", "offset", "range", "block", "height", "measure", "estimate", "and",
    "with", "from", "into", "after", "before", "because", "however", "should", "will",
];

const CJK: &[char] = &[
    '的', '一', '是', '不', '了', '人', '我', '在', '有', '他', '這', '個', '們', '中', '來', '上',
    '大', '為', '和', '國', '地', '到', '以', '說', '時', '要', '就', '出', '會', '可', '也', '你',
    '對', '生', '能', '而', '子', '那', '得', '於', '著', '下', '自', '之', '年', '過', '發', '後',
    '作', '里', '用', '道', '行', '所', '然', '家', '種', '事', '成', '方', '多', '經', '麼', '去',
];

fn ascii_line(rng: &mut Rng, chars: usize) -> String {
    let mut s = String::with_capacity(chars + 8);
    while s.len() < chars {
        if !s.is_empty() {
            s.push(' ');
        }
        s.push_str(WORDS[rng.range(0, WORDS.len() - 1)]);
    }
    s
}

fn cjk_line(rng: &mut Rng, chars: usize) -> String {
    (0..chars)
        .map(|i| {
            if i % 23 == 22 {
                '，'
            } else {
                CJK[rng.range(0, CJK.len() - 1)]
            }
        })
        .collect()
}

fn code_line(rng: &mut Rng) -> String {
    let indent = " ".repeat(rng.range(0, 3) * 4);
    let a = WORDS[rng.range(0, WORDS.len() - 1)];
    let b = WORDS[rng.range(0, WORDS.len() - 1)];
    match rng.range(0, 3) {
        0 => format!("{indent}let {a} = {b}({});", rng.range(0, 999)),
        1 => format!("{indent}if {a}.len() > {} {{ return {b}; }}", rng.range(1, 64)),
        2 => format!("{indent}fn {a}_{b}(x: &str) -> usize {{ x.len() + {} }}", rng.range(0, 9)),
        _ => format!("{indent}// {a} {b} {a}"),
    }
}

fn prose(rng: &mut Rng, lines: usize, cjk: bool) -> String {
    (0..lines)
        .map(|_| {
            if cjk {
                let n = rng.range(10, 90);
                cjk_line(rng, n)
            } else {
                let n = rng.range(20, 170);
                ascii_line(rng, n)
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn code(rng: &mut Rng, lines: usize) -> String {
    (0..lines).map(|_| code_line(rng)).collect::<Vec<_>>().join("\n")
}

/// Line count: mostly short, a long tail up to 250 lines.
fn line_count(rng: &mut Rng) -> usize {
    match rng.range(0, 99) {
        0..=49 => rng.range(1, 3),
        50..=79 => rng.range(4, 15),
        80..=94 => rng.range(16, 60),
        _ => rng.range(120, 250),
    }
}

pub fn generate_message(rng: &mut Rng, id: u32) -> Message {
    let role = if id % 2 == 0 { Role::User } else { Role::Assistant };
    let cjk = rng.chance(15);
    let mut lines = line_count(rng);
    if role == Role::User {
        lines = lines.min(8);
    }
    let mut parts = Vec::new();
    if role == Role::Assistant && lines >= 6 && rng.chance(35) {
        let code_lines = rng.range(3, (lines / 2).max(3).min(120));
        let intro = rng.range(1, 3);
        parts.push((Kind::Prose, prose(rng, intro, cjk)));
        parts.push((Kind::Code, code(rng, code_lines)));
        if lines > code_lines + 3 {
            parts.push((Kind::Prose, prose(rng, lines - code_lines, cjk)));
        }
    } else {
        parts.push((Kind::Prose, prose(rng, lines, cjk)));
    }
    Message { id, role, parts }
}

/// `n` messages with ids `0..n`, fully determined by `seed`.
pub fn generate(n: usize, seed: u64) -> Vec<Message> {
    let mut rng = Rng::new(seed);
    (0..n as u32).map(|id| generate_message(&mut rng, id)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flat(m: &[Message]) -> Vec<String> {
        m.iter()
            .flat_map(|m| m.parts.iter().map(|p| p.1.clone()))
            .collect()
    }

    #[test]
    fn same_seed_same_output() {
        assert_eq!(flat(&generate(300, 42)), flat(&generate(300, 42)));
        assert_ne!(flat(&generate(300, 42)), flat(&generate(300, 43)));
    }

    #[test]
    fn mix_has_code_cjk_and_long_messages() {
        let msgs = generate(2000, 1);
        let has_code = msgs.iter().any(|m| m.parts.iter().any(|p| p.0 == Kind::Code));
        let has_cjk = msgs
            .iter()
            .any(|m| m.parts.iter().any(|p| p.1.chars().any(|c| c as u32 >= 0x2E80)));
        let max_lines = msgs
            .iter()
            .map(|m| m.parts.iter().map(|p| p.1.split('\n').count()).sum::<usize>())
            .max()
            .unwrap();
        let one_liners = msgs
            .iter()
            .filter(|m| m.parts.len() == 1 && !m.parts[0].1.contains('\n'))
            .count();
        assert!(has_code && has_cjk);
        assert!(max_lines >= 200, "max lines {max_lines}");
        assert!(one_liners > 100);
    }
}
