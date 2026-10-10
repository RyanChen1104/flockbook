//! Windows process source on the `sysinfo` crate.
//!
//! NOT COMPILED OR RUN on the dev host (only the macOS target is installed). It is kept short on purpose.
//! Windows cannot list a process's open files cheaply, so `open_files` is empty and the resolver falls back to the
//! Codex cwd + start-time match, which needs only the process start time.

use super::{Proc, ProcessSource};
use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};

pub struct WindowsProcessSource;

impl ProcessSource for WindowsProcessSource {
    fn processes(&self) -> Vec<Proc> {
        let mut sys = System::new();
        let kind = ProcessRefreshKind::new().with_cmd(UpdateKind::Always).with_environ(UpdateKind::Always);
        sys.refresh_processes_specifics(ProcessesToUpdate::All, true, kind);
        let join = |v: &[std::ffi::OsString]| v.iter().map(|s| s.to_string_lossy().into_owned()).collect::<Vec<_>>().join(" ");
        sys.processes()
            .values()
            .map(|p| Proc {
                pid: p.pid().as_u32() as i32,
                ppid: p.parent().map_or(0, |q| q.as_u32() as i32),
                start: p.start_time() as f64,
                // command line, then KEY=VALUE pairs: the same shape as `ps -E`
                line: format!("{} {}", join(p.cmd()), join(p.environ())),
            })
            .collect()
    }

    fn open_files(&self, _pids: &[i32]) -> Vec<String> {
        Vec::new()
    }
}
