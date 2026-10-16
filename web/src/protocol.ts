// Remote protocol v1 (docs/design/remote-protocol.md): the shapes the PWA reads and sends. Types only.

export type Status = "idle" | "working" | "blocked" | "done" | "unknown";
export type Level = "read" | "input";

export interface Agent { name: string; kind: string; status: Status; session?: string; title: string }
export interface Pane { id: string; cwd: string; label?: string; agent?: Agent }
export interface Tab { id: string; label: string; number: number; status: Status; panes: Pane[] }
export interface Workspace { id: string; label: string; tabs: Tab[] }

export interface Approval { id: string; tool: string; title: string; command: string; state: "pending" | "resolved" }
export interface Option { label: string; detail?: string; recommended?: boolean }
export interface Question { id: string; header: string; text: string; multiSelect: boolean; options: Option[] }
export interface QuestionRequest {
  id: string; agent: string; delivery: "picker" | "message"; state: "pending" | "answered" | "declined";
  headers: string[]; questions: Question[]; answers?: string[];
  /** Only the Mac answers it (read from the screen, not from the agent's log). */
  onMac?: boolean;
}
export interface ToolCall { id: string; tool: string; summary: string; done: boolean; error: boolean }
export interface ToolChip { symbol: string; text: string; calls: ToolCall[] }

export type Item =
  | { id: string; time?: string; kind: "user" | "assistant" | "status"; text: string }
  | { id: string; time?: string; kind: "tools"; tools: ToolChip[] }
  | { id: string; time?: string; kind: "approval"; approval: Approval }
  | { id: string; time?: string; kind: "question"; question: QuestionRequest };

export interface HubError { code: string; message?: string }
export interface Device { id: string; name: string; level: Level }

export type HubMessage =
  | { type: "paired"; token: string; device: Device }
  | { type: "welcome"; hub: string; hubVersion: string; level: Level; session?: string; pushKey?: string; pushOn?: boolean }
  | { type: "reply"; re: string; ok: boolean; error?: HubError }
  | { type: "snapshot"; workspaces: Workspace[] }
  | { type: "status"; pane: string; status: Status }
  | { type: "conversation"; pane: string; session: string; mode: "replace" | "append" | "prepend"; items: Item[]; hasEarlier: boolean }
  | { type: "screen"; pane: string; text: string }
  | { type: "prompt"; pane: string; approval?: Approval; question?: QuestionRequest }
  | { type: "queued"; pane: string; agent: string; items: (string | null)[]; pullable: boolean; pullsAll: boolean }
  | { type: "pulled"; pane: string; text: string; interrupted: boolean }
  | { type: "pong" };

/** The agent's own queue: messages typed while it works, not taken yet. A null item: its text is not readable yet. */
export interface Queue { agent: string; items: (string | null)[]; pullable: boolean; pullsAll: boolean }

export interface Answer { picks: number[]; other?: string }
