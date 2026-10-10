//! Headless fuzz: scroll, jump and append against the real widget tree.
//! No window is opened; rendering is tiny-skia.

use iced_test::core::Size;
use spike_virt::app::{Mode, Model};
use spike_virt::gen::{generate, generate_message, Rng};
use spike_virt::harness::{FrameStats, Harness};

const SIZE: Size = Size { width: 1200.0, height: 900.0 };

fn harness(n: usize, mode: Mode) -> Harness {
    let msgs = generate(n, 7);
    let mut h = Harness::new(Model::new(&msgs, mode, SIZE.height), SIZE);
    h.rasterise = false;
    h.frame(Vec::new());
    h
}

fn check(h: &mut Harness, stats: &FrameStats, what: &str) {
    assert!(stats.settled, "{what}: frame did not settle in {} passes", stats.passes);
    assert!(h.covers_viewport(), "{what}: window {:?} misses viewport", h.model.win.range);
    // Rendered blocks always exist for the whole range.
    assert!(h.model.win.range.1 <= h.model.blocks.len());
}

fn total(h: &Harness) -> f32 {
    h.model.win.total_height()
}

#[test]
fn smoke_first_frame() {
    let mut h = harness(1500, Mode::Windowed);
    let (offset, vh, content) = h.probe().expect("scrollable found");
    assert_eq!(offset, 0.0);
    assert!((vh - 900.0).abs() < 1.0, "viewport {vh}");
    assert!(content > 5000.0, "content {content}");
    assert!(h.model.win.active);
    let (s, e) = h.model.win.range;
    assert_eq!(s, 0);
    assert!(e < 400, "window should be small, got {e}");
    assert!(h.model.stats.measured > 0, "measure sink fed by KeyedBody");
}

fn fuzz(mode: Mode, n: usize, steps: usize, randoms: usize) {
    let mut h = harness(n, mode);
    let mut rng = Rng::new(99);
    let end = total(&h);

    // top -> bottom in wheel steps, then jump bottom -> middle -> top.
    for i in 0..steps {
        let s = h.wheel(end / steps as f32 * (0.5 + rng.unit()));
        check(&mut h, &s, &format!("sweep {i}"));
    }
    let end = total(&h);
    for (label, frac) in [("bottom", 1.0), ("middle", 0.5), ("top", 0.0), ("bottom2", 1.0)] {
        let s = h.jump(end * frac);
        check(&mut h, &s, label);
    }
    // Seeded random jumps (both directions) and small wheel moves.
    for i in 0..randoms {
        let end = total(&h);
        let s = if rng.chance(70) {
            h.jump(end * rng.unit())
        } else {
            h.wheel((rng.unit() - 0.5) * 3000.0)
        };
        check(&mut h, &s, &format!("random {i}"));
    }
}

#[test]
fn fuzz_windowed_reorder_mode() {
    // Debug builds shape text slowly (~0.5s/frame); the release bench does the
    // heavy sweeps. This still crosses the whole 5k list both ways.
    fuzz(Mode::Windowed, 5000, 30, 40);
}

#[test]
fn fuzz_windowed_fresh_mode() {
    fuzz(Mode::WindowedFresh, 2000, 20, 30);
}

#[test]
fn append_while_pinned_follows_bottom() {
    let mut h = harness(1200, Mode::Windowed);
    let end = total(&h);
    let s = h.jump(end);
    check(&mut h, &s, "to bottom");
    assert!(h.model.pinned);
    let mut rng = Rng::new(5);
    for i in 0..40u32 {
        let msg = generate_message(&mut rng, 100_000 + i);
        let s = h.append(msg);
        check(&mut h, &s, &format!("append {i}"));
        let (offset, vh, content) = h.probe().unwrap();
        assert!(
            content - (offset + vh) < 3.0,
            "append {i}: not at bottom (offset {offset}, content {content})"
        );
    }
}

#[test]
fn append_while_scrolled_up_keeps_position() {
    let mut h = harness(1200, Mode::Windowed);
    let end = total(&h);
    let s = h.jump(end * 0.4);
    check(&mut h, &s, "mid");
    assert!(!h.model.pinned);
    let before = h.probe().unwrap().0;
    let mut rng = Rng::new(6);
    for i in 0..20u32 {
        let s = h.append(generate_message(&mut rng, 200_000 + i));
        check(&mut h, &s, "append mid");
    }
    let after = h.probe().unwrap().0;
    assert!((after - before).abs() < 400.0, "offset drifted {before} -> {after}");
}

#[test]
fn small_scrolls_do_not_rebuild_window() {
    let mut h = harness(1500, Mode::Windowed);
    let s = h.jump(total(&h) * 0.3);
    check(&mut h, &s, "mid");
    let rebuilds = h.model.stats.rebuilds;
    for i in 0..10 {
        let s = h.wheel(40.0);
        check(&mut h, &s, &format!("nudge {i}"));
    }
    assert_eq!(h.model.stats.rebuilds, rebuilds, "tiny scrolls must stay inside the band");
}

#[test]
fn small_list_renders_in_full() {
    let mut h = harness(40, Mode::Windowed);
    assert!(!h.model.win.active);
    assert_eq!(h.model.win.range, (0, h.model.blocks.len()));
    let s = h.wheel(500.0);
    check(&mut h, &s, "small");
}
