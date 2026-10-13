# Question pickers: keys and log behaviour per agent

Researched 2026-10-10 in herdr session `c9-input-test` only (workspace `wB`), with Claude Code 2.1.296 (claude-haiku-5-5) and codex-cli 0.162.1 (GPT-5.6-Luna).
Code: `Sources/HerdrKit/QuestionAdapter.swift`. End-to-end check: `HerdrKitChecks --question-live` (results at the end).

## Summary

| Agent | Tool | Pending question comes from | Answer | End-to-end |
|---|---|---|---|---|
| Claude Code | AskUserQuestion | **the screen**: `pendingQuestion` (read-only) + `loadAllQuestions` (keys, user action only); the log gets the call only after the answer | keys | verified (6 cases) |
| Codex | `request_user_input` (Plan mode only) | the log (`function_call` is written while the picker is open) | keys | verified (3 cases) |
| Codex | `request_user_input_async` | the log (`{"accepted":true}` keeps it pending) | a user message (`send(text:to:)`) | **not verified**: "unavailable" in this Codex setup |
| Cursor | AskQuestion | not supported (no answer in the transcript) | – | – |

herdr reports the agent as `blocked` while a picker is open (Claude and Codex).

Only the picker part of the screen counts (Claude: from the tab bar down; Codex: from "Question k/n" down). The user's prompt above it often repeats the question texts; matching the whole screen made "wait for question 2" pass at once, and the next digit landed on the review screen as Cancel (seen: "User declined to answer questions").

Keys are typed with `pane.send_text` (no Enter). `send(text:to:)` (`pane.send_input` + Enter) is wrong for pickers: a digit + Enter in Codex became a note ("answer: Juice, note: 2").

## Claude Code AskUserQuestion

Important: Claude Code writes the assistant line with the AskUserQuestion `tool_use` to the session JSONL **only when the question is answered** (checked: picker open for 60+ s, no line; the line and its result appear together right after the answer). So `ConversationItem.question` with `.pending` never comes from a Claude log; the card must use `pendingQuestion(paneId:)`, which reads the picker from the screen.

Update 2026-10-13 (2.1.296, c9-input-test): with a PreToolUse hook on AskUserQuestion (`--settings <test file>`), the hook's stdin has `session_id` (= herdr's `agent_session`), `tool_use_id` and `tool_input` before the picker opens, and the assistant line with the `tool_use` was in the log while the picker was still open (no result yet). The hub uses the hook record, not that line (see `ClaudeQuestionHook`).

Screen markers: "Chat about this" (every question screen), "Review your answers" (review screen).

Keys (n = number of options):
- Single choice: digit `k` picks option k. One question: it submits at once. Several: it moves to the next question.
- Single choice, Other: digit `n+1` focuses "Type something.", type the text, `Enter` (submits or moves on).
- multiSelect: digits toggle `[✔]`; the cursor stays on row 1. `Tab` moves on (to the next question, or to the review screen).
- multiSelect, Other: digit `n+1` checks the row, `Down` × n puts the cursor on it, type the text, `Tab` (cursor to the "Submit" row), `Enter`.
- Review screen (after the last question when there are several questions or the last is multiSelect): `1` = Submit answers, `2` = Cancel.
- `→` / `←` move between questions without choosing (used by `pendingQuestion` to read every question, then back).
- `Esc`: declined ("User declined to answer questions"; the log result is `is_error: true`, parsed as `.declined`).
- Option n+2 "Chat about this" is not used.
- Answers in the log: `toolUseResult.answers` = {question text: answer}; multiSelect labels and Other text joined with ", ", raw labels (with "(Recommended)").

## Codex request_user_input (Plan mode)

Only in Plan mode (Shift-Tab, `\e[Z`, toggles). In Default mode the tool output is "request_user_input is unavailable in Default mode" (parsed as `.declined`).

Screen: "Question 1/2 (2 unanswered)", numbered options, last option "None of the above  Optionally, add details in notes (tab)", footer with "enter to submit". Marker used: "enter to submit".

Keys:
- Digit `k` picks option k and moves on; on the last question it submits all.
- Free text: `Down` × n (to "None of the above"), `Tab` opens "Add notes", type the text, `Enter`.
- `←` / `→` move between questions. `Esc` interrupts.
- No multiSelect was seen; `answerQuestion` throws `.unsupported` for it.

Output: `{"answers":{"<id>":{"answers":["Blue"]}}}`; with notes `["None of the above","user_note: 一隻魚 fish"]` (parsed as "一隻魚 fish").

## Codex request_user_input_async

Seen 17 times in real rollouts: arguments `{questions:[{title, options:[String]}]}`, output `{"accepted":true}` at once; the answer is the next user message (free text). In this Codex setup (Default mode, gpt-5.6-luna low) the tool was "unavailable", so sending the answer as a message is **not verified**.

## End-to-end runs (`--question-live`, c9-input-test)

Each run: (1) the safety check — a question that is not on screen throws `.notOnScreen` and sends nothing; (2) the agent is asked; (3) the pending question is read (Claude: screen; Codex: log + screen); (4) `answerQuestion`; (5) the log must report the expected answers.

| Agent | Case | Answers sent | Log reports | Result |
|---|---|---|---|---|
| Claude | 1 question, single | pick 2 | "Coffee (Recommended)" | OK |
| Claude | 1 question, multiSelect + Other | picks 1,3 + "一塊 tart" | "Chips, Nuts, 一塊 tart" | OK |
| Claude | 3 questions: single, multiSelect, single + Other | 2 / 1,3 / "用 Line Pay" | "Large" / "Cheese, Ham" / "用 Line Pay" | OK |
| Claude | 2 questions: multiSelect + Other, single | 2 + "kiwi" / 2 | "Pear, kiwi" / "No" | OK |
| Claude | 3 questions, after the read-only/full-read split: read-only read leaves the screen unchanged; answer with unread > 0 refused, nothing sent; loadAllQuestions reads 3 and moves back | 1 / 2,3 / "用悠遊卡" | "Small" / "Egg, Tofu" / "用悠遊卡" | OK |
| Claude | 2 questions, user moved the picker to question 2 first (→ in the terminal) | 2 / 2 | "Blue" / "42" | OK |
| Claude | 3 questions, multiSelect pick + Other in the middle | 2 / 1 + "冰塊 ice" / 2 | "Large" / "Milk, 冰塊 ice" / "Cash" | OK |
| Codex | 1 question | pick 2 | "Pear" | OK |
| Codex | 2 questions: pick, notes (after the picker-region fix) | 2 / "草莓 berry" | "Rye" / "草莓 berry" | OK |
| Codex | 2 questions: pick, notes | 1 / "一隻魚 fish" | "Small" / "一隻魚 fish" | OK |

## Screen captures (text)

#### Claude: single question, single choice (picker open)
```
 ☐ Color
Pick a color?
❯ 1. Red (Recommended)
     warm
  2. Blue
     cool
  3. Green
     calm
  4. Type something.
────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this
Enter to select · ↑/↓ to navigate · Esc to cancel
```

#### Claude: after `2`
```
⏺ User answered Claude's questions:
  ⎿  · Pick a color? → Blue
⏺ Blue
```

#### Claude: multiSelect, open
```
←  ☐ Fruit  ✔ Submit  →
Pick fruits?
❯ 1. [ ] Apple
         red
  2. [ ] Pear
         green
  3. [ ] Plum (Recommended)
         purple
  4. [ ] Type something
     Submit
────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this
Enter to select · ↑/↓ to navigate · Esc to cancel
```

#### Claude: multiSelect after `1` `3` (toggles, cursor stays)
```
←  ☒ Fruit  ✔ Submit  →
Pick fruits?
❯ 1. [✔] Apple
         red
  2. [ ] Pear
         green
  3. [✔] Plum (Recommended)
         purple
  4. [ ] Type something
     Submit
────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this
Enter to select · ↑/↓ to navigate · Esc to cancel
```

#### Claude: review screen (after → or Tab)
```
←  ☒ Fruit  ✔ Submit  →
Review your answers
 ● Pick fruits?
   → Apple, Plum (Recommended)
Ready to submit your answers?
❯ 1. Submit answers
  2. Cancel
```

#### Claude: multiSelect Other: after `3` then Down Down, type `tart`
```
←  ☒ Snack  ✔ Submit  →
Pick snacks?
  1. [✔] Chips
         salty
  2. [ ] Cake
         sweet
❯ 3. [✔] tart
     Submit
────────────────────────────────────────────────────────────────────────────────────────────────────
  4. Chat about this
Enter to select · ↑/↓ to navigate · ctrl+g to edit in Vim · Esc to cancel
```

#### Claude: after Tab (cursor on Submit row)
```
←  ☒ Snack  ✔ Submit  →
Pick snacks?
  1. [✔] Chips
         salty
  2. [ ] Cake
         sweet
  3. [✔] tart
❯    Submit
────────────────────────────────────────────────────────────────────────────────────────────────────
  4. Chat about this
Enter to select · ↑/↓ to navigate · ctrl+g to edit in Vim · Esc to cancel
```

#### Claude: three questions, tab bar
```
←  ☐ Size  ☐ Tops  ☐ Pay  ✔ Submit  →
Which size?
❯ 1. Small
     Small size
  2. Large
     Large size
  3. Type something.
────────────────────────────────────────────────────────────────────────────────────────────────────
  4. Chat about this
Enter to select · Tab/Arrow keys to navigate · Esc to cancel
```

#### Claude: Esc
```
⏺ User declined to answer questions
  ⎿  · Tea or coffee? (Tea / Coffee)
✻ Baked for 1s · done 12:11 PM
```

#### Codex: picker (2 questions, second shown)
```
  Question 2/2 (1 unanswered)
  How to pay?
  › 1. Card               Pay by Card.
    2. Cash               Pay by Cash.
    3. None of the above  Optionally, add details in notes (tab)
  tab to add notes | enter to submit all | ←/→ to navigate questions | esc to interrupt
```

#### Codex: None of the above, after Down Down Tab
```
  Question 1/1 (1 unanswered)
  Cat or dog?
    1. Cat                Choose Cat.
    2. Dog                Choose Dog.
  › 3. None of the above  Optionally, add details in notes (tab)
  › Add notes
  tab or esc to clear notes | enter to submit answer
```

#### Codex: notes typed
```
  Question 1/1 (1 unanswered)
  Cat or dog?
    1. Cat                Choose Cat.
    2. Dog                Choose Dog.
  › 3. None of the above  Optionally, add details in notes (tab)
  › 一隻魚 fish
  tab or esc to clear notes | enter to submit answer
```

#### Codex: after the answer
```
• Questions 1/1 answered
  • Pick a color?
    answer: Blue
```

