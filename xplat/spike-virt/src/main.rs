//! Headless bench for the windowed chat list. Never opens a window.
//!
//! cargo run -p spike-virt --release -- --bench [--messages N] [--baseline]
//!   [--budget-secs S]   cap for the baseline run (default 90)

use iced_test::core::Size;
use spike_virt::app::{Mode, Model};
use spike_virt::gen::{generate, Rng};
use spike_virt::harness::{FrameStats, Harness};
use std::time::{Duration, Instant};

fn max_rss_mb() -> f64 {
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) };
    // macOS reports bytes, Linux kilobytes.
    let raw = ru.ru_maxrss as f64;
    if cfg!(target_os = "macos") {
        raw / (1024.0 * 1024.0)
    } else {
        raw / 1024.0
    }
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

fn report(name: &str, frames: &[FrameStats]) {
    if frames.is_empty() {
        println!("{name:<8} frames=0");
        return;
    }
    let mut t: Vec<f64> = frames.iter().map(|f| ms(f.total)).collect();
    t.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let pick = |p: f64| t[((t.len() - 1) as f64 * p).round() as usize];
    let avg = |f: fn(&FrameStats) -> Duration| {
        frames.iter().map(|x| ms(f(x))).sum::<f64>() / frames.len() as f64
    };
    println!(
        "{name:<8} frames={:<4} p50={:>8.2}ms p95={:>8.2}ms max={:>8.2}ms | mean build={:.2} update={:.2} draw={:.2} raster={:.2} | unsettled={}",
        frames.len(),
        pick(0.5),
        pick(0.95),
        t[t.len() - 1],
        avg(|f| f.build),
        avg(|f| f.update),
        avg(|f| f.draw),
        avg(|f| f.raster),
        frames.iter().filter(|f| !f.settled).count(),
    );
}

fn arg_value(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1).cloned())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if !args.iter().any(|a| a == "--bench") {
        eprintln!("usage: spike-virt --bench [--messages N] [--baseline] [--budget-secs S]");
        std::process::exit(2);
    }
    let n: usize = arg_value(&args, "--messages").and_then(|v| v.parse().ok()).unwrap_or(5000);
    let baseline = args.iter().any(|a| a == "--baseline");
    let budget = Duration::from_secs(
        arg_value(&args, "--budget-secs").and_then(|v| v.parse().ok()).unwrap_or(90),
    );
    let size = Size::new(1200.0, 900.0);

    let msgs = generate(n, 7);
    let rss_data = max_rss_mb();
    let mode = if baseline { Mode::Baseline } else { Mode::Windowed };
    let mut h = Harness::new(Model::new(&msgs, mode, size.height), size);
    println!(
        "mode={} messages={} blocks={} renderer={} viewport=1200x900",
        if baseline { "baseline(no virtualization)" } else { "windowed" },
        n,
        h.model.blocks.len(),
        h.renderer_name()
    );
    println!("peak RSS after generate+model (no UI yet): {rss_data:.1} MB");

    let started = Instant::now();
    let first = h.frame(Vec::new());
    println!("first frame: {:.1} ms (passes={})", ms(first.total), first.passes);

    let over_budget = |frames: &[FrameStats]| baseline && started.elapsed() > budget && !frames.is_empty();
    let mut rng = Rng::new(2024);
    let total = h.model.win.total_height();
    let mut capped = false;

    // 1. Fast sweep: 400 wheel steps from top to bottom.
    let mut sweep = Vec::new();
    for _ in 0..400 {
        if over_budget(&sweep) {
            capped = true;
            break;
        }
        sweep.push(h.wheel(total / 400.0));
    }
    // 2. 50 seeded random jumps.
    let mut jumps = Vec::new();
    for _ in 0..50 {
        if over_budget(&jumps) {
            capped = true;
            break;
        }
        let total = h.model.win.total_height();
        jumps.push(h.jump(total * rng.unit()));
    }
    // 3. Reading speed: 200 small wheel ticks.
    let mut smooth = Vec::new();
    for _ in 0..200 {
        if over_budget(&smooth) {
            capped = true;
            break;
        }
        smooth.push(h.wheel(60.0));
    }

    report("sweep", &sweep);
    report("jumps", &jumps);
    report("smooth", &smooth);
    let all: Vec<FrameStats> = sweep.iter().chain(&jumps).chain(&smooth).copied().collect();
    report("all", &all);
    let s = &h.model.stats;
    println!(
        "window rebuilds={} measured-rows={} corrections={} mean|estimate error|={:.1}px rendered-range-now={:?} of {}",
        s.rebuilds,
        s.measured,
        s.corrections,
        s.abs_err_px / s.measured.max(1) as f64,
        h.model.win.range,
        h.model.blocks.len()
    );
    println!("peak RSS: {:.1} MB (data only: {rss_data:.1} MB)", max_rss_mb());
    if capped {
        println!(
            "CAPPED: baseline stopped issuing frames after {}s budget; counts above are what finished",
            budget.as_secs()
        );
    }
    println!("total wall: {:.1}s", started.elapsed().as_secs_f64());
}
