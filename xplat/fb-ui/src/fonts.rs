//! Bundled fonts and the CJK fallback rules.
//!
//! Inter (Regular as the variable face, plus static Medium/SemiBold/Bold) and JetBrains Mono Regular are embedded.
//! Both are SIL OFL 1.1; see `fonts/Inter-OFL.txt` and `fonts/JetBrainsMono-OFL.txt`. Inter and JetBrains Mono ship
//! no CJK glyphs on purpose: CJK text falls back to a system font through cosmic-text.
//!
//! Adapted from rmdv (MIT): the weight note and the CJK run rules.
//!
//! cosmic-text accepts a face only when its weight equals the requested weight, and a variable font is read as one
//! face at its default weight. That is why Medium/SemiBold/Bold are separate static files.

use iced::font::{Family, Style, Weight};
use iced::Font;
use std::borrow::Cow;

pub const BUNDLED: [&[u8]; 5] = [
    include_bytes!("../fonts/Inter-Variable.ttf"),
    include_bytes!("../fonts/Inter-Medium.ttf"),
    include_bytes!("../fonts/Inter-SemiBold.ttf"),
    include_bytes!("../fonts/Inter-Bold.ttf"),
    include_bytes!("../fonts/JetBrainsMono-Regular.otf"),
];

/// Font bytes for `iced::Settings::fonts` (and `iced_test` settings). Also installs the CJK fallback
/// ([`crate::cjk::install`]), so every place that sets up the fonts gets the same CJK faces.
pub fn bytes() -> Vec<Cow<'static, [u8]>> {
    crate::cjk::install();
    BUNDLED.iter().map(|b| Cow::Borrowed(*b)).collect()
}

/// The default app font: Inter Regular.
pub fn default_font() -> Font {
    inter(Weight::Normal)
}

pub fn inter(weight: Weight) -> Font {
    Font { family: Family::Name("Inter"), weight, ..Font::DEFAULT }
}

pub fn inter_italic() -> Font {
    Font { style: Style::Italic, ..inter(Weight::Normal) }
}

pub fn mono() -> Font {
    Font { family: Family::Name("JetBrains Mono"), ..Font::DEFAULT }
}

/// True for characters Inter and JetBrains Mono do not cover and that need the system CJK fallback.
pub fn is_cjk_char(c: char) -> bool {
    matches!(
        c as u32,
        0x1100..=0x11FF // Hangul Jamo
            | 0x2E80..=0x2FFF // CJK radicals
            | 0x3000..=0x303F // CJK symbols and punctuation
            | 0x3040..=0x30FF // Hiragana and Katakana
            | 0x3100..=0x312F // Bopomofo
            | 0x3130..=0x318F // Hangul compatibility Jamo
            | 0x31A0..=0x31BF // Bopomofo extensions
            | 0x3400..=0x4DBF // CJK extension A
            | 0x4E00..=0x9FFF // CJK unified ideographs
            | 0xA960..=0xA97F // Hangul Jamo extended-A
            | 0xAC00..=0xD7AF // Hangul syllables
            | 0xD7B0..=0xD7FF // Hangul Jamo extended-B
            | 0xF900..=0xFAFF // CJK compatibility ideographs
            | 0xFF00..=0xFFEF // Fullwidth and halfwidth forms
            | 0x20000..=0x2FA1F // CJK extensions
    )
}

/// Visits contiguous CJK and non-CJK runs without splitting a UTF-8 character. `visit(run, is_cjk)`.
pub fn for_text_runs<'a>(text: &'a str, mut visit: impl FnMut(&'a str, bool)) {
    let mut start = 0usize;
    let mut cur: Option<bool> = None;
    for (idx, c) in text.char_indices() {
        let is = is_cjk_char(c);
        match cur {
            None => cur = Some(is),
            Some(prev) if prev != is => {
                visit(&text[start..idx], prev);
                start = idx;
                cur = Some(is);
            }
            Some(_) => {}
        }
    }
    if let Some(c) = cur {
        visit(&text[start..], c);
    }
}

/// Font for one span. Code on a Latin run uses the mono font. CJK runs stay on the normal reader family and never
/// ask for italic, because CJK system fonts have no italic face and asking for one produces tofu.
pub fn span_font(code: bool, italic: bool, bold: bool, cjk: bool) -> Font {
    let mut font = if code && !cjk { mono() } else { inter(Weight::Normal) };
    if italic && !cjk {
        font.style = Style::Italic;
    }
    if bold && !code {
        font.weight = Weight::Bold;
    }
    font
}

#[cfg(test)]
mod tests {
    use super::*;
    use iced::advanced::graphics::text::cosmic_text::{fontdb, Attrs, Buffer, Family as CFamily, FontSystem, Metrics, Shaping, Weight as CWeight};
    use std::sync::Arc;

    fn shaped_families(text: &str, weight: CWeight) -> Vec<String> {
        let sources = BUNDLED.iter().map(|b| fontdb::Source::Binary(Arc::new(*b)));
        let mut fonts = FontSystem::new_with_fonts(sources);
        let mut buffer = Buffer::new(&mut fonts, Metrics::new(16.0, 20.0));
        buffer.set_text(&mut fonts, text, &Attrs::new().family(CFamily::Name("Inter")).weight(weight), Shaping::Advanced, None);
        buffer.shape_until_scroll(&mut fonts, false);
        let mut out = Vec::new();
        for run in buffer.layout_runs() {
            for glyph in run.glyphs {
                out.push(fonts.db().face(glyph.font_id).expect("face").families[0].0.clone());
            }
        }
        out
    }

    #[test]
    fn inter_weights_resolve_to_inter() {
        for w in [CWeight::NORMAL, CWeight::MEDIUM, CWeight::SEMIBOLD, CWeight::BOLD] {
            let f = shaped_families("Plain bold words", w);
            assert!(!f.is_empty());
            assert!(f.iter().all(|x| x == "Inter"), "{w:?} -> {f:?}");
        }
    }

    #[test]
    fn jetbrains_mono_family_is_registered() {
        let sources = BUNDLED.iter().map(|b| fontdb::Source::Binary(Arc::new(*b)));
        let fonts = FontSystem::new_with_fonts(sources);
        assert!(fonts.db().faces().any(|f| f.families.iter().any(|(n, _)| n == "JetBrains Mono")));
    }

    #[test]
    fn cjk_runs_split_and_never_italic() {
        let mut runs = Vec::new();
        for_text_runs("rank 排名 list", |r, cjk| runs.push((r.to_string(), cjk)));
        assert_eq!(runs, vec![("rank ".into(), false), ("排名".into(), true), (" list".into(), false)]);
        assert_eq!(span_font(false, true, false, true).style, Style::Normal);
        assert_eq!(span_font(false, true, false, false).style, Style::Italic);
        assert_eq!(span_font(true, false, false, true).family, Family::Name("Inter"));
        assert_eq!(span_font(true, false, false, false).family, Family::Name("JetBrains Mono"));
    }
}
