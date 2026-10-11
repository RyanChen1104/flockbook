//! The CJK fallback: which system font draws Chinese, Japanese and Korean text.
//!
//! Inter and JetBrains Mono have no CJK glyphs, so cosmic-text falls back to a system font. Its own lists fail in
//! two ways:
//!
//! - The face must have the exact requested weight. A family with no Regular (400) face, or only a variable face
//!   at another default weight (macOS ships PingFang as one variable face at 500), is skipped.
//! - The region comes from the locale only for `zh-TW`, `zh-HK` and `ja`. `en-TW` gets Simplified forms.
//!
//! On macOS 26 both hit. PingFang is not in the font folders, and its outlines use Apple's `hvgl` table, which swash
//! cannot draw. Hiragino Sans GB has no 400 face (W3 is 300). So Chinese fell to Arial Unicode MS, whose TrueType
//! hinting snaps stems to whole pixels: the text looks rough.
//!
//! The fix: per script group (Han, Kana, Hangul), take the installed families from a ranked list per platform and
//! region that draw a probe character with real outlines. Register the best three again under families of our own
//! at every weight from 100 to 900. A variable face is drawn at the requested weight; a static family uses its
//! nearest face. Our families go first in the script fallback, in rank order, so a character the first family
//! lacks goes to the second. The platform lists stay behind them.

use iced::advanced::graphics::text::cosmic_text::{self, fontdb, Fallback, PlatformFallback};
use unicode_script::Script;

/// Our families per script group, in rank order. The first one is the face that draws the group.
pub const HAN: [&str; 3] = ["Flockbook Han", "Flockbook Han 2", "Flockbook Han 3"];
pub const KANA: [&str; 3] = ["Flockbook Kana", "Flockbook Kana 2", "Flockbook Kana 3"];
pub const HANGUL: [&str; 3] = ["Flockbook Hangul", "Flockbook Hangul 2", "Flockbook Hangul 3"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    MacOs,
    Windows,
    Linux,
}

impl Platform {
    pub fn current() -> Platform {
        if cfg!(target_os = "macos") {
            Platform::MacOs
        } else if cfg!(target_os = "windows") {
            Platform::Windows
        } else {
            Platform::Linux
        }
    }
}

/// Which glyph forms Han text prefers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Region {
    /// Traditional, Taiwan.
    Tc,
    /// Traditional, Hong Kong and Macau.
    Hk,
    /// Simplified. The default.
    Sc,
    Ja,
    Ko,
}

/// Reads a locale such as `zh-Hant-TW`, `en-TW`, `ja_JP.UTF-8` or `ko`. The language decides for ja and ko; else
/// the script (Hant, Hans), else the region (TW, HK, MO), else Simplified.
pub fn region(locale: &str) -> Region {
    let lower = locale.to_ascii_lowercase();
    let parts: Vec<&str> = lower.split(['-', '_', '.', '@']).collect();
    match parts.first().copied() {
        Some("ja") => return Region::Ja,
        Some("ko") => return Region::Ko,
        _ => {}
    }
    let rest = &parts[1.min(parts.len())..];
    if rest.contains(&"hans") {
        return Region::Sc;
    }
    if rest.contains(&"hk") || rest.contains(&"mo") {
        return Region::Hk;
    }
    if rest.contains(&"hant") || rest.contains(&"tw") {
        return Region::Tc;
    }
    Region::Sc
}

/// Ranked families for Han text: the region's own design first, then other CJK sans faces, then the last resorts.
pub fn han_candidates(platform: Platform, region: Region) -> Vec<&'static str> {
    let (tc, hk, sc, ja, ko): (&[&str], &[&str], &[&str], &[&str], &[&str]) = match platform {
        Platform::MacOs => (
            // PingFang first for macOS releases that ship it with drawable outlines. Hiragino Sans GB covers all
            // of Big5 level 1 and has a real bold (W6); Heiti TC has no bold.
            &["PingFang TC", "Hiragino Sans GB", "Heiti TC"],
            &["PingFang HK", "Hiragino Sans GB", "Heiti TC"],
            &["PingFang SC", "Hiragino Sans GB", "Heiti SC"],
            &["Hiragino Sans", "Hiragino Kaku Gothic ProN"],
            &["Apple SD Gothic Neo"],
        ),
        Platform::Windows => (
            &["Microsoft JhengHei UI", "Microsoft JhengHei"],
            &["Microsoft JhengHei UI", "Microsoft JhengHei"],
            &["Microsoft YaHei UI", "Microsoft YaHei"],
            &["Yu Gothic UI", "Yu Gothic", "Meiryo UI", "Meiryo"],
            &["Malgun Gothic"],
        ),
        Platform::Linux => (
            &["Noto Sans CJK TC", "Noto Sans TC", "Source Han Sans TC", "Source Han Sans TW"],
            &["Noto Sans CJK HK", "Noto Sans HK", "Source Han Sans HC", "Source Han Sans HK"],
            &["Noto Sans CJK SC", "Noto Sans SC", "Source Han Sans SC", "Source Han Sans CN"],
            &["Noto Sans CJK JP", "Noto Sans JP", "Source Han Sans", "Source Han Sans JP"],
            &["Noto Sans CJK KR", "Noto Sans KR", "Source Han Sans K", "Source Han Sans KR"],
        ),
    };
    let order: [&[&str]; 5] = match region {
        Region::Tc => [tc, hk, sc, ja, ko],
        Region::Hk => [hk, tc, sc, ja, ko],
        Region::Sc => [sc, tc, hk, ja, ko],
        Region::Ja => [ja, sc, tc, hk, ko],
        Region::Ko => [ko, sc, tc, hk, ja],
    };
    let last: &[&str] = match platform {
        Platform::MacOs => &["Arial Unicode MS"],
        Platform::Windows => &["SimSun", "MingLiU"],
        Platform::Linux => &["WenQuanYi Micro Hei", "WenQuanYi Zen Hei", "Droid Sans Fallback", "AR PL UMing TW"],
    };
    let mut out: Vec<&'static str> = Vec::new();
    for f in order.into_iter().flatten().chain(last) {
        if !out.contains(f) {
            out.push(f);
        }
    }
    out
}

/// Kana: Japanese designs first in every region (kana appear only in Japanese text), then the rest.
pub fn kana_candidates(platform: Platform) -> Vec<&'static str> {
    han_candidates(platform, Region::Ja)
}

/// Hangul: Korean designs first.
pub fn hangul_candidates(platform: Platform) -> Vec<&'static str> {
    han_candidates(platform, Region::Ko)
}

/// The installed families, in rank order, that have an upright face drawing `probe`. At most `max`.
pub fn pick(db: &fontdb::Database, candidates: &[&str], probe: char, max: usize) -> Vec<String> {
    candidates
        .iter()
        .filter(|name| faces_of(db, name).first().is_some_and(|id| covers(db, *id, probe)))
        .take(max)
        .map(|s| s.to_string())
        .collect()
}

fn faces_of(db: &fontdb::Database, family: &str) -> Vec<fontdb::ID> {
    db.faces()
        .filter(|f| f.style == fontdb::Style::Normal && f.stretch == fontdb::Stretch::Normal && f.families.iter().any(|(n, _)| n == family))
        .map(|f| f.id)
        .collect()
}

/// True when the face maps `c` and has outlines swash can draw (`glyf`, `CFF `, `CFF2`). macOS 26 PingFang has only
/// Apple's `hvgl` outlines: it shapes but draws nothing. A file face is memory-mapped by fontdb, not read whole.
fn covers(db: &fontdb::Database, id: fontdb::ID, c: char) -> bool {
    use cosmic_text::skrifa::raw::types::Tag;
    use cosmic_text::skrifa::{FontRef, MetadataProvider};
    db.with_face_data(id, |data, index| {
        FontRef::from_index(data, index).is_ok_and(|f| {
            let outlines = [b"glyf", b"CFF ", b"CFF2"].iter().any(|t| f.table_data(Tag::new(t)).is_some());
            outlines && f.charmap().map(c).is_some()
        })
    })
    .unwrap_or(false)
}

/// Registers `family`'s faces again as `alias` at weights 100..=900, each pointing at the nearest real face.
/// Returns the number of faces added.
pub fn alias(db: &mut fontdb::Database, family: &str, alias: &str) -> usize {
    let faces: Vec<fontdb::FaceInfo> = faces_of(db, family).into_iter().filter_map(|id| db.face(id).cloned()).collect();
    if faces.is_empty() {
        return 0;
    }
    for w in (100..=900).step_by(100) {
        // Nearest weight; on a tie the heavier face above Medium, the lighter one below.
        let best = faces
            .iter()
            .min_by_key(|f| (f.weight.0.abs_diff(w), if w >= 500 { u16::MAX - f.weight.0 } else { f.weight.0 }))
            .expect("not empty");
        let mut info = best.clone();
        info.families = vec![(alias.to_string(), fontdb::Language::English_UnitedStates)];
        info.weight = fontdb::Weight(w);
        info.post_script_name = format!("{}-{alias}-{w}", best.post_script_name).replace(' ', "");
        db.push_face_info(info);
    }
    9
}

/// What `install` chose per group, best first. Empty when nothing suitable is installed.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Choice {
    pub han: Vec<String>,
    pub kana: Vec<String>,
    pub hangul: Vec<String>,
}

/// Picks the families per group and registers the aliases.
pub fn prepare(db: &mut fontdb::Database, platform: Platform, locale: &str) -> Choice {
    let r = region(locale);
    let choice = Choice {
        han: pick(db, &han_candidates(platform, r), '體', HAN.len()),
        kana: pick(db, &kana_candidates(platform), 'の', KANA.len()),
        hangul: pick(db, &hangul_candidates(platform), '한', HANGUL.len()),
    };
    for (families, names) in [(&choice.han, HAN), (&choice.kana, KANA), (&choice.hangul, HANGUL)] {
        for (family, name) in families.iter().zip(names) {
            alias(db, family, name);
        }
    }
    choice
}

/// The script fallback with our families in front.
pub struct CjkFallback {
    inner: PlatformFallback,
    han: Vec<&'static str>,
    kana: Vec<&'static str>,
    hangul: Vec<&'static str>,
}

impl CjkFallback {
    pub fn new(choice: &Choice, locale: &str) -> CjkFallback {
        let inner = PlatformFallback;
        let with = |names: [&'static str; 3], picked: &[String], script: Script| {
            let mut v: Vec<&'static str> = names[..picked.len().min(names.len())].to_vec();
            v.extend_from_slice(inner.script_fallback(script, locale));
            v
        };
        CjkFallback {
            han: with(HAN, &choice.han, Script::Han),
            kana: with(KANA, &choice.kana, Script::Hiragana),
            hangul: with(HANGUL, &choice.hangul, Script::Hangul),
            inner,
        }
    }
}

impl Fallback for CjkFallback {
    fn common_fallback(&self) -> &[&'static str] {
        self.inner.common_fallback()
    }

    fn forbidden_fallback(&self) -> &[&'static str] {
        self.inner.forbidden_fallback()
    }

    fn script_fallback(&self, script: Script, locale: &str) -> &[&'static str] {
        match script {
            Script::Han | Script::Bopomofo => &self.han,
            Script::Hiragana | Script::Katakana => &self.kana,
            Script::Hangul => &self.hangul,
            _ => self.inner.script_fallback(script, locale),
        }
    }
}

/// Swaps iced's global font system for one with the CJK fallback. Keeps every font already loaded and the locale.
/// Runs once; later calls return the first choice. Call it before the first frame.
pub fn install() -> Choice {
    static DONE: std::sync::OnceLock<Choice> = std::sync::OnceLock::new();
    DONE.get_or_init(|| {
        let mut system = iced::advanced::graphics::text::font_system().write().expect("font system lock");
        let raw = system.raw();
        let locale = raw.locale().to_string();
        let mut db = std::mem::take(raw.db_mut());
        let choice = prepare(&mut db, Platform::current(), &locale);
        let fallback = CjkFallback::new(&choice, &locale);
        *raw = cosmic_text::FontSystem::new_with_locale_and_db_and_fallback(locale, db, fallback);
        choice
    })
    .clone()
}
