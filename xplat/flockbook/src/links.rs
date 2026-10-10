//! Opening links. The app never spawns a process itself: it asks a [`LinkOpener`].
//!
//! `App::new` installs a [`RecordingOpener`], which only remembers the URLs. Tests and snapshots therefore never
//! start a browser. `main.rs` installs [`SystemOpener`] for a real window.

use std::cell::RefCell;

pub trait LinkOpener {
    /// Opens `url`. Only called for allowed schemes (see [`allowed`]).
    fn open(&self, url: &str);
    /// URLs this opener has been asked to open (recording openers only).
    fn recorded(&self) -> Vec<String> {
        Vec::new()
    }
}

/// Schemes the app opens. Anything else (file:, javascript:, custom schemes) is dropped.
pub fn allowed(url: &str) -> bool {
    ["http://", "https://", "mailto:"].iter().any(|p| url.starts_with(p))
}

/// Remembers the URLs and does nothing else.
#[derive(Default)]
pub struct RecordingOpener {
    urls: RefCell<Vec<String>>,
}

impl LinkOpener for RecordingOpener {
    fn open(&self, url: &str) {
        self.urls.borrow_mut().push(url.to_string());
    }
    fn recorded(&self) -> Vec<String> {
        self.urls.borrow().clone()
    }
}

/// Hands the URL to the operating system (`open`, `xdg-open`, `rundll32`).
pub struct SystemOpener;

impl LinkOpener for SystemOpener {
    fn open(&self, url: &str) {
        #[cfg(target_os = "macos")]
        let cmd = ("open", vec![url.to_string()]);
        #[cfg(target_os = "windows")]
        let cmd = ("rundll32", vec!["url.dll,FileProtocolHandler".to_string(), url.to_string()]);
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        let cmd = ("xdg-open", vec![url.to_string()]);
        let _ = std::process::Command::new(cmd.0).args(&cmd.1).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).spawn();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_web_and_mail_schemes_are_allowed() {
        assert!(allowed("https://example.com") && allowed("http://a.b") && allowed("mailto:a@b.c"));
        assert!(!allowed("file:///etc/passwd") && !allowed("javascript:alert(1)") && !allowed("ssh://x"));
    }

    #[test]
    fn recording_opener_records() {
        let r = RecordingOpener::default();
        r.open("https://example.com");
        assert_eq!(r.recorded(), vec!["https://example.com".to_string()]);
    }
}
