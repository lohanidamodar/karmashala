# Review A — opening prompts lost, folder trust, checklist menus

Repo: `C:\Users\dlohani\projects\popupbits\projects\.karmashala-worktrees\karmashala-20289127` (read-only review, 2026-11-12).
Installed agent on this machine: Claude Code **2.1.316** (`C:\Users\dlohani\.local\bin\claude.exe`); the descriptor was measured against 2.1.274/2.1.287.

Legend: **[C]** confirmed from code / probe, **[H]** hypothesis.

---

## The delivery path, end to end (so the findings have a map)

1. `open_new_session` → `LaunchToolSet._open` (`server/lib/src/mcp/tools/launch_tool_set.dart:884-1016`): `prompt` + `kReportBackHint` (`:56-59`, ends `…then end your turn.]` — the tail the reporter saw) → `ServerSessionLauncher.start`.
2. `server/lib/src/sessions/launch/server_session_launcher.dart:359-384`: attribution, scratch preamble, `_trustScratch` **only when `inScratch || bot`** (`:384`).
3. `server/lib/src/automations/hosted_agent_launcher.dart:555-566` → `_openingHandoff` (`:959-1005`) → `openingRoute` (`server/lib/src/sessions/launch/handoff_routes.dart:22-36`):
   - argv if `survivesWindowsNativeArgv` (`packages/karmashala_launch/lib/src/pty_launch.dart:477-486`: ≤2000 chars, no `"` `%` `&|<>^;`, **no newline**) — a 2–4 KB multi-line brief never qualifies on Windows;
   - else **typed** when `terminal.typedTextArrivesWhole` (Claude Code: `claude_code_descriptor.dart:947` = true) → `_Opening(null, pending: true)`, row stored in `session_handoffs`;
   - else file pointer (Codex etc.).
4. `HandoffDelivery` (`server/lib/src/sessions/launch/handoff_delivery.dart`) polls every 500 ms; `ready` (`:59-70`) = status idle, or status unknown/null **and** `TurnSettlement.quiet` (screen unchanged 8 s, `turn_settlement.dart:12,86-96,121-132`), and not `hasOpenPrompt/hasOpenQuestion`; after `settle` 800 ms (`:118`) it calls `deliver` = `SessionInput.deliverNow` (`server/lib/src/sessions/session_input.dart:273-321`) with lead-in `Please carry out this request: ` (`claude_code_descriptor.dart:951`).
5. `SessionMessageTypist._deliver` (`packages/karmashala_agent_status/lib/src/service/message_typist.dart:109-150`): `type(leadIn)`, 200 ms, `type(text)` → `SessionToolSet.typistOver.type` (`session_tool_set.dart:860-870`) = **one raw `typeAsServer(utf8.encode(text))`, no bracketed-paste wrapper, no chunking** → `HostSession.typeAsHost` (`server/lib/src/domain/host_session.dart:269-274`) → `_ConPtyHandle.write` (`server/lib/src/pty/conpty.dart:404-410`) → writer isolate loops `WriteFile` until every byte is written (`:549-581`). Then it waits ≤1.5 s for the probe (first 40 chars) **or** `[Pasted text #` in the composer, `_still` (300 ms unchanged screen, ≤1.5 s), presses `\r`, and presses `\r` up to 3 times while the composer still shows the placeholder (`:131-150`).
6. `session_send` → `SessionToolSet._send` (`session_tool_set.dart:353-470`) → `_deliverNow` (`:474-535`) → `typist.send` — same typist, no lead-in.

Karmashala-side write is lossless and ordered [C]. Whatever is lost is lost **in the agent's input handling**, and the code already knows the two ways that happens: the composer folding a Return into a paste, and keys landing in a modal.

---

## Bug 1 — opening prompt lost / only the tail arrives

### 1a [C] high — a Return is pressed blind on a screen the server cannot read, and the result is reported as delivered

`message_typist.dart:124-133`:

```dart
final typed = markers != null && await _until(sessionId, holds);
if (typed) await _still(sessionId);
if (!press(sessionId, _enter)) return MessageDelivery.none;
if (!typed) return MessageDelivery.unverified;
```

`markersFor` = `prompts.agentOf(sessionId)?.menus?.markers` (`session_tool_set.dart:857`) and `agentOf` is `status.keeper.agentOf(sessionId)` (`daemon_prompt_answers.dart:175-178`), which is null until `DaemonAgentStatus.tick` has run `keeper.track` for that row (`daemon_agent_status.dart:240`, every **1.2 s**, `:24`). In that window — and whenever the keeper does not track the row — the typist types the text and presses Return in the *next* write with no wait at all. The typist's own doc (`:5-9`) says what Claude Code then does: a Return arriving in the same read as the paste is folded into a newline; the message sits in the composer unsent. `SessionInput.deliverNow` logs it and returns `sent: true, via: unverified` (`session_input.dart:306-313`); `SessionToolSet._deliverNow` returns `true` → `session_send` answers `delivered: true` (`session_tool_set.dart:451-455`). `HandoffDelivery._type` consumes the handoff row on any non-throwing return (`handoff_delivery.dart:258-260`), so the opening is never retried; `_resubmit` can press Return again only while `stillTyped` sees the placeholder/lead-in, and `markersOf` is the same null in that window (`:84-91`).

Repro: `open_new_session` then `session_send` within ~1 s (or any time `keeper.agentOf` is null); or unit test `SessionMessageTypist` with `markersFor: (_) => null` and a fake screen that shows the text only 200 ms after `type` — assert that Return is not pressed before the composer shows the text, and that `unverified` is not surfaced as `delivered: true`.

Fix: in `_deliver`, when `markers == null` wait for `readScreen` to change after `type` (and for `_still`) before Return, and return `unverified`; in `SessionToolSet._deliverNow`/`_send` report `via: 'unverified'` with `delivered: 'unverified'` rather than `true`; in `HandoffDelivery._type` keep the row (do not `consume`) when delivery is `unverified` and let `_resubmit` confirm. Also make `markersFor` fall back to the installation's descriptor (`_checkouts.installation(row.agentInstallationId)?.agentId`, as `_rowOf` does) instead of the keeper.

### 1b [C] high — nothing refuses typing into a modal during the same window, and the modal eats the brief

`SessionToolSet._deliverNow` (`session_tool_set.dart:486-505`) and `SessionInput.deliverNow` (`session_input.dart:286-288`) refuse only when `report.hasOpenPrompt/hasOpenQuestion` is **true**; `report == null` (keeper not yet tracking) passes. `HandoffDelivery.ready` returns `turns.quiet(id)` for `report == null` (`handoff_delivery.dart:64-68`), which is true once the trust dialog has sat unchanged for 8 s. So with the keeper late, or with the grid unable to classify the dialog (see 2b), a 2–4 KB brief is typed into Claude Code's trust/MCP dialog: the dialog ignores printable keys, the typist's Return (1a) or a later one confirms whatever is highlighted (trust dialog highlights **No, exit**), and the composer is empty afterwards — "the CLI sits at an empty prompt". Bytes still unread by Ink when the dialog closes land in the composer — "only its tail".

Repro: launch Claude Code in a never-trusted folder from `open_new_session` with a 3 KB prompt and no human; watch `karmashala_host:` log for `handoff …: the opening message was typed in` while the screen shows `Enter to confirm`.

Fix: `ready` must be false while the screen holds any menu `readScreenMenu` can read (call `menus.onScreen`, not only `report.hasOpenPrompt`), and must be false while `report == null`; the same guard in both `deliverNow`s (refuse with the existing `_promptOpen` message when `menuOnScreen != null`).

### 1c [H] med — Return pressed mid-stream splits one paste into two messages (the "last 30 %" shape)

The whole text is handed to ConPTY in one write, but Claude Code (node/Ink on a Windows console) reads it in several chunks and decides "paste" by chunk timing, not by bracketed-paste markers (none are sent, `session_tool_set.dart:861`). The typist presses Return once `[Pasted text #1]` is on screen and the screen has been still for **300 ms** (`message_typist.dart:21,126`; `settle`). At startup Claude Code's event loop is busy (MCP servers, hooks), so a gap >300 ms between reads is plausible; the first part is then sent as one message, the remainder becomes `[Pasted text #2]`, and the typist's retry loop (`:139-150`, up to 3 Returns while a placeholder is visible) or `HandoffDelivery._resubmit` (`handoff_delivery.dart:287-304`) sends the tail as a **second** message — the one the agent treats as the latest instruction. The live test that justified `typedTextArrivesWhole` typed 1.5 KB and waited a fixed 2 s before Return (`server/test/live/claude_paste_live_test.dart:95-99`), which is not what production does.

Repro: `claude_paste_live_test.dart` with a 4 KB message and the production typist (`SessionToolSet.typistOver`) instead of the fixed 2 s; count `type: user` records in the transcript.

Fix (pick one, both are cheap): (i) wrap the typed text in bracketed paste `\x1b[200~ … \x1b[201~` for agents whose composer honours it (the live test already measured Claude Code records a bracketed paste whole), so chunk timing stops mattering; (ii) raise `settle` and require the placeholder's line count (`[Pasted text #1 +N lines]`) to be stable, and never press a second Return while a *different* placeholder number is visible.

### 1d [C] low — the opening goes typed even when a file pointer would be lossless

`openingRoute` prefers `typed` over `file` whenever `typedTextArrivesWhole` (`handoff_routes.dart:33-35`). Claude Code accepts `@path` file pointers (the file route exists and is used for Codex). Routing briefs over ~1 KB by file would bypass 1a–1c for `open_new_session` entirely (`session_send` would still need 1a/1b).

---

## Bug 2 — folder trust blocks every new session; `approve` presses Enter

### 2a [C] high — `session_answer approve` presses a blind Enter whenever the menu cannot be read, including before the prompt exists

`SessionToolSet._answer` passes `requireOpenPrompt: false` (`session_tool_set.dart:258`). `SessionPromptAnswers._approve` then reaches `SessionApprovalAnswerer.answer` (`approval_answerer.dart:63-152`) regardless of status; when `menus.onScreen` is null (no menu drawn yet, keeper not tracking so `supportFor` is null, or a layout the parser does not read) it falls through to `pressAnswerKey('\r')` and returns Claude Code's declared effect verbatim: *"Sends Enter, which confirms whichever option Claude Code currently has highlighted."* (`claude_code_descriptor.dart:878-884`). That is the sentence the reporter quoted, so this path was hit. On the trust dialog the highlight is **No, exit** (probe below), so a blind Enter that lands on it quits Claude Code; one that lands before the dialog is drawn does nothing and the session stays blocked.

Probe (2026-11-12, Claude Code 2.1.316 in a Karmashala PowerShell pane, empty folder): the dialog renders exactly as the 2.1.274 fixture — ` ❯ No, exit` / `   Yes, I trust this folder` / ` Enter to confirm · Esc to cancel` — so `readScreenMenu` (`agent_screen_menu.dart:174-262`) parses it and `affirmative: ['^Yes\b', …]` (`claude_code_descriptor.dart:923`) picks "Yes, I trust this folder" **when the screen is read**. The failure is timing/tracking, not wording. (The probe pane is detached and still running; `terminal_list` shows it — kill it, Esc exits.)

Fix: in `_answer`, when `decision` is given and `prompts.answers.menuOnScreen(sessionId) == null && !hasOpenPrompt`, throw "no prompt is open; nothing was pressed" instead of pressing the key; keep `requireOpenPrompt: false` only for the `optionId` (ACP) path. Test: `SessionToolSet` with a status that holds the session but has not classified it — assert no key is typed.

### 2b [C] med — the approve/deny key fallback exists only because the status is allowed to lag

`SessionPromptAnswers.menuOnScreen` → `menus.read` requires `isAsking` (`menu_answerer.dart:50-53`), i.e. `hasOpenPrompt`, which needs the grid to fire (`terminal_grid_status_source.dart:50-80`: `Enter to confirm` + a readable menu, no composer row). The transcript's `menu` block is likewise gated on `hasOpenPrompt` (`session_tool_set.dart:726-733`). The keeper reads screens every 1.2 s; until then `session_transcript` shows no `menu`, and `option`/`approve` have nothing to work with. Fix: `menuOnScreen` for the MCP tools should use `menus.onScreen` (screen only) and the transcript should include the menu whenever one parses.

### 2c [C] med — trust is pre-written only for scratch folders, not for worktrees or registered projects

`AgentFolderTrust` (`server/lib/src/agents/agent_folder_trust.dart`) already writes Claude Code's `projects.<folder>.hasTrustDialogAccepted: true` into `~/.claude.json` (`:140-172`), Codex's `[projects."<folder>"] trust_level = "trusted"` (`:195-217`), Antigravity's `trustedWorkspaces`. Key spelling matches the real file (forward slashes on Windows — verified: 38 entries like `C:/Users/dlohani/karmashala/scratch/…`, all scratch folders present, `hasTrustDialogAccepted: true`). It is wired as `trustScratchFolder` (`serve_command.dart:1385-1395`) and called only `if (inScratch || bot)` (`server_session_launcher.dart:384`). It also silently does nothing when the store home cannot be located or `~/.claude.json` does not exist (`:52-53,73-77`) — so a Claude Code installed in WSL and launched into a Windows path, or an environment whose store `homeFor` is unresolved, still asks. Note Claude Code keys trust per *git root*; this very worktree has no entry and did not ask, so worktrees of an already-trusted checkout inherit trust — the ask comes from `project_add`-registered folders and scratch folders whose write failed.

Fix: (1) call `_trustScratch` (renamed) for every **new** conversation whose `launchDirectory` Karmashala created — scratch, `worktrees.create` (`hosted_agent_launcher.dart:412-432`) — and for a registered project when the agent's store already trusts its main checkout; (2) log the "no settings file / no home" early returns at `agent_folder_trust.dart:53,76` so a silent miss is visible; (3) the `FirstRunPromptWatch` (`first_run_prompt_watch.dart`) already detects the dialog for automations — raise the same inbox notice for `open_new_session` children, and let `session_wait` return `blocked` with `kind: trust` so the parent can answer by option. Policy note: `daemon_agents.dart:121-126` says "Karmashala does not trust a folder on your behalf"; (1) stays inside the existing exception (folders Karmashala made).

---

## Bug 3 — checklist menus cannot be answered from `session_answer`

### 3a [C] med — the whole checklist stack exists; only the MCP tool refuses it

- Parser: `_checklistAt` (`agent_screen_menu.dart:264-327`) reads `❯ [✔] dart` / `[ ] name` rows plus the submit row (`Enable selected`), producing `AgentScreenMenu(checked: [true,true,null])`, `boxes`, `submit`, `isChecklist` (`:11-45`). Fixture: `packages/karmashala_agent_status/test/mcp_checklist_screen.dart`.
- Keys: `AgentMenuSupport.toggle = ' '`, `choose = '\r'`, `cancel = '\x1b'`, `down/up` arrows (`agent_screen_menu.dart:53-62`); Claude Code: Space ticks the highlighted box, Enter on the last row submits, Esc rejects all (`claude_code_descriptor.dart:925-927`).
- Answerer: `SessionMenuAnswerer.submitChecklist` (`menu_answerer.dart:92-158`) moves box by box, toggles, waits for the tick to change, moves to the submit row, presses Enter, waits for the menu to go; `dismiss` presses Esc (`:161-176`).
- Request: `MenuAnswerRequest.checklist(ticks:)` / `.dismiss()` (`prompt_answer_request.dart:252-284`); `SessionPromptAnswers._answerChecklist` files the decision (`prompt_answers.dart:150-205`). The desktop card already uses it (`app/lib/src/features/sessions/presentation/approval_request_card/screen_prompts.dart:111-115`); the phone payload carries `ticks` (`remote_question_payloads.dart:367`).
- MCP: `SessionToolSet._chooseRow` throws *"That menu is a checklist; answer it in its pane."* (`session_tool_set.dart:305-311`) and builds only `MenuAnswerRequest(option:)`; the schema offers no `ticks` (`session_tool_schemas.dart:88-115`); the transcript's `menu` omits `checked` (`session_tool_set.dart:729-733`).

Fix: add `ticks: boolean[]` (one per box, order of `menu.boxes`) and `dismiss: boolean` to `session_answer`; in `_chooseRow` build `MenuAnswerRequest.checklist(submit: menu.submit!, ticks:)` or `.dismiss()`; make `approve` on a checklist mean "all boxes ticked" and `deny` mean `dismiss` (both are unambiguous on Claude Code's MCP checklist, and `approval_answerer.dart:80-90` currently refuses). Emit `checked` and `boxes` in `session_transcript.menu`. Tests: `session_tool_set` with `kOwnersMcpChecklist` → asserts the key sequence ` `/`↓`/`\r` as `checklist_answer_test.dart` does.

---

## Other correctness notes

- [C] `SessionToolSet._deliverNow` (`:506-517`) and `HandoffDelivery` both treat `report == null` as "nothing asked" — see 1b.
- [C] `HandoffDelivery.forServer.submit` presses `\r` with no screen check beyond `stillTyped` (`handoff_delivery.dart:92,287-304`); a `[Pasted text #2]` from a split paste satisfies `stillTyped` and gets sent as its own message (1c).
- [C] Claude Code 2.1.316's binary no longer contains the idle footer literals `shift+tab to cycle`, `manual mode on`, `bypass permissions on` (`claude_code_descriptor.dart:866-873`); its mode labels are `default` / `accept edits on` / `plan mode on` / `auto mode on`. In default mode the grid may read **unknown** instead of idle, so `ready` degrades to the 8 s quiet rule and `TurnSettlement.running` relies on quiet — worth re-measuring the idle footer on 2.1.316 and adding the new labels.
- [H] `survivesWindowsNativeArgv` rejects any newline, so even a short two-line prompt takes the typed route on Windows; short prompts could be sent as `--` argv with `\n` replaced only if the agent collapses it — not recommended, just noting why "short prompts sometimes work" (single-line) and multi-line never ride argv.
