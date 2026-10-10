//! Data sources. The UI only reads through `DataSource`.
//!
//! `LiveSource` wraps herdr-core's `HerdrStore` and only reads (snapshot + events). `DemoSource` serves fixed,
//! neutral demo data and never opens a socket.

use herdr_core::{ConversationItem, Pane, Workspace};

pub trait DataSource {
    /// Short label for the title or a status line, e.g. "demo" or a session name.
    fn label(&self) -> String;
    fn workspaces(&self) -> Vec<Workspace>;
    fn connected(&self) -> bool;
    /// Conversation of one pane (the agent's session log). Empty when there is none.
    fn conversation(&self, pane: &Pane) -> Vec<ConversationItem>;
    /// True while the pane's log may have older content ("Show earlier"). Sources without paging say false.
    fn can_load_earlier(&self, _pane: &Pane) -> bool {
        false
    }
    /// Loads an older part of the pane's log. Returns true while older content remains.
    fn load_earlier(&self, _pane: &Pane) -> bool {
        false
    }
}

pub use crate::demo::DemoSource;

#[cfg(unix)]
pub use live::LiveSource;

#[cfg(unix)]
mod live {
    use super::DataSource;
    use herdr_core::transport::UnixConnector;
    use herdr_core::store::HerdrStore;
    use herdr_core::{ConversationItem, HerdrSession, Pane, Workspace};
    use std::collections::HashMap;
    use std::path::Path;

    /// The live herdr session. Read-only: `HerdrStore` sends `session.snapshot` and `events.subscribe` only.
    pub struct LiveSource {
        store: HerdrStore<UnixConnector>,
        label: String,
    }

    impl LiveSource {
        /// Session order: `--session NAME`, `HERDR_DESK_SESSION`, the herdr env, then the default session.
        pub fn from_args(args: &[String]) -> LiveSource {
            let env: HashMap<String, String> = std::env::vars().collect();
            let home = std::env::var_os("HOME").map(std::path::PathBuf::from).unwrap_or_default();
            let session = HerdrSession::resolve(args, &env, Path::new(&home));
            let label = session.name.clone().unwrap_or_else(|| "default".to_string());
            let store = HerdrStore::new(&session);
            store.start();
            LiveSource { store, label }
        }
    }

    impl DataSource for LiveSource {
        fn label(&self) -> String {
            self.label.clone()
        }
        fn workspaces(&self) -> Vec<Workspace> {
            self.store.workspaces()
        }
        fn connected(&self) -> bool {
            self.store.connected()
        }
        fn conversation(&self, pane: &Pane) -> Vec<ConversationItem> {
            self.store.conversation(pane.agent.as_ref().and_then(|a| a.session_id.as_deref()))
        }
        fn can_load_earlier(&self, pane: &Pane) -> bool {
            pane.agent.as_ref().is_some_and(|a| a.session_id.is_some())
        }
        fn load_earlier(&self, pane: &Pane) -> bool {
            // Reads an older part of the session log file: no herdr call.
            self.store.load_earlier(pane.agent.as_ref().and_then(|a| a.session_id.as_deref()), 256 * 1024)
        }
    }
}
