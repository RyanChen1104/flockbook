//! Word, line and paragraph ranges for double-click and triple-click selection.
//!
//! Words follow Unicode UAX 29 (`unicode-segmentation`), with one CJK rule: UAX 29 has no dictionary, so every
//! Han ideograph is its own "word". A double-click on Han text therefore selects the whole run of Han
//! characters around the click (and a Hiragana or Katakana run likewise), which is what a reader expects from a
//! phrase without spaces.

use super::model::clamp_boundary;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Script {
    Han,
    Hiragana,
    Katakana,
    Other,
}

fn script(c: char) -> Script {
    match c as u32 {
        0x2E80..=0x2FDF | 0x3005 | 0x3007 | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0x20000..=0x2FA1F => Script::Han,
        0x3041..=0x309F => Script::Hiragana,
        0x30A1..=0x30FF | 0x31F0..=0x31FF | 0xFF66..=0xFF9F => Script::Katakana,
        _ => Script::Other,
    }
}

/// The word around byte `offset` of `text`, as `(start, end)`. An offset at the end of the text picks the last
/// word. Whitespace and punctuation runs select as one unit.
pub fn word_range(text: &str, offset: usize) -> (usize, usize) {
    if text.is_empty() {
        return (0, 0);
    }
    let offset = clamp_boundary(text, offset);
    let probe = if offset >= text.len() { text.len() - 1 } else { offset };
    let probe = clamp_boundary(text, probe);
    let (mut start, mut end) = (0, text.len());
    for (i, seg) in text.split_word_bound_indices() {
        if probe >= i && probe < i + seg.len() {
            start = i;
            end = i + seg.len();
            break;
        }
    }
    // Extend a CJK script run around the segment.
    let first = text[start..].chars().next().map(script).unwrap_or(Script::Other);
    if first != Script::Other {
        while start > 0 {
            let prev = text[..start].chars().next_back().unwrap();
            if script(prev) != first {
                break;
            }
            start -= prev.len_utf8();
        }
        while end < text.len() {
            let next = text[end..].chars().next().unwrap();
            if script(next) != first {
                break;
            }
            end += next.len_utf8();
        }
    }
    (start, end)
}

/// The logical line around `offset` (split at `\n`, the newline not included).
pub fn line_range(text: &str, offset: usize) -> (usize, usize) {
    let offset = clamp_boundary(text, offset);
    let start = text[..offset].rfind('\n').map(|i| i + 1).unwrap_or(0);
    let end = text[offset..].find('\n').map(|i| offset + i).unwrap_or(text.len());
    (start, end)
}

/// The cell around `offset` when cells are separated by `\t` and rows by `\n`.
pub fn cell_range(text: &str, offset: usize) -> (usize, usize) {
    let offset = clamp_boundary(text, offset);
    let start = text[..offset].rfind(['\t', '\n']).map(|i| i + 1).unwrap_or(0);
    let end = text[offset..].find(['\t', '\n']).map(|i| offset + i).unwrap_or(text.len());
    (start, end)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pick(text: &str, at: &str) -> String {
        let i = text.find(at).unwrap();
        let (s, e) = word_range(text, i);
        text[s..e].to_string()
    }

    #[test]
    fn latin_words_and_punctuation() {
        let t = "Use log1p(clicks) so popularity can't dominate.";
        assert_eq!(pick(t, "log1p"), "log1p");
        assert_eq!(pick(t, "clicks"), "clicks");
        assert_eq!(pick(t, "can't"), "can't");
        assert_eq!(pick(t, "dominate"), "dominate");
        assert_eq!(pick(t, "("), "(");
    }

    #[test]
    fn whitespace_run_is_one_unit() {
        let t = "a   b";
        assert_eq!(word_range(t, 2), (1, 4));
    }

    #[test]
    fn han_run_is_one_word() {
        let t = "結果摘要：新上架的商品 now";
        assert_eq!(pick(t, "摘"), "結果摘要");
        assert_eq!(pick(t, "新"), "新上架的商品");
        assert_eq!(pick(t, "商"), "新上架的商品");
        assert_eq!(pick(t, "now"), "now");
    }

    #[test]
    fn kana_runs_split_by_script() {
        let t = "これはテストです";
        assert_eq!(pick(t, "こ"), "これは");
        assert_eq!(pick(t, "テ"), "テスト");
    }

    #[test]
    fn end_of_text_picks_last_word() {
        let t = "hello world";
        assert_eq!(word_range(t, t.len()), (6, 11));
        assert_eq!(word_range("", 0), (0, 0));
    }

    #[test]
    fn line_and_cell_ranges() {
        let t = "one\ntwo words\nthree";
        assert_eq!(line_range(t, 6), (4, 13));
        let tsv = "a\tbb\nc\td";
        assert_eq!(cell_range(tsv, 3), (2, 4));
        assert_eq!(cell_range(tsv, 6), (5, 6));
    }
}
