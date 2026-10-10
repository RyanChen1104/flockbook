//! Deterministic demo data. Neutral names, no real sessions, no sockets.
//!
//! 6 workspaces, 16 tabs: 6 working, 2 blocked, 5 done, 3 idle. The default selection of the snapshot is
//! Quarry / ranking, whose conversation is long and mixed (bubbles, prose, headings, lists, a table, code, tool
//! chips, CJK).

use crate::source::DataSource;
use herdr_core::{Agent, AgentStatus, ConversationItem, ItemKind, Pane, Tab, ToolCall, ToolChip, Workspace};
use herdr_core::PermState;
use std::collections::HashMap;

pub struct DemoSource {
    workspaces: Vec<Workspace>,
    conversations: HashMap<String, Vec<ConversationItem>>,
}

/// (workspace, [(tab label, agent name, status)]).
const TREE: &[(&str, &[(&str, &str, AgentStatus)])] = &[
    ("Orchard", &[("cart drawer", "orchard-ui-dev", AgentStatus::Working), ("pricing", "orchard-api-dev", AgentStatus::Done), ("e2e", "orchard-e2e-dev", AgentStatus::Done)]),
    ("Atlas", &[("backfill", "atlas-backfill-dev", AgentStatus::Working), ("schema", "atlas-schema-dev", AgentStatus::Working), ("importer", "atlas-import-dev", AgentStatus::Done)]),
    ("Harbor", &[("deploy", "harbor-deploy-ops", AgentStatus::Blocked), ("ci", "harbor-ci-dev", AgentStatus::Done), ("runbook", "harbor-runbook-docs", AgentStatus::Idle)]),
    ("Lighthouse", &[("getting started", "lighthouse-start-docs", AgentStatus::Blocked), ("api ref", "lighthouse-api-docs", AgentStatus::Idle)]),
    ("Tidepool", &[("parser", "tidepool-parse-dev", AgentStatus::Working), ("release", "tidepool-release-dev", AgentStatus::Idle)]),
    ("Quarry", &[("ranking", "quarry-rank-dev", AgentStatus::Working), ("bench", "quarry-bench-perf", AgentStatus::Working), ("notes", "quarry-notes-docs", AgentStatus::Done)]),
];

fn item(id: &str, kind: ItemKind, ts: f64) -> ConversationItem {
    ConversationItem { id: id.into(), kind, timestamp: Some(ts) }
}

fn chip(id: &str, symbol: &str, text: &str, tool: &str, summary: &str, output: Option<&str>) -> ToolChip {
    ToolChip {
        id: id.into(),
        symbol: symbol.into(),
        text: text.into(),
        calls: vec![ToolCall { id: format!("{id}-c"), tool_name: tool.into(), summary: summary.into(), input: summary.into(), output: output.map(Into::into), is_error: false }],
    }
}

const BASE_TS: f64 = 1_790_000_000.0;

fn ranking_conversation() -> Vec<ConversationItem> {
    use ItemKind::*;
    vec![
        item("u1", UserText("Search ranks the old bestseller above the new listing. Can you find out why?".into()), BASE_TS),
        item("c1", ToolChips(vec![chip("c1a", "doc.text", "Read 6 files", "Read", "src/ranking/score.py", Some("ok")), chip("c1b", "terminal", "Ran 2 commands", "Bash", "pytest tests/ranking -q", Some("14 passed"))]), BASE_TS + 20.0),
        item(
            "a1",
            AssistantText(
                "The cause is clear in the table below: clicks are summed with no decay, so a 2-year-old listing with 912 clicks beats a better match from this week.\n\n\
                 ## Proposal\n\n\
                 1. Use `log1p(clicks)` so popularity cannot dominate.\n\
                 2. Decay clicks with a 30-day half-life.\n\
                 3. Keep the BM25 weight at 0.8.\n\n\
                 ```python\n\
                 def score(doc, bm25, now):\n    age_days = (now - doc.created).days\n    fresh = 0.5 ** (age_days / 30)\n    return bm25 * 0.8 + math.log1p(doc.clicks * fresh) * 0.2\n\
                 ```"
                    .into(),
            ),
            BASE_TS + 80.0,
        ),
        item("u2", UserText("Try it and show me the same query.".into()), BASE_TS + 400.0),
        item("c2", ToolChips(vec![chip("c2a", "pencil", "Edited a file", "Edit", "src/ranking/score.py", Some("ok")), chip("c2b", "terminal", "Ran a command", "Bash", "python -m ranking.query \"gala apples\"", Some("3 rows"))]), BASE_TS + 420.0),
        item(
            "a2",
            AssistantText(
                "The new-season listing is first now, and the old bestseller still ranks second on relevance.\n\n\
                 | Listing | Rank before | Rank after |\n|---|---|---|\n\
                 | Gala apples, new season | 3 | **1** |\n| Gala apples, 10 kg (2024) | 1 | 2 |\n| Royal Gala, organic | 4 | 3 |\n\n\
                 Next I'll replay last week's query log to check the change does not hurt long queries."
                    .into(),
            ),
            BASE_TS + 460.0,
        ),
        item("u3", UserText("好，請再用中文總結一次結果，並列出風險。".into()), BASE_TS + 600.0),
        item(
            "a3",
            AssistantText(
                "結果摘要：新上架的商品現在排第一，舊的暢銷商品仍然排第二。\n\n\
                 ### 風險\n\n\
                 - 長尾查詢可能受到 *衰減* 影響，需要用上週的查詢紀錄重放驗證。\n\
                 - `half_life_days` 設為 30 只是起點，之後要用 A/B 測試調整。\n\n\
                 Latency stays flat: p95 went from 41 ms to 43 ms."
                    .into(),
            ),
            BASE_TS + 640.0,
        ),
        item("c3", ToolChips(vec![ToolChip { id: "c3a".into(), symbol: "terminal".into(), text: "Running Bash...".into(), calls: vec![ToolCall { id: "c3a-c".into(), tool_name: "Bash".into(), summary: "python -m ranking.replay logs/last-week.jsonl".into(), input: "python -m ranking.replay logs/last-week.jsonl".into(), output: None, is_error: false }] }]), BASE_TS + 660.0),
    ]
}

fn generic_conversation(agent: &str, status: AgentStatus) -> Vec<ConversationItem> {
    use ItemKind::*;
    let mut v = vec![
        item("g-u1", UserText(format!("Please pick up the next task for {agent}.")), BASE_TS),
        item("g-c1", ToolChips(vec![chip("g-c1a", "doc.text", "Read 3 files", "Read", "README.md", Some("ok"))]), BASE_TS + 10.0),
        item("g-a1", AssistantText("I read the notes and the open issues.\n\n- The first task is small and well scoped.\n- I will start there and report back.".into()), BASE_TS + 30.0),
    ];
    match status {
        AgentStatus::Blocked => v.push(item(
            "g-p1",
            ItemKind::PermissionRequest(herdr_core::PermissionRequest {
                title: "Run a command".into(),
                command: "./scripts/deploy.sh --env staging".into(),
                tool_name: "Bash".into(),
                tool_use_id: "toolu_demo".into(),
                state: PermState::Pending,
            }),
            BASE_TS + 50.0,
        )),
        AgentStatus::Done => v.push(item("g-a2", AssistantText("Done. All checks pass and the change is ready for review.".into()), BASE_TS + 60.0)),
        _ => {}
    }
    v
}

impl DemoSource {
    pub fn new() -> DemoSource {
        let mut workspaces = Vec::new();
        let mut conversations = HashMap::new();
        let mut n = 0;
        for (wi, (wname, tabs)) in TREE.iter().enumerate() {
            let mut out = Vec::new();
            for (ti, (label, agent, status)) in tabs.iter().enumerate() {
                n += 1;
                let pane_id = format!("p{n}");
                let session = format!("demo-session-{n}");
                let pane = Pane {
                    id: pane_id.clone(),
                    terminal_id: format!("term_{n}"),
                    cwd: format!("~/{}", wname.to_lowercase()),
                    agent: Some(Agent { name: agent.to_string(), kind: "claude".into(), status: *status, session_id: Some(session), title: label.to_string() }),
                    label: None,
                };
                let conv = if *agent == "quarry-rank-dev" { ranking_conversation() } else { generic_conversation(agent, *status) };
                conversations.insert(pane_id, conv);
                out.push(Tab { id: format!("t{n}"), label: label.to_string(), number: ti as i64 + 1, panes: vec![pane], status: *status });
            }
            workspaces.push(Workspace { id: format!("w{}", wi + 1), label: wname.to_string(), tabs: out });
        }
        DemoSource { workspaces, conversations }
    }

    /// Workspace and tab ids of Quarry / ranking, the demo's default selection.
    pub fn default_selection(&self) -> (String, String) {
        let ws = self.workspaces.iter().find(|w| w.label == "Quarry").expect("demo workspace");
        (ws.id.clone(), ws.tabs[0].id.clone())
    }
}

impl Default for DemoSource {
    fn default() -> Self {
        Self::new()
    }
}

impl DataSource for DemoSource {
    fn label(&self) -> String {
        "demo".into()
    }
    fn workspaces(&self) -> Vec<Workspace> {
        self.workspaces.clone()
    }
    fn connected(&self) -> bool {
        true
    }
    fn conversation(&self, pane: &Pane) -> Vec<ConversationItem> {
        self.conversations.get(&pane.id).cloned().unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use herdr_core::AgentStatus::*;

    #[test]
    fn tree_shape_matches_the_reference() {
        let d = DemoSource::new();
        let ws = d.workspaces();
        assert_eq!(ws.len(), 6);
        let tabs: Vec<_> = ws.iter().flat_map(|w| &w.tabs).collect();
        assert_eq!(tabs.len(), 16);
        assert_eq!(tabs.iter().filter(|t| t.status == Blocked).count(), 2);
        assert_eq!(tabs.iter().filter(|t| t.status == Working).count(), 6);
        assert!(tabs.iter().any(|t| t.status == Done) && tabs.iter().any(|t| t.status == Idle));
    }

    #[test]
    fn ranking_conversation_is_rich() {
        let d = DemoSource::new();
        let (w, t) = d.default_selection();
        let ws = d.workspaces();
        let pane = &ws.iter().find(|x| x.id == w).unwrap().tabs.iter().find(|x| x.id == t).unwrap().panes[0];
        let items = d.conversation(pane);
        assert!(items.iter().any(|i| matches!(i.kind, ItemKind::UserText(_))));
        assert!(items.iter().any(|i| matches!(i.kind, ItemKind::ToolChips(_))));
        assert!(items.iter().any(|i| matches!(&i.kind, ItemKind::AssistantText(s) if s.contains("```"))));
        assert!(items.iter().any(|i| matches!(&i.kind, ItemKind::AssistantText(s) if s.contains("|---|"))));
        assert!(items.iter().any(|i| matches!(&i.kind, ItemKind::AssistantText(s) if s.contains("風險"))));
    }

    #[test]
    fn demo_data_is_public_safe() {
        let d = DemoSource::new();
        let text = format!("{:?}{:?}", d.workspaces(), d.conversations);
        for bad in [concat!("/Us", "ers/"), concat!("lim", "inchen"), concat!("alf", "red"), concat!("thought", "kit")] {
            assert!(!text.to_lowercase().contains(bad));
        }
    }
}
