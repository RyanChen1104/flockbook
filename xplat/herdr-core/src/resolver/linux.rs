//! Linux process source: plain file reads under a proc root (`/proc` by default). No libc calls, so it compiles
//! (and is tested against a synthetic tree) on every platform.

use super::{Proc, ProcessSource};
use std::path::PathBuf;

pub struct LinuxProcSource {
    root: PathBuf,
    /// Clock ticks per second (`USER_HZ`). It is 100 on every mainstream Linux build.
    ticks_per_sec: f64,
}

impl LinuxProcSource {
    pub fn new() -> Self {
        Self::with_root(PathBuf::from("/proc"))
    }

    pub fn with_root(root: PathBuf) -> Self {
        LinuxProcSource { root, ticks_per_sec: 100.0 }
    }

    fn boot_time(&self) -> Option<f64> {
        let s = std::fs::read_to_string(self.root.join("stat")).ok()?;
        s.lines().find_map(|l| l.strip_prefix("btime ")?.trim().parse().ok())
    }
}

impl Default for LinuxProcSource {
    fn default() -> Self {
        Self::new()
    }
}

/// `(ppid, starttime in clock ticks since boot)` from `/proc/<pid>/stat`. The command name sits in parentheses and
/// may hold spaces and parentheses, so the fields are counted after the last `)`.
pub fn parse_linux_stat(text: &str) -> Option<(i32, u64)> {
    let rest = &text[text.rfind(')')? + 1..];
    let f: Vec<&str> = rest.split_whitespace().collect();
    // f[0] = state (field 3), f[1] = ppid (field 4), f[19] = starttime (field 22)
    Some((f.get(1)?.parse().ok()?, f.get(19)?.parse().ok()?))
}

fn nul_to_space(bytes: &[u8]) -> String {
    let s = String::from_utf8_lossy(bytes);
    s.split('\0').filter(|p| !p.is_empty()).collect::<Vec<_>>().join(" ")
}

impl ProcessSource for LinuxProcSource {
    fn processes(&self) -> Vec<Proc> {
        let boot = self.boot_time().unwrap_or(0.0);
        let Ok(rd) = std::fs::read_dir(&self.root) else { return Vec::new() };
        let mut out = Vec::new();
        for e in rd.flatten() {
            let Ok(pid) = e.file_name().to_string_lossy().parse::<i32>() else { continue };
            let dir = e.path();
            let Some((ppid, ticks)) = std::fs::read_to_string(dir.join("stat")).ok().and_then(|s| parse_linux_stat(&s)) else { continue };
            // Another user's environ is unreadable: the process is listed but carries no pane env.
            let cmd = std::fs::read(dir.join("cmdline")).map(|b| nul_to_space(&b)).unwrap_or_default();
            let env = std::fs::read(dir.join("environ")).map(|b| nul_to_space(&b)).unwrap_or_default();
            out.push(Proc { pid, ppid, start: boot + ticks as f64 / self.ticks_per_sec, line: format!("{cmd} {env}") });
        }
        out
    }

    fn open_files(&self, pids: &[i32]) -> Vec<String> {
        let mut out = Vec::new();
        for pid in pids {
            let Ok(rd) = std::fs::read_dir(self.root.join(pid.to_string()).join("fd")) else { continue };
            for e in rd.flatten() {
                if let Ok(target) = std::fs::read_link(e.path()) {
                    let t = target.to_string_lossy().into_owned();
                    if t.starts_with('/') {
                        out.push(t);
                    }
                }
            }
        }
        out
    }
}
