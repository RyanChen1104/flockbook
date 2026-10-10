//! Shared app state. Every module owns one state struct in its own file and registers ONE field here.

use crate::source::DataSource;
use fb_ui::{Mode, StatusKind};
use herdr_core::{AgentStatus, ConversationItem, Pane, Tab, Workspace};
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Screen {
    #[default]
    Conversation,
    Overview,
    /// Stub until step 3.
    NeedsYou,
    /// Stub until step 3.
    Search,
}

impl Screen {
    pub fn parse(s: &str) -> Option<Screen> {
        match s {
            "conversation" => Some(Screen::Conversation),
            "overview" => Some(Screen::Overview),
            "needs-you" => Some(Screen::NeedsYou),
            "search" => Some(Screen::Search),
            _ => None,
        }
    }
}

pub fn status_kind(s: AgentStatus) -> StatusKind {
    match s {
        AgentStatus::Working => StatusKind::Working,
        AgentStatus::Blocked => StatusKind::Blocked,
        AgentStatus::Done => StatusKind::Done,
        AgentStatus::Idle | AgentStatus::Unknown => StatusKind::Idle,
    }
}

/// Status counts of one workspace.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Counts {
    pub working: usize,
    pub blocked: usize,
    pub done: usize,
    pub idle: usize,
}

pub struct State {
    pub screen: Screen,
    pub mode: Mode,
    /// Mirror of the source's tree. Refreshed by `App::refresh`.
    pub workspaces: Vec<Workspace>,
    pub selected_workspace: Option<String>,
    pub selected_tab: Option<String>,
    pub selected_pane: Option<String>,
    /// Conversation items per pane id. Filled for the selected pane on `refresh`.
    pub conversations: HashMap<String, Vec<ConversationItem>>,
    pub connected: bool,
    pub session_label: String,

    // One field per module. A builder adds its own state struct in its own file and registers it here.
    pub sidebar: crate::sidebar::SidebarState,
    pub toprow: crate::toprow::TopRowState,
    pub overview: crate::overview::OverviewState,
    pub conversation: crate::conversation::ConversationState,
    pub composer: crate::composer::ComposerState,
}

impl State {
    pub fn new(mode: Mode, screen: Screen) -> State {
        State {
            screen,
            mode,
            workspaces: Vec::new(),
            selected_workspace: None,
            selected_tab: None,
            selected_pane: None,
            conversations: HashMap::new(),
            connected: false,
            session_label: String::new(),
            sidebar: Default::default(),
            toprow: Default::default(),
            overview: Default::default(),
            conversation: Default::default(),
            composer: Default::default(),
        }
    }

    pub fn workspace(&self, id: &str) -> Option<&Workspace> {
        self.workspaces.iter().find(|w| w.id == id)
    }

    pub fn selected_workspace(&self) -> Option<&Workspace> {
        self.selected_workspace.as_deref().and_then(|id| self.workspace(id))
    }

    pub fn selected_tab(&self) -> Option<&Tab> {
        let ws = self.selected_workspace()?;
        let id = self.selected_tab.as_deref()?;
        ws.tabs.iter().find(|t| t.id == id)
    }

    /// The pane the conversation shows: the selected pane, else the tab's first agent pane, else its first pane.
    pub fn selected_pane(&self) -> Option<&Pane> {
        let tab = self.selected_tab()?;
        if let Some(id) = self.selected_pane.as_deref() {
            if let Some(p) = tab.panes.iter().find(|p| p.id == id) {
                return Some(p);
            }
        }
        tab.panes.iter().find(|p| p.agent.is_some()).or_else(|| tab.panes.first())
    }

    pub fn conversation_items(&self) -> &[ConversationItem] {
        self.selected_pane().and_then(|p| self.conversations.get(&p.id)).map(|v| v.as_slice()).unwrap_or(&[])
    }

    pub fn select_workspace(&mut self, id: &str) {
        let Some(ws) = self.workspace(id) else { return };
        // Keep the tab when it already belongs to this workspace; else the first tab, preferring a blocked one.
        let tab = ws.tabs.iter().find(|t| t.status == AgentStatus::Blocked).or_else(|| ws.tabs.first()).map(|t| t.id.clone());
        self.selected_workspace = Some(id.to_string());
        self.selected_tab = tab;
        self.selected_pane = None;
    }

    pub fn select_tab(&mut self, ws: &str, tab: &str) {
        if self.workspace(ws).is_some_and(|w| w.tabs.iter().any(|t| t.id == tab)) {
            self.selected_workspace = Some(ws.to_string());
            self.selected_tab = Some(tab.to_string());
            self.selected_pane = None;
        }
    }

    pub fn counts(ws: &Workspace) -> Counts {
        let mut c = Counts::default();
        for t in &ws.tabs {
            match t.status {
                AgentStatus::Working => c.working += 1,
                AgentStatus::Blocked => c.blocked += 1,
                AgentStatus::Done => c.done += 1,
                _ => c.idle += 1,
            }
        }
        c
    }

    /// Tabs that need the user, as (workspace, tab).
    pub fn blocked_tabs(&self) -> Vec<(&Workspace, &Tab)> {
        self.workspaces.iter().flat_map(|w| w.tabs.iter().filter(|t| t.status == AgentStatus::Blocked).map(move |t| (w, t))).collect()
    }

    pub fn tab_count(&self) -> usize {
        self.workspaces.iter().map(|w| w.tabs.len()).sum()
    }

    /// Pulls the tree and the selected pane's conversation from the source. Keeps the selection when it is still valid.
    pub fn reload(&mut self, source: &dyn DataSource) {
        self.workspaces = source.workspaces();
        self.connected = source.connected();
        let valid = self.selected_tab().is_some();
        if !valid {
            let first = self.selected_workspace.clone().filter(|id| self.workspace(id).is_some()).or_else(|| self.workspaces.first().map(|w| w.id.clone()));
            if let Some(id) = first {
                self.select_workspace(&id);
            }
        }
        if let Some(p) = self.selected_pane().cloned() {
            let items = source.conversation(&p);
            self.conversations.insert(p.id, items);
        }
    }
}

/// Monogram for a workspace chip: the first two letters, upper case.
pub fn monogram(label: &str) -> String {
    label.chars().filter(|c| c.is_alphanumeric()).take(2).collect::<String>().to_uppercase()
}
