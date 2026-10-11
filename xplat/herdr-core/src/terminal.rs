//! One long-lived `herdr terminal session control|observe <terminal_id>` child process (port of TerminalSession.swift).
//!
//! Input, resize and frames share the child's pipes, so a key press is one small pipe write (no socket per key).
//! Control mode owns the terminal's input and size (herdr allows one controller; `takeover` steals it). Observe mode is read-only.
//!
//! The binary and its leading args are injectable (`launcher`), so tests run a fake script.
//!
//! SAFETY: the mutating methods here (`send_*`, `paste`, `resize`, `wheel`, `right_click`, `release`) write to a real terminal.
//! Live writes are for the `c9-input-test` session only. Tests must use a fake launcher.

use crate::session::HerdrSession;
use base64::Engine;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq)]
pub struct TerminalFrame {
    pub seq: i64,
    pub full: bool,
    pub width: u32,
    pub height: u32,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TerminalEvent {
    /// First frame after (re)connect is `full`; later ones are increments (or a full redraw after a resize).
    Frame(TerminalFrame),
    /// Final: the stream ends after this. Reasons seen: `detached`, `terminal attach taken over`,
    /// `terminal attach failed: ... already has an attached client ...`, `... not found`.
    Closed { reason: String },
    /// The process ended without a closed record; a new one starts after a short delay.
    Reconnecting { attempt: u32 },
    /// A line from stderr, e.g. an ignored input.
    Notice(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalMode {
    Observe,
    Control { takeover: bool },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseEncoding {
    Sgr,
    Legacy,
}

#[derive(Default)]
struct State {
    started: bool,
    stopped: bool,
    /// `stop()` was called (not only `release()`): a child that appears later must be killed.
    killed: bool,
    want_cols: Option<usize>,
    want_rows: Option<usize>,
    last_size: Option<(u32, u32)>,
    /// herdr frames do not carry DEC private modes; assume yes until a frame says `?2004l`.
    bracketed: bool,
    child: Option<Child>,
    stdin: Option<ChildStdin>,
    /// `None` after the stream finished.
    tx: Option<Sender<TerminalEvent>>,
}

struct Inner {
    terminal_id: String,
    mode: TerminalMode,
    argv_prefix: Vec<String>,
    strip_herdr_env: bool,
    st: Mutex<State>,
    /// Test hook: runs right after the child is spawned, before it is stored.
    after_spawn: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

pub struct TerminalSession {
    inner: Arc<Inner>,
}

fn default_launcher(session: &HerdrSession) -> Vec<String> {
    let mut v: Vec<String> = if cfg!(unix) { vec!["/usr/bin/env".into(), "herdr".into()] } else { vec!["herdr".into()] };
    v.extend(session.cli_prefix());
    v
}

impl Inner {
    fn emit(&self, e: TerminalEvent) {
        if let Some(tx) = &self.st.lock().unwrap().tx {
            let _ = tx.send(e);
        }
    }

    fn finish(&self) {
        self.st.lock().unwrap().tx = None;
    }

    fn stopped(&self) -> bool {
        self.st.lock().unwrap().stopped
    }

    fn stop(&self) {
        let mut st = self.st.lock().unwrap();
        st.stopped = true;
        st.killed = true;
        st.stdin = None;
        if let Some(mut c) = st.child.take() {
            let _ = c.kill();
            thread::spawn(move || {
                let _ = c.wait();
            });
        }
        st.tx = None;
    }

    fn write(&self, data: &[u8]) -> bool {
        let mut st = self.st.lock().unwrap();
        let Some(h) = st.stdin.as_mut() else { return false };
        h.write_all(data).and_then(|_| h.flush()).is_ok()
    }

    fn write_json(&self, o: Value) -> bool {
        if self.mode == TerminalMode::Observe {
            return false;
        }
        let mut d = o.to_string().into_bytes();
        d.push(b'\n');
        self.write(&d)
    }

    /// Sleeps in short slices so `stop()` ends the wait early. True when stopped.
    fn sleep_unless_stopped(&self, ms: u64) -> bool {
        let mut left = ms;
        while left > 0 {
            if self.stopped() {
                return true;
            }
            let step = left.min(20);
            thread::sleep(Duration::from_millis(step));
            left -= step;
        }
        self.stopped()
    }
}

fn rfind(h: &[u8], n: &[u8]) -> Option<usize> {
    if n.is_empty() || h.len() < n.len() {
        return None;
    }
    (0..=h.len() - n.len()).rev().find(|&i| &h[i..i + n.len()] == n)
}

fn find(h: &[u8], n: &[u8]) -> Option<usize> {
    if n.is_empty() || h.len() < n.len() {
        return None;
    }
    (0..=h.len() - n.len()).find(|&i| &h[i..i + n.len()] == n)
}

enum Outcome {
    Final,
    Retry,
}

impl TerminalSession {
    /// Not started yet; call `start()`. `launcher` replaces `/usr/bin/env herdr --session <name>` (tests use a fake script).
    /// Frames and state changes arrive on the receiver; it ends after `Closed`, `release()` or `stop()`.
    pub fn new(
        terminal_id: &str, session: &HerdrSession, mode: TerminalMode, cols: Option<usize>, rows: Option<usize>, launcher: Option<Vec<String>>,
    ) -> (TerminalSession, Receiver<TerminalEvent>) {
        let (tx, rx) = channel();
        let st = State {
            want_cols: cols.filter(|c| *c > 0),
            want_rows: rows.filter(|r| *r > 0),
            bracketed: true,
            tx: Some(tx),
            ..Default::default()
        };
        let inner = Inner {
            terminal_id: terminal_id.to_string(),
            mode,
            argv_prefix: launcher.filter(|l| !l.is_empty()).unwrap_or_else(|| default_launcher(session)),
            strip_herdr_env: session.name.is_some(),
            st: Mutex::new(st),
            after_spawn: Mutex::new(None),
        };
        (TerminalSession { inner: Arc::new(inner) }, rx)
    }

    /// Test hook: `f` runs on the worker thread between spawning the child and storing it (to race `stop()` there).
    #[doc(hidden)]
    pub fn set_after_spawn_hook(&self, f: impl Fn() + Send + Sync + 'static) {
        *self.inner.after_spawn.lock().unwrap() = Some(Arc::new(f));
    }

    pub fn terminal_id(&self) -> &str {
        &self.inner.terminal_id
    }
    pub fn mode(&self) -> TerminalMode {
        self.inner.mode
    }

    /// Current pty size (cols, rows) as last reported by herdr; `None` before the first frame.
    pub fn size(&self) -> Option<(u32, u32)> {
        self.inner.st.lock().unwrap().last_size
    }

    /// Whether `paste` wraps the text in bracketed-paste markers. True unless a frame carried `ESC[?2004l`
    /// (then false until `ESC[?2004h`).
    pub fn bracketed_paste(&self) -> bool {
        self.inner.st.lock().unwrap().bracketed
    }

    pub fn start(&self) {
        {
            let mut st = self.inner.st.lock().unwrap();
            if st.started || st.stopped {
                return;
            }
            st.started = true;
        }
        let inner = self.inner.clone();
        thread::spawn(move || {
            let attempt = Arc::new(Mutex::new(0u32));
            while !inner.stopped() {
                let a2 = attempt.clone();
                let outcome = run_once(&inner, move || *a2.lock().unwrap() = 0);
                if matches!(outcome, Outcome::Final) || inner.stopped() {
                    break;
                }
                let n = {
                    let mut a = attempt.lock().unwrap();
                    *a += 1;
                    *a
                };
                inner.emit(TerminalEvent::Reconnecting { attempt: n });
                if inner.sleep_unless_stopped((250u64 << (n - 1).min(3)).min(2000)) {
                    break;
                }
            }
            inner.finish();
        });
    }

    // MARK: input (control mode)

    /// Raw bytes to the program: text, control keys, escape sequences, any UTF-8. False when not connected or observing.
    pub fn send_bytes(&self, bytes: &[u8]) -> bool {
        if bytes.is_empty() {
            return true;
        }
        self.inner.write_json(json!({"type": "terminal.input", "bytes": base64::engine::general_purpose::STANDARD.encode(bytes)}))
    }

    pub fn send_text(&self, text: &str) -> bool {
        self.send_bytes(text.as_bytes())
    }

    /// Pastes text. Wrapped in bracketed paste (default: `bracketed_paste()`); otherwise newlines become CR.
    /// Bracketed paste drops every ESC from the text (as Alacritty does): an `ESC[201~` inside would end the paste early
    /// and the rest would run as typed input.
    pub fn paste(&self, text: &str, bracketed: Option<bool>) -> bool {
        if self.inner.mode == TerminalMode::Observe {
            return false;
        }
        if bracketed.unwrap_or_else(|| self.bracketed_paste()) {
            return self.send_text(&format!("\u{1b}[200~{}\u{1b}[201~", text.replace('\u{1b}', "")));
        }
        self.send_text(&text.replace("\r\n", "\r").replace('\n', "\r"))
    }

    /// Resizes the pty (control mode). Kept for reconnects. Ignores values below 1.
    pub fn resize(&self, cols: usize, rows: usize) {
        if cols == 0 || rows == 0 {
            return;
        }
        {
            let mut st = self.inner.st.lock().unwrap();
            st.want_cols = Some(cols);
            st.want_rows = Some(rows);
        }
        self.inner.write_json(json!({"type": "terminal.resize", "cols": cols, "rows": rows}));
    }

    /// One wheel step for the terminal, control mode only (observe returns false and sends nothing). herdr decides where it
    /// goes from the program's current mode. A forwarded step is one event per call whatever `lines` is; pass
    /// `event_per_line` to send `lines` separate steps.
    pub fn wheel(&self, lines: usize, up: bool, event_per_line: bool) -> bool {
        if self.inner.mode == TerminalMode::Observe || lines == 0 {
            return false;
        }
        let dir = if up { "up" } else { "down" };
        if event_per_line {
            let mut ok = true;
            for _ in 0..lines {
                ok = self.inner.write_json(json!({"type": "terminal.scroll", "lines": 1, "direction": dir})) && ok;
            }
            return ok;
        }
        self.inner.write_json(json!({"type": "terminal.scroll", "lines": lines, "direction": dir}))
    }

    /// Right click (press and release) at a 1-based cell. Control mode only. Sends the xterm mouse bytes as plain input:
    /// `ESC[<2;col;rowM` + `ESC[<2;col;rowm` (SGR) or `ESC[M` + 3 bytes (legacy; col and row must be <= 223).
    /// False in observe mode or for an invalid cell.
    pub fn right_click(&self, col: usize, row: usize, encoding: MouseEncoding) -> bool {
        if self.inner.mode == TerminalMode::Observe || col < 1 || row < 1 {
            return false;
        }
        match encoding {
            MouseEncoding::Sgr => self.send_text(&format!("\u{1b}[<2;{col};{row}M\u{1b}[<2;{col};{row}m")),
            MouseEncoding::Legacy => {
                if col > 223 || row > 223 {
                    return false;
                }
                let (c, r) = (32 + col as u8, 32 + row as u8);
                self.send_bytes(&[0x1b, 0x5b, 0x4d, 34, c, r, 0x1b, 0x5b, 0x4d, 35, c, r])
            }
        }
    }

    /// Gives the input back (the pty returns to the other client's size) and ends the stream.
    pub fn release(&self) {
        self.inner.st.lock().unwrap().stopped = true;
        self.inner.write_json(json!({"type": "terminal.release"}));
        // the process answers closed(detached) and exits; stop() is the fallback if it does not
        let inner = self.inner.clone();
        thread::spawn(move || {
            thread::sleep(Duration::from_secs(2));
            inner.stop();
        });
    }

    /// Ends the session without telling herdr (the process is killed).
    pub fn stop(&self) {
        self.inner.stop();
    }

    /// Writes one raw line to the child's stdin. Test hook (the fake script reacts to it).
    pub fn send_raw(&self, line: &str) {
        let mut d = line.as_bytes().to_vec();
        d.push(b'\n');
        self.inner.write(&d);
    }
}

impl Drop for TerminalSession {
    fn drop(&mut self) {
        self.inner.stop();
    }
}

fn handle_line(inner: &Inner, line: &[u8], final_reason: &Mutex<Option<String>>, on_frame: &dyn Fn()) {
    let Ok(Value::Object(o)) = serde_json::from_slice::<Value>(line) else { return };
    match o.get("type").and_then(Value::as_str) {
        Some("terminal.frame") => {
            let bytes = o
                .get("bytes")
                .and_then(Value::as_str)
                .and_then(|s| base64::engine::general_purpose::STANDARD.decode(s).ok())
                .unwrap_or_default();
            let num = |k: &str| o.get(k).and_then(Value::as_i64).unwrap_or(0);
            let f = TerminalFrame { seq: num("seq"), full: o.get("full").and_then(Value::as_bool).unwrap_or(false), width: num("width").max(0) as u32, height: num("height").max(0) as u32, bytes };
            {
                let mut st = inner.st.lock().unwrap();
                if f.width > 0 && f.height > 0 {
                    st.last_size = Some((f.width, f.height));
                }
                let on = rfind(&f.bytes, b"\x1b[?2004h");
                let off = rfind(&f.bytes, b"\x1b[?2004l");
                if let Some(on) = on {
                    if off.map(|o| o < on).unwrap_or(true) {
                        st.bracketed = true;
                    } else if find(&f.bytes, b"\x1b[?2004l").is_some() {
                        st.bracketed = false;
                    }
                } else if off.is_some() {
                    st.bracketed = false;
                }
            }
            on_frame();
            inner.emit(TerminalEvent::Frame(f));
        }
        Some("terminal.closed") => {
            let r = o.get("reason").and_then(Value::as_str).unwrap_or("").to_string();
            *final_reason.lock().unwrap() = Some(r.clone());
            inner.emit(TerminalEvent::Closed { reason: r });
        }
        _ => {}
    }
}

fn run_once(inner: &Arc<Inner>, on_frame: impl Fn() + Send + 'static) -> Outcome {
    let (cols, rows) = {
        let st = inner.st.lock().unwrap();
        (st.want_cols, st.want_rows)
    };
    let mut cmd = Command::new(&inner.argv_prefix[0]);
    cmd.args(&inner.argv_prefix[1..]);
    cmd.args(["terminal", "session", if inner.mode == TerminalMode::Observe { "observe" } else { "control" }, &inner.terminal_id]);
    if inner.mode == (TerminalMode::Control { takeover: true }) {
        cmd.arg("--takeover");
    }
    if let Some(c) = cols {
        cmd.args(["--cols", &c.to_string()]);
    }
    if let Some(r) = rows {
        cmd.args(["--rows", &r.to_string()]);
    }
    if inner.strip_herdr_env {
        for (k, _) in std::env::vars_os() {
            if k.to_string_lossy().starts_with("HERDR_") {
                cmd.env_remove(&k);
            }
        }
    }
    #[cfg(unix)]
    {
        let mut paths: Vec<std::path::PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
        paths.push("/opt/homebrew/bin".into());
        paths.push("/usr/local/bin".into());
        if let Ok(p) = std::env::join_paths(paths) {
            cmd.env("PATH", p);
        }
    }
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            inner.emit(TerminalEvent::Notice(format!("cannot start herdr: {e}")));
            return Outcome::Final;
        }
    };
    let hook = inner.after_spawn.lock().unwrap().clone();
    if let Some(h) = hook {
        h();
    }
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    {
        let mut st = inner.st.lock().unwrap();
        st.stdin = child.stdin.take();
        st.child = Some(child);
        if st.killed {
            // stop() ran between spawn and here and found no child to kill: kill it now (release() alone does not kill)
            st.stdin = None;
            if let Some(mut c) = st.child.take() {
                let _ = c.kill();
                thread::spawn(move || {
                    let _ = c.wait();
                });
            }
        }
    }
    if inner.st.lock().unwrap().killed {
        return Outcome::Final;
    }
    let final_reason = Arc::new(Mutex::new(None::<String>));
    let err_inner = inner.clone();
    let err_t = thread::spawn(move || {
        for line in BufReader::new(stderr).split(b'\n').map_while(Result::ok) {
            if let Ok(s) = String::from_utf8(line) {
                if !s.is_empty() {
                    err_inner.emit(TerminalEvent::Notice(s));
                }
            }
        }
    });
    // stdout until EOF
    for line in BufReader::new(stdout).split(b'\n').map_while(Result::ok) {
        handle_line(inner, &line, &final_reason, &on_frame);
    }
    // the process must end too
    loop {
        let mut st = inner.st.lock().unwrap();
        match st.child.as_mut() {
            None => break,
            Some(c) => match c.try_wait() {
                Ok(Some(_)) | Err(_) => {
                    st.child = None;
                    break;
                }
                Ok(None) => {}
            },
        }
        drop(st);
        thread::sleep(Duration::from_millis(5));
    }
    {
        let mut st = inner.st.lock().unwrap();
        st.stdin = None;
    }
    let _ = err_t.join();
    if final_reason.lock().unwrap().is_some() {
        Outcome::Final
    } else {
        Outcome::Retry
    }
}
