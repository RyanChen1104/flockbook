//! The CJK fallback: locale to region, the ranked lists, the weight aliases, the font that draws CJK text, and
//! before/after crops at 2x. Pure CPU (cosmic-text + swash, the rasterizer that both iced renderers use).
//! Set `FB_WRITE_EVIDENCE=1` to copy the crops to `evidence/`.

use std::sync::Arc;

use fb_ui::cjk::{self, CjkFallback, Platform, Region};
use iced::advanced::graphics::text::cosmic_text::{fontdb, Attrs, Buffer, Family, FontSystem, Metrics, PlatformFallback, Shaping, SwashCache, Weight};

fn bundled_db() -> fontdb::Database {
    let mut db = fontdb::Database::new();
    for b in fb_ui::fonts::BUNDLED {
        db.load_font_source(fontdb::Source::Binary(Arc::new(b)));
    }
    db
}

// ------------------------------------------------------------ locale and lists

#[test]
fn the_locale_decides_the_han_forms() {
    for (locale, want) in [
        ("zh-TW", Region::Tc),
        ("zh-Hant", Region::Tc),
        ("zh-Hant-HK", Region::Hk),
        ("en-TW", Region::Tc),
        ("en_HK.UTF-8", Region::Hk),
        ("zh-MO", Region::Hk),
        ("zh-CN", Region::Sc),
        ("zh-Hans-TW", Region::Sc),
        ("en-US", Region::Sc),
        ("ja_JP.UTF-8", Region::Ja),
        ("ko-KR", Region::Ko),
        ("", Region::Sc),
    ] {
        assert_eq!(cjk::region(locale), want, "{locale}");
    }
}

#[test]
fn each_platform_ranks_its_own_cjk_sans_first() {
    let first = |p, r| cjk::han_candidates(p, r)[0];
    assert_eq!(first(Platform::MacOs, Region::Tc), "PingFang TC");
    assert_eq!(first(Platform::MacOs, Region::Sc), "PingFang SC");
    assert_eq!(first(Platform::Windows, Region::Tc), "Microsoft JhengHei UI");
    assert_eq!(first(Platform::Windows, Region::Sc), "Microsoft YaHei UI");
    assert_eq!(first(Platform::Linux, Region::Tc), "Noto Sans CJK TC");
    assert_eq!(first(Platform::Linux, Region::Ja), "Noto Sans CJK JP");
    assert_eq!(cjk::kana_candidates(Platform::Windows)[0], "Yu Gothic UI");
    assert_eq!(cjk::hangul_candidates(Platform::Linux)[0], "Noto Sans CJK KR");
}

#[test]
fn the_rough_faces_come_last_and_nothing_repeats() {
    for p in [Platform::MacOs, Platform::Windows, Platform::Linux] {
        for r in [Region::Tc, Region::Hk, Region::Sc, Region::Ja, Region::Ko] {
            let list = cjk::han_candidates(p, r);
            let mut dedup = list.clone();
            dedup.dedup();
            assert_eq!(list.len(), dedup.len());
            for rough in ["Arial Unicode MS", "SimSun", "MingLiU", "WenQuanYi Zen Hei", "Droid Sans Fallback"] {
                if let Some(i) = list.iter().position(|f| *f == rough) {
                    assert!(list[..i].iter().any(|f| f.contains("PingFang") || f.contains("Microsoft") || f.contains("Noto")), "{p:?} {r:?}: {rough} too early");
                }
            }
        }
    }
}

// ------------------------------------------------------------ aliases

#[test]
fn an_alias_covers_every_weight_with_the_nearest_face() {
    let mut db = bundled_db();
    assert_eq!(cjk::alias(&mut db, "Inter", "Alias Test"), 9);
    let weights: Vec<(u16, String)> = db
        .faces()
        .filter(|f| f.families[0].0 == "Alias Test")
        .map(|f| (f.weight.0, f.post_script_name.clone()))
        .collect();
    assert_eq!(weights.len(), 9);
    let ps = |w: u16| weights.iter().find(|(x, _)| *x == w).unwrap().1.clone();
    // The "Inter" family: Regular (400, variable) and Bold (700). Medium and SemiBold are families of their own.
    for w in [100, 400, 500] {
        assert!(ps(w).starts_with("Inter-Regular-"), "{w}: {}", ps(w));
    }
    for w in [600, 700, 900] {
        assert!(ps(w).starts_with("Inter-Bold-"), "{w}: {}", ps(w));
    }
    assert_eq!(cjk::alias(&mut db, "No Such Family", "Nothing"), 0);
}

#[test]
fn nothing_is_aliased_when_no_candidate_is_installed() {
    let mut db = bundled_db();
    let choice = cjk::prepare(&mut db, Platform::Linux, "zh-TW");
    // The bundled fonts have no CJK; on a bare Linux box this is the state, and the platform lists still apply.
    assert_eq!(choice, cjk::Choice::default());
    let fb = CjkFallback::new(&choice, "zh-TW");
    use iced::advanced::graphics::text::cosmic_text::Fallback;
    assert!(!fb.script_fallback(unicode_script::Script::Han, "zh-TW").contains(&cjk::HAN[0]));
}

// ------------------------------------------------------------ the real system fonts

/// The system fonts plus ours, with cosmic-text's own fallback (before) or ours (after).
fn system(after: bool, locale: &str) -> (FontSystem, cjk::Choice) {
    let mut db = bundled_db();
    db.load_system_fonts();
    if after {
        let choice = cjk::prepare(&mut db, Platform::current(), locale);
        let fb = CjkFallback::new(&choice, locale);
        (FontSystem::new_with_locale_and_db_and_fallback(locale.into(), db, fb), choice)
    } else {
        (FontSystem::new_with_locale_and_db_and_fallback(locale.into(), db, PlatformFallback), cjk::Choice::default())
    }
}

/// The family that drew each glyph of `text` at `weight`.
fn families(fs: &mut FontSystem, text: &str, weight: Weight) -> Vec<String> {
    let mut buf = Buffer::new(fs, Metrics::new(26.0, 36.0));
    buf.set_text(fs, text, &Attrs::new().family(Family::Name("Inter")).weight(weight), Shaping::Advanced, None);
    buf.shape_until_scroll(fs, false);
    let mut out = Vec::new();
    for run in buf.layout_runs() {
        for g in run.glyphs {
            let name = fs.db().face(g.font_id).unwrap().families[0].0.clone();
            if !out.contains(&name) {
                out.push(name);
            }
        }
    }
    out
}

#[test]
fn han_text_uses_the_picked_face_at_every_weight() {
    let (mut fs, choice) = system(true, "en-TW");
    let Some(han) = choice.han.first().cloned() else {
        eprintln!("no CJK font installed here: nothing to check");
        return;
    };
    for w in [Weight::NORMAL, Weight::MEDIUM, Weight::SEMIBOLD, Weight::BOLD] {
        let f = families(&mut fs, "排名清單：中文字測試，繁體顯示", w);
        assert_eq!(f, vec![cjk::HAN[0].to_string()], "{w:?} ({han})");
    }
    assert_eq!(families(&mut fs, "Plain words", Weight::NORMAL), vec!["Inter".to_string()], "Latin stays on Inter");
}

/// The bug: on macOS 26 Chinese fell to Arial Unicode MS. PingFang there has only `hvgl` outlines, so it is
/// skipped; Hiragino Sans GB draws Chinese now.
#[cfg(target_os = "macos")]
#[test]
fn macos_draws_chinese_with_hiragino_not_arial_unicode() {
    let (mut before, _) = system(false, "en-TW");
    assert_eq!(families(&mut before, "排名清單", Weight::NORMAL), vec!["Arial Unicode MS".to_string()], "the old fallback");
    let (_, choice) = system(true, "en-TW");
    assert!(!choice.han.iter().any(|f| f.contains("PingFang")), "PingFang draws nothing here: {choice:?}");
    assert_eq!(choice.han.first().map(String::as_str), Some("Hiragino Sans GB"), "{choice:?}");
    assert_eq!(choice.kana.first().map(String::as_str), Some("Hiragino Sans"), "{choice:?}");
    assert_eq!(choice.hangul.first().map(String::as_str), Some("Apple SD Gothic Neo"), "{choice:?}");
}

// ------------------------------------------------------------ crops

const TEXT: &str = "Flockbook 排名清單：中文字測試，繁體顯示";
const LINE: usize = 40;
const WIDTH: usize = 620;

/// One line at 13 pt and scale 2 (26 px), dark text on white, as iced draws it (swash, alpha mask, hinting on).
fn line(fs: &mut FontSystem, weight: Weight) -> Vec<u8> {
    let mut buf = Buffer::new(fs, Metrics::new(26.0, LINE as f32));
    buf.set_size(fs, Some(WIDTH as f32 * 2.0), None);
    buf.set_text(fs, TEXT, &Attrs::new().family(Family::Name("Inter")).weight(weight), Shaping::Advanced, None);
    buf.shape_until_scroll(fs, false);
    let mut px = vec![255u8; WIDTH * LINE];
    let mut cache = SwashCache::new();
    for run in buf.layout_runs() {
        for g in run.glyphs {
            let pg = g.physical((8.0, 0.0), 1.0);
            let Some(img) = cache.get_image_uncached(fs, pg.cache_key) else { continue };
            let (w, h) = (img.placement.width as i32, img.placement.height as i32);
            for y in 0..h {
                for x in 0..w {
                    let a = img.data[(y * w + x) as usize] as i32;
                    let (dx, dy) = (pg.x + img.placement.left + x, run.line_y as i32 + pg.y - img.placement.top + y);
                    if (0..WIDTH as i32).contains(&dx) && (0..LINE as i32).contains(&dy) {
                        let p = &mut px[dy as usize * WIDTH + dx as usize];
                        *p = (*p as i32 * (255 - a) / 255) as u8;
                    }
                }
            }
        }
    }
    px
}

/// Share of the inked pixels that are fully black. Hinted Arial Unicode MS snaps stems to whole pixels: hard edges.
fn hard_edge_share(px: &[u8]) -> f32 {
    let inked = px.iter().filter(|&&p| p < 250).count() as f32;
    px.iter().filter(|&&p| p == 0).count() as f32 / inked.max(1.0)
}

fn write_gray(rows: &[Vec<u8>], scale: usize, name: &str) {
    let (w, h) = (WIDTH * scale, LINE * rows.len() * scale);
    let mut img = Vec::with_capacity(w * h);
    for row in rows {
        for y in 0..LINE {
            let mut line = Vec::with_capacity(w);
            for x in 0..WIDTH {
                line.extend(std::iter::repeat_n(row[y * WIDTH + x], scale));
            }
            for _ in 0..scale {
                img.extend_from_slice(&line);
            }
        }
    }
    let mut dirs = vec![std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR"))];
    if std::env::var_os("FB_WRITE_EVIDENCE").is_some() {
        dirs.push(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("evidence"));
    }
    for dir in dirs {
        let file = std::fs::File::create(dir.join(format!("{name}.png"))).unwrap();
        let mut enc = png::Encoder::new(file, w as u32, h as u32);
        enc.set_color(png::ColorType::Grayscale);
        enc.set_depth(png::BitDepth::Eight);
        enc.write_header().unwrap().write_image_data(&img).unwrap();
    }
}

#[test]
fn crops_before_and_after_at_2x() {
    let (mut before, _) = system(false, "en-TW");
    let (mut after, choice) = system(true, "en-TW");
    let rows = vec![line(&mut before, Weight::NORMAL), line(&mut after, Weight::NORMAL), line(&mut before, Weight::BOLD), line(&mut after, Weight::BOLD)];
    // Rows: before regular, after regular, before bold, after bold. 2x pixels, then 3x nearest to see the edges.
    write_gray(&rows, 1, "cjk-before-after-2x");
    write_gray(&rows, 3, "cjk-before-after-2x-zoom3");
    // Every row has the CJK text: the ink right of "Flockbook " is there (a face that draws nothing failed here).
    for (i, row) in rows.iter().enumerate() {
        let cjk_ink = (0..LINE).flat_map(|y| (180..WIDTH).map(move |x| (x, y))).filter(|&(x, y)| row[y * WIDTH + x] < 128).count();
        assert!(cjk_ink > 1500, "row {i}: CJK ink {cjk_ink}");
    }
    if cfg!(target_os = "macos") && !choice.han.is_empty() {
        let (b, a) = (hard_edge_share(&rows[0]), hard_edge_share(&rows[1]));
        eprintln!("hard edge share: before {b:.3}, after {a:.3}");
        assert!(a < b * 0.8, "the new face has softer edges: before {b:.3}, after {a:.3}");
    }
}
