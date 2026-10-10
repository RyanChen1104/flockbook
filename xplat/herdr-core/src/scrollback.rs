//! Scroll state and terminal history (port of Scrollback.swift).
//!
//! `read_scrollback` is read-only. `set_scroll_offset` and `read_deep_history` move the pane's shared scroll position:
//! live use is for the `c9-input-test` session only, tests use the fake.

use crate::client::HerdrClient;
use crate::error::HerdrError;
use crate::transport::Connector;
use serde_json::{json, Value};

/// Where a pane stands for scrolling. From `pane.get` (scroll) and `pane.process_info` (foreground program).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScrollInfo {
    pub max_offset_from_bottom: i64,
    pub offset_from_bottom: i64,
    pub viewport_rows: i64,
    /// Name of the foreground program (`zsh`, `less`, `claude`). `None` when unknown.
    pub foreground_name: Option<String>,
    /// True when the shell itself is in the foreground. `None` when unknown.
    pub shell_is_foreground: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScrollKind {
    /// herdr holds scrollback lines: show them (`read_scrollback`), the wheel never goes to the program.
    History,
    /// No scrollback and a program other than the shell runs (less, vim, htop on the alternate screen). The program scrolls itself.
    FullScreenProgram,
    /// Nothing to scroll (fresh shell). Do not send anything.
    None,
}

fn proto(m: &str) -> HerdrError {
    HerdrError::Protocol(m.into())
}

impl ScrollInfo {
    pub fn kind(&self) -> ScrollKind {
        if self.max_offset_from_bottom > 0 {
            return ScrollKind::History;
        }
        if self.shell_is_foreground == Some(false) {
            ScrollKind::FullScreenProgram
        } else {
            ScrollKind::None
        }
    }

    pub fn parse(pane: &[u8], process: Option<&[u8]>) -> Result<ScrollInfo, HerdrError> {
        let o: Value = serde_json::from_slice(pane).map_err(|_| proto("pane.get has no scroll info"))?;
        let sc = o.pointer("/result/pane/scroll").and_then(Value::as_object).ok_or_else(|| proto("pane.get has no scroll info"))?;
        let n = |k: &str| sc.get(k).and_then(Value::as_i64).unwrap_or(0);
        let mut info = ScrollInfo {
            max_offset_from_bottom: n("max_offset_from_bottom"),
            offset_from_bottom: n("offset_from_bottom"),
            viewport_rows: n("viewport_rows"),
            foreground_name: None,
            shell_is_foreground: None,
        };
        if let Some(po) = process.and_then(|p| serde_json::from_slice::<Value>(p).ok()) {
            if let Some(pi) = po.pointer("/result/process_info").and_then(Value::as_object) {
                let empty = Vec::new();
                let fg = pi.get("foreground_processes").and_then(Value::as_array).unwrap_or(&empty);
                info.foreground_name = fg.first().and_then(|f| f.get("name")).and_then(Value::as_str).map(str::to_string);
                if let Some(shell) = pi.get("shell_pid").and_then(Value::as_i64) {
                    info.shell_is_foreground = if fg.is_empty() { None } else { Some(fg.iter().any(|f| f.get("pid").and_then(Value::as_i64) == Some(shell))) };
                }
            }
        }
        Ok(info)
    }
}

/// Terminal history as text. `ansi` text keeps SGR colors and uses CRLF line ends.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scrollback {
    pub text: String,
    /// herdr cut the history (it holds more than was returned).
    pub truncated: bool,
    pub revision: i64,
    pub line_count: usize,
}

impl Scrollback {
    /// Most lines one `pane.read` returns (herdr 0.9.1).
    pub const READ_LIMIT: usize = 1000;

    pub fn parse(data: &[u8]) -> Result<Scrollback, HerdrError> {
        let o: Value = serde_json::from_slice(data).map_err(|_| proto("pane.read has no text"))?;
        let r = o.pointer("/result/read").and_then(Value::as_object).ok_or_else(|| proto("pane.read has no text"))?;
        let text = r.get("text").and_then(Value::as_str).ok_or_else(|| proto("pane.read has no text"))?.to_string();
        let mut n = text.bytes().filter(|b| *b == b'\n').count();
        if text.as_bytes().last().is_some_and(|b| *b != b'\n') {
            n += 1;
        }
        Ok(Scrollback {
            truncated: r.get("truncated").and_then(Value::as_bool).unwrap_or(false),
            revision: r.get("revision").and_then(Value::as_i64).unwrap_or(0),
            line_count: n,
            text,
        })
    }
}

impl<C: Connector> HerdrClient<C> {
    /// Scroll state of a pane. Two read-only requests.
    pub fn scroll_info(&self, pane_id: &str) -> Result<ScrollInfo, HerdrError> {
        let pane = self.raw_request("pane.get", json!({"pane_id": pane_id}))?;
        let proc = self.raw_request("pane.process_info", json!({"pane_id": pane_id})).ok();
        ScrollInfo::parse(&pane, proc.as_deref())
    }

    /// The last `lines` lines of the terminal buffer (scrollback plus visible rows). herdr returns at most
    /// `Scrollback::READ_LIMIT` lines; `truncated` says more exist. Read-only.
    pub fn read_scrollback(&self, pane_id: &str, lines: usize, ansi: bool, unwrapped: bool) -> Result<Scrollback, HerdrError> {
        Scrollback::parse(&self.raw_request(
            "pane.read",
            json!({"pane_id": pane_id, "source": if unwrapped { "recent_unwrapped" } else { "recent" }, "lines": lines.max(1),
                   "format": if ansi { "ansi" } else { "text" }, "strip_ansi": !ansi}),
        )?)
    }

    /// Moves the pane's scroll position (0 = bottom). Shared state: every client of that pane sees it. Sends no input.
    pub fn set_scroll_offset(&self, pane_id: &str, from_bottom: i64) -> Result<(), HerdrError> {
        self.raw_request("pane.scroll", json!({"pane_id": pane_id, "offset_from_bottom": from_bottom.max(0)})).map(|_| ())
    }

    /// History deeper than `Scrollback::READ_LIMIT`: moves the pane's scroll position one screen at a time and reads each
    /// screen, then puts the position back. Not read-only for a moment (other clients see the pane scroll).
    pub fn read_deep_history(&self, pane_id: &str, lines: usize, ansi: bool) -> Result<Scrollback, HerdrError> {
        // Output arriving during the read shifts every page; a pass that saw buffer growth is repeated (up to 3 times).
        let mut result = None;
        for _ in 0..3 {
            let before = self.scroll_info(pane_id)?;
            result = Some(self.deep_pass(pane_id, lines, ansi, &before)?);
            let after = self.scroll_info(pane_id)?;
            if after.max_offset_from_bottom == before.max_offset_from_bottom {
                break;
            }
        }
        Ok(result.expect("at least one pass"))
    }

    fn deep_pass(&self, pane_id: &str, lines: usize, ansi: bool, info: &ScrollInfo) -> Result<Scrollback, HerdrError> {
        let rows = info.viewport_rows.max(1);
        let want_top = info.max_offset_from_bottom.min((lines as i64 - rows).max(0));
        let mut out: Vec<String> = Vec::new();
        let mut offset = want_top;
        let mut revision = 0;
        let mut previous: Option<i64> = None;
        let body = (|| -> Result<(), HerdrError> {
            loop {
                self.set_scroll_offset(pane_id, offset)?;
                let page = Scrollback::parse(&self.raw_request(
                    "pane.read",
                    json!({"pane_id": pane_id, "source": "visible", "format": if ansi { "ansi" } else { "text" }, "strip_ansi": !ansi}),
                )?)?;
                revision = page.revision;
                let mut ls: Vec<String> = page.text.split('\n').map(str::to_string).collect();
                if ls.last().map(String::as_str) == Some("") {
                    ls.pop();
                }
                if let Some(prev) = previous {
                    let skip = (rows + offset - prev).max(0) as usize; // the last step can overlap
                    ls = ls.into_iter().skip(skip).collect();
                }
                out.extend(ls);
                previous = Some(offset);
                if offset == 0 {
                    return Ok(());
                }
                offset = (offset - rows).max(0);
            }
        })();
        if let Err(e) = body {
            let _ = self.set_scroll_offset(pane_id, info.offset_from_bottom);
            return Err(e);
        }
        self.set_scroll_offset(pane_id, info.offset_from_bottom)?;
        Ok(Scrollback { line_count: out.len(), text: out.join("\n"), truncated: info.max_offset_from_bottom > want_top, revision })
    }
}
