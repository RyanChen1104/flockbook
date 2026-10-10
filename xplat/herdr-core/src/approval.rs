//! Keystrokes for Claude Code's permission prompt, and prompt detection on the pane (port of ApprovalKeys.swift and
//! the client part of PermissionGate.swift; the pure `screen_shows_prompt` stays in lib.rs).
//!
//! Verified against Claude Code 2.1.294 in a throwaway test session, manual permission mode, Bash tool: the prompt lists
//! `1. Yes`, `2. Yes, and always allow...`, `3. Yes, and switch to auto mode`, `4. No`. `1` (typed, no Enter) approves once.
//! `Escape` denies. Do NOT use Enter blindly: the folder-trust dialog highlights "No, exit" by default. The number of options
//! changes with the prompt type, so deny uses Escape, never a number.
//!
//! `respond` sends input to a pane: live use is for the `c9-input-test` session only.

use crate::client::HerdrClient;
use crate::error::HerdrError;
use crate::screen_shows_prompt;
use crate::transport::Connector;
use serde_json::{json, Value};

pub const ALLOW_ONCE: &str = "1";
pub const DENY: &str = "Escape";

impl<C: Connector> HerdrClient<C> {
    /// Named keys such as "Enter", "Down", "Escape", "C-c".
    pub fn send_named_keys(&self, keys: &[&str], pane_id: &str) -> Result<(), HerdrError> {
        self.raw_request("pane.send_keys", json!({"pane_id": pane_id, "keys": keys})).map(|_| ())
    }

    /// Answer a permission prompt in `pane_id`. Call only when the agent is `blocked` on a prompt.
    pub fn respond(&self, pane_id: &str, allow: bool) -> Result<(), HerdrError> {
        if allow {
            self.raw_request("pane.send_text", json!({"pane_id": pane_id, "text": ALLOW_ONCE})).map(|_| ())
        } else {
            self.send_named_keys(&[DENY], pane_id)
        }
    }

    /// Read-only: does the pane's visible screen show a permission prompt right now?
    pub fn check_prompt(&self, pane_id: &str) -> bool {
        let Ok(data) = self.raw_request("pane.read", json!({"pane_id": pane_id, "source": "visible", "format": "text", "lines": 40})) else {
            return false;
        };
        let Ok(o) = serde_json::from_slice::<Value>(&data) else { return false };
        o.pointer("/result/read/text").and_then(Value::as_str).map(screen_shows_prompt).unwrap_or(false)
    }
}
