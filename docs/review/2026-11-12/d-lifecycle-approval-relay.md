# Review D — server session lifecycle, delegation, approval flow, MCP relay

Scope: `server/lib/src/sessions/`, `server/lib/src/mcp/`, `server/lib/src/status/`,
`server/lib/src/acp/acp_session_runtime.dart`, `server/lib/src/domain/`,
`packages/karmashala_agent_status`, `packages/karmashala_mcp`.
Method: code reading only. Nothing was run, no test was executed, no file in the
repository was changed. "Confirmed from code" means the path is traced end to end
in the source; it does not mean reproduced live.

Paths are relative to the worktree root
`C:\Users\dlohani\projects\popupbits\projects\.karmashala-worktrees\karmashala-20289127`.

Ranking: 1–3 high, 4–8 medium, 9–15 low.

---

## 1. HIGH — A delegated child that waits for a concurrency slot is reported as ended

Confirmed from code.

**Evidence**
- `server/lib/src/mcp/tools/launch_tool_set.dart:993-1016` — every agent launch is
  `priority: LaunchPriority.background`, the first kind the gate holds back
  (`session_launch_gate.dart` `_heldBack`: `pauseBackground`,
  `holdBackgroundAbovePercent`, and any full limit).
- `server/lib/src/sessions/launch/server_session_launcher.dart:416-421` — a held launch
  returns `SessionStarted(session: row, wait: …)` with a `created` row and no process.
- `launch_tool_set.dart:1031` puts `waitingForSlot` in the answer map, but nothing
  reads `started.wait` before waiting or watching:
  - sync `subagent_run`: `launch_tool_set.dart:709` `outcome = await turns!.firstTurn(session.id, …)`
  - async `subagent_run`: `launch_tool_set.dart:673` `delegate!(DelegatedChild(…))`
  - `open_new_session`: `launch_tool_set.dart:303` `delegate?.call(…)`
- `server/lib/src/status/child_turn_wait.dart:103-104`:
  `final running = status.liveScreenOf(sessionId); if (running == null) return _ended(sessionId, idle: afterWork);`
  so a first-turn wait on a row nothing runs yet settles at once as `ended`.
- `server/lib/src/sessions/delegation_results.dart` `_follow`: `ended` and not live →
  `over = true` → `_report(…)` → `_flush` posts
  `## "<title>" — its process ended … Exit code unknown` and `store.close(childId)`.

**Reproduction**
1. Settings: global limit 1 (or "pause background work", or the usage hold with the
   account above the percent). The calling parent itself holds the one slot.
2. Parent calls `subagent_run {prompt: …}` (mode wait).
3. Result: `state: "ended"`, `exitCodeKnown: false`, `childOpen: false`, a note that
   the pane is gone. The ticket is still in the gate; when the parent's turn ends
   the child starts by itself, with report mode `none`, and nobody ends it
   (ending on answer happens only inside the call that already returned).
4. Async variant: two seconds after the launch the parent receives "A session you
   delegated has reported back … its process ended". Later the child starts;
   `DelegationResults.started` happens to reopen the row (`reportVia == turn`,
   `reportState == ended`), so the real result also arrives. Under report mode
   `once` (the bot) `started` returns early, so the bot hears only the false end.

Unit test idea: `subagent_run_test.dart` with a gate whose limit is full; expect the
call not to answer `ended`, and `delegation_results_test.dart` with `isLive` false
and a `SlotWaits` entry; expect nothing pushed until the child runs.

**Root cause** `ChildTurnWait` and `DelegationResults` equate "no live screen" with
"ended"; only `session_wait` (`session_tool_set.dart:590`) knows about `SlotWaits`.

**Proposed fix**
- `LaunchToolSet._run`: when `opened` carries a wait, do not call `firstTurn`.
  For mode wait, either block until the gate grants (bounded by the call's
  timeout) and then wait the first turn, or answer `state: "waitingForSlot"` with
  the child id, as `session_wait` does.
- `DelegationResults.watch` / `_follow`: take a `waitsForSlot(childId)` predicate
  (from `SlotWaits`) and, while it is true, park the follow until
  `LifecycleEventKind.started` instead of calling `turnOf`.
- Tests as above, plus one for report mode `once`.

---

## 2. HIGH — `session_answer` approve/deny presses Enter or Esc into a session with no prompt open

Confirmed from code.

**Evidence**
- `server/lib/src/mcp/tools/session_tool_set.dart:251-258` — the MCP path builds
  `ApprovalAnswerRequest(… requireOpenPrompt: false …)` with no `ask`; the comment
  says "the menu reader and the question guard still stand between it and a blind
  Enter".
- `packages/karmashala_agent_status/lib/src/service/prompt_answers.dart:114` — the
  only "is a prompt open" check is skipped when `requireOpenPrompt` is false.
- `packages/karmashala_agent_status/lib/src/service/approval_answerer.dart:75-140` —
  `var menu = menus.onScreen(sessionId)`; when no menu is drawn the menu branch is
  skipped, and with a declared key the code goes straight to
  `pressAnswerKey(sessionId, key.keys, …)` (line 134).
- Keys: `claude_code_descriptor.dart:878-889` approve `'\r'`, deny `'\x1b'`;
  `codex_descriptor.dart:709` approve `'\r'`.
- `prompt_answers.dart:311-336` `_pressAnswerKey` then files a decision record
  ("Approve"/"Deny", `granted`) for a prompt that did not exist, and the tool
  returns `answered: "Approve"`, `effect: "Sends Enter, which confirms…"`.
- The only pre-check in the tool is `held` (`session_tool_set.dart:147-157`).

**Reproduction**
1. Terminal Claude session S is idle with a half-typed draft in its composer, or
   is working with no prompt.
2. An operator-granted agent calls `session_answer {sessionId: S, decision: "approve"}`
   (for example a moment after the person already answered the prompt it read).
3. Idle: Enter submits whatever is in the composer as a turn. Working:
   `decision: "deny"` sends Esc, which interrupts the running turn. Both return
   success and leave an approval row in S's decision record.

Unit test idea (`prompt_answers_test.dart`): status idle, screen with no menu,
`ApprovalAnswerRequest(requireOpenPrompt: false)`; expect `SessionPromptRefusal`
and no key pressed. Today it presses `\r`.

**Root cause** `requireOpenPrompt: false` was meant to tolerate a status that lags
the screen, but with neither a status prompt nor a menu on screen there is
nothing to answer, and the bare-key branch has no guard of its own.

**Proposed fix** In `SessionApprovalAnswerer.answer`, before the bare-key branch:
refuse when `menu == null` and the status reports no open prompt ("no prompt is
open in that session, so nothing was pressed"). Keep the lenient path only for
"menu on screen, status not caught up". Test above, plus a server test in
`session_tool_set_test.dart`.

---

## 3. HIGH — An ACP runtime keeps one pending permission; a second concurrent request orphans the first and the turn hangs

Confirmed from code (structure); that an agent sends two at once is a hypothesis
for any given agent, but the bridge carries a subagent `asker`, so parallel asks
are expected.

**Evidence**
- `server/lib/src/acp/acp_session_runtime.dart:239` `_PendingPermission? _pending;`
- `acp_session_runtime.dart:1548-1549`
  `final pending = _PendingPermission(call, options, title, question); _pending = pending;`
  — unconditional overwrite; the earlier completer is never completed.
- `_resolvePending`, `_permissionWithdrawn` (compares only against the current
  `_pending`), `_settle` and `answerPermission` all act on the current one only.
- `packages/karmashala_acp/lib/src/client/acp_agent_client.dart:215-229` keeps a
  *set* of pending permission requests per session and dispatches each without
  serialising, so two can be in `_requestPermission` together.
- `server/lib/src/acp/claude/claude_stream_json_bridge.dart` `_canUseTool` awaits
  `_acp.call(sessionRequestPermission …)` per `can_use_tool` with no queue.

**Reproduction** Unit test on `AcpSessionRuntime` with a fake client: deliver two
`session/request_permission` requests (tool calls A then B) before answering.
The card shows only B. Answer B. A's future never completes: the agent waits on
A forever, the status says `working`, no card is offered, `session_wait` never
settles. Only Stop (`AcpAgentClient.cancel` answers every request in its own set)
recovers it. A withdrawal of A is ignored too.

**Root cause** Single-slot state for a protocol that allows several open requests.

**Proposed fix** Make `_pending` an ordered map by `toolCallId`. Publish the head
as the open ask; `answerPermission(toolCallId:)` picks by id (default: head) and
then publishes the next; `_resolvePending` cancels all; `_permissionWithdrawn`
and `askWithdrawn` remove by id. Tests: two concurrent requests answered in
either order; withdraw of the first while the second shows; turn end cancels both.

---

## 4. MEDIUM — After a restart, a delegated child whose turn was cut off is reported to its parent as "done"

Confirmed from code; timing-dependent, not run.

**Evidence**
- `server/lib/src/sessions/delegation_results.dart:630-645` `_restore`: when the
  child is not live it first reads `await _answer(follow)`; any agent message since
  the turn began is reported at once as `ChildTurnOutcome(ChildTurnState.done)`,
  with `ended: true` when `endOnAnswer` — and only when there is no such message
  does it wait `restoreGrace` for the child to come back.
- `server/lib/src/sessions/session_subagents.dart:21-31` `lastAgentAnswer` returns
  the last agent message at or after `since`; a cut-off turn usually has
  mid-turn text.
- `server/lib/src/serve/serve_command.dart:1598-1641` starts the interrupted-turn
  resumes unawaited, at `LaunchPriority.background`; `:1985` calls
  `delegations.start()`. `isLive` is `prompts.status.holds`, false until the
  resumed process exists and is tracked.
- After the false report the row stays open and unawaited, so
  `DelegationResults.started` (line 405) returns at `row.isOpen` and nothing
  follows the continued turn. With `endOnAnswer` the row is closed, `ended: true`
  is told, and nothing ends the child that then resumes.

**Reproduction** `delegation_results_test.dart`, group "across a restart": watch
`c1`, let it say "Starting on it…" mid-turn, close the tracker, end the process
(server stop), start a new tracker, then run the child again inside
`restoreGrace` and finish the turn with a different answer. Expected: one push
with the final answer. Actual by the code: an immediate "done" with
"Starting on it…", and no push for the real end.

**Root cause** "Answered while the server was down" and "cut off mid-turn and about
to be continued" look the same to `_restore`, and it checks the answer first.

**Proposed fix** In `_restore`, wait `restoreGrace` for liveness first when the
row's turn is in `OpenTurns` (or simply always), and read the answer only if the
child is still not running after it. Never set `ended: true` without calling
`endChild`.

---

## 5. MEDIUM — `session_answer` can raise a session's mode through `optionId`, and may answer the caller's own prompt

Confirmed from code (missing checks); the parallel-call route to self-answering is a hypothesis.

**Evidence**
- `server/lib/src/acp/acp_session_runtime.dart:1665-1694` documents the invariant
  "An allow that switches the agent's mode never raises the session" and enforces
  it in `_optionFor(approve: true)`.
- `acp_session_runtime.dart:768-778` — the `optionId` branch takes the named option
  as is: `approve = option.kind.allows;` with no rung check and no
  `allow_always` restriction.
- `session_tool_set.dart:161-166` passes an agent's `optionId` straight through;
  `claude_stream_json_bridge.dart` offers `auto` / `acceptEdits` on ExitPlanMode
  and `allow_always` (which writes Claude's permission rule) on ordinary asks.
- `session_tool_set.dart:110` `targetSessionOf` defaults to the caller, and only
  `_chooseRow` (`option`) insists on a descendant; `decision` and `optionId` have
  no "not yourself" check, unlike `session_rewind`
  (`continuation_tool_set.dart:114-119`).

**Reproduction** Session S (rung "ask") shows a plan approval. An operator-granted
agent calls `session_answer {sessionId: S, optionId: "auto"}`: S continues in
auto mode. Or, in a chat session whose subagent raised an ask, the main agent
calls `session_answer {decision: "approve"}` with no `sessionId`.

**Root cause** The ceiling lives in the approve/deny path only; the gate treats
"has the operator grant" as enough for every option.

**Proposed fix** In `answerPermission`, when the answer comes from an agent
(`decidedBySessionId != null`, passed down from `DaemonPromptAnswers.answer`),
refuse an `optionId` whose rung is above the session's ceiling and refuse
`allow_always`. In `SessionToolSet`, refuse `session_answer` whose target is the
caller. Tests in `acp_session_runtime` tests and `session_tool_set_test.dart`.

---

## 6. MEDIUM — A send that resumes a stopped session reports "delivered, live" when the resume only joined the slot line

Confirmed from code.

**Evidence**
- `session_tool_set.dart:518-525`: `final started = await resumeWith!(…); if (started is SessionStarted && started.adopted) {…} return true;`
  — a `started.wait` is never looked at; the answer at `:451-460` says
  `delivered: true, live: true, resumed: true`.
- `serve_command.dart:2248-2263` resumes at `LaunchPriority.background`.
- `server/lib/src/sessions/session_queue.dart:1013` `_resumeFor` does the same:
  not adopted + `withPrompt` → head marked `delivered`, `_awaitTurnStart`.
- With `wait: true` the tool then calls `waits.wait`, which answers `ended` for a
  row nothing runs (`hosted_session_wait.dart:107-110`).
- `sentBy` arms the delegation's next turn for a child that is not running.
- `InterruptedTurnContinuer._continue` likewise files "Karmashala continued it and
  told the agent" for a resume that is only waiting.

**Reproduction** Limit full; `session_send` to an ended child. Answer claims
delivery; the child is in the gate's queue. Cancel the wait from the capacity
view: the message is gone, and its row says delivered.

**Proposed fix** Have `resumeWith` / `resumeStopped` callers branch on
`started.wait`: answer `queued: true, waitingForSlot: …` from the tool; keep the
queue head `queued` (not `delivered`) until `LifecycleEventKind.started`; word
the interrupted-turn inbox line accordingly. Test in `gated_launch_test.dart`
and `session_tool_set_test.dart`.

---

## 7. MEDIUM — `session_end` on a waiting child fails, leaves it in line, and still closes its delegation

Confirmed from code.

**Evidence**
- `session_tool_set.dart:203-211`: `endedBy?.call(callerSessionId, sessionId); return _end(sessionId, held: runsHere, by: callerSessionId);`
  — the delegation is told before anything is known to have ended.
- `_end` (`:769-803`): not held and `status.claimsLive` false (`created`) → throws
  "Nothing is running that session…". It never asks the gate, although
  `ServerSessionLauncher.end` (`server_session_launcher.dart:596-602`) knows how
  to cancel a waiting ticket.
- `delegation_results.dart:449-463` `endedBy` → `stopped` → `store.close`. When the
  child later starts, `started` (`:405-420`) returns because the row was not
  closed by a turn's `ended`, so nothing it does reaches the parent.
- The same ordering closes the delegation when `registry.close` throws for any
  other reason, and `queue?.ended(...)` (`:805`) has already cancelled what
  waited for it.

**Reproduction** Parent starts a child under a full limit, then calls
`session_end {sessionId: child}`. Error returned; child starts when a slot frees
and runs with no parent listening.

**Proposed fix** In `_end`, when a gate ticket exists for the row, cancel it
(route through `launches.end`) and answer `ended: true, endedAt: "the line for a
slot"`. Call `endedBy` and `queue.ended` only after the end succeeded. Test:
waiting child, `session_end`, expect the ticket gone and the row `cancelled`.

---

## 8. MEDIUM (hypothesis) — `session_send {wait: true}` can answer `idle` before the turn it sent begins

**Evidence**
- `session_tool_set.dart:464-468` calls `waits.wait(sessionId, inputSent: true)`
  right after the typist returns.
- `hosted_session_wait.dart:166` considers the current status immediately, and
  `idle` is "ready" → settles as `SessionWaitState.idle`.
- The typist returns when the composer no longer holds the text
  (`message_typist.dart`), not when the status has moved to `working`.
- `ChildTurnWait._turn` guards exactly this ("Ready and never seen working is also
  a session not yet started", `child_turn_wait.dart`), and `HostedSessionWait`
  has no such guard even though it knows `inputSent`.

**Reproduction** Unit test: status `idle`, send with `wait: true`, deliver the
`working` status one event-loop turn after the typist returns. Expected: the call
waits for the turn. By the code: `state: "idle"`, `changed: false`, whose note
says "not proof it did anything" — an agent may then send the message again.

**Proposed fix** When `inputSent` is true, do not settle on the opening reading:
require a `working` reading or a transcript move first (or delegate to
`ChildTurnWait.firstTurn(since: at)`), with the bound as the fallback.

---

## 9. LOW-MEDIUM — `worktree_remove` and `project_merge` use a narrower "is a session running here" than the rest of the server

Confirmed from code.

**Evidence**
- `server/lib/src/mcp/tools/worktree_tool_set.dart:373-382` `_liveSessionIn` matches
  only `session.repositoryId == worktree.id` or `session.worktree`.
- `server/lib/src/mcp/tools/server_checkout_occupancy.dart` (used elsewhere) also
  counts `session.workingDirectory` and every non-primary link
  (`session_checkout_attach`).
- A `created` row waiting for a slot is not live, so a worktree can be removed
  from under a launch that then starts in a missing directory.
- `server/lib/src/data/workspace_handler.dart:454-466` `_liveAcpSessionsIn` counts
  only ACP sessions whose *primary* `repository_id` is a folded checkout; a live
  ACP session attached to it as an additional checkout, or one waiting in the
  gate with the folded checkout id in its persisted spec, passes.

**Reproduction** Session A attaches worktree W with `session_checkout_attach`;
W is merged and pushed; session B calls `worktree_remove {repositoryId: W}`.
Not refused; A is working in a directory that is gone.

**Proposed fix** `_liveSessionIn` → `serverCheckoutOccupants(context, worktree.path, liveness:)`
without the may-write filter, plus gate tickets whose spec names the checkout.
`_liveAcpSessionsIn` → include `SessionRepositoryDao` links and tickets.

---

## 10. LOW — An agent's `session_send` lifts a pause the person put on the target's queue

Confirmed from code; whether intended is the owner's call.

**Evidence** `session_queue.dart:470-471` `queueIfBusy`: "Sending again is going on"
→ `_unpause(sessionId)` for every origin, including `QueuedMessageOrigin.mcp`.
`postDelegation`'s doc says a server post "never lifts a person's pause"; an
agent's send does. `pause` is what a person's Stop applies.

**Reproduction** Person stops child C with three messages queued (paused). Parent
calls `session_send` to C: the pause is gone and all four go, one per turn.

**Proposed fix** Unpause only for person origins (`_personOrigins`); an MCP send
joins the paused queue and its answer says the queue is paused.

---

## 11. LOW — `SessionRegistry.close` removes by id, not by identity, and can emit two `SessionClosed`

Hypothesis (narrow window).

**Evidence** `server/lib/src/domain/session_registry.dart:255-273`:
`final end = await process.terminate(…); _processes.remove(id); store?.forget(id);`.
`HostSession.terminate` keeps awaiting (`_closePty`, `_live.close()`) after the
lifecycle has ended, and `_vacate` lets `open(id)` replace an ended process. A
resume that lands in that window is then removed from the registry by the first
close: a live PTY nothing can find, attach to or end, and `runsHere` false so a
second agent can be started on the same conversation. Two concurrent closes of
one id each emit `SessionClosed`.

**Proposed fix** `if (identical(_processes[id], process)) { _processes.remove(id); store?.forget(id); }`
and keep an in-flight close per id so a second caller awaits the first.

---

## 12. LOW — Tools outside the operator gate that write onto another session

Confirmed from code; whether they "drive" a session is a judgement.

**Evidence**
- `server/lib/src/mcp/tools/decision_tool_set.dart:57-80` — `decision_record` with a
  `sessionId` appends to that session's decision record; those rows are carried
  into handoff packets and forks (`session_continuations.dart` `_carryDecisions`).
- `server/lib/src/checkpoints/checkpoint_tool_set.dart:31-37` — `checkpoint_capture`
  for another session.
- `server/lib/src/automations/checks_tool_set.dart:28` — `checks_run` for another
  session.
None is in `kMcpOperatorTools` or `_kMcpOperatorToolsOnOthers`
(`packages/karmashala_mcp/lib/src/mcp_tool_catalogue.dart:10-36`).

**Proposed fix** Add the three to `_kMcpOperatorToolsOnOthers`, with cases in
`operator_gate_test.dart`.

Not holes, checked: `terminal_run` refuses agent panes; `session_archive` /
`session_unarchive` are limited to descendants; `artifact_update` is limited to
the caller; `inbox_dismiss` and `review_thread_*` reach no session.

---

## 13. LOW — Results that claim more than was done

Confirmed from code.

- `session_checkout_tool_set.dart` `_detach` answers `'detached': checkout.id` for
  a checkout that was never attached (`sessions_handler.dart` `unlink` is a no-op
  then).
- `delegation_results.dart:637-642` `_restore` sets `ended: true` for an
  `endOnAnswer` child without calling `endChild`.
- Item 6 (`delivered: true`) and item 2 (`answered: "Approve"`).

Fix for the first: compare links before and after; answer `detached: null` with a
note when nothing changed.

---

## 14. LOW — Argument type errors surface as raw cast failures

Confirmed from code.

`targetSessionOf` (`server_tool_set.dart:32`) and most tool sets cast with
`as String?` / `as num?`. A wrong type throws a `TypeError`; in
`SessionToolSet.call` (`session_tool_set.dart:108-113`) only `ArgumentError` is
caught, so it leaves `call` synchronously rather than as the failed future the
relay expects. The agent reads "type 'int' is not a subtype of type 'String?'".
Fix: one `stringArg(arguments, name)` helper that throws `ArgumentError` in words,
and `on Object` at that catch.

---

## 15. LOW — Small leaks and stuck places

Confirmed from code.

- `hosted_session_wait.dart` and `child_turn_wait.dart` arm
  `_deadline(bound).then(…)` and never cancel it: every wait keeps a timer and
  its closure for the whole bound (six hours for a delegation's first turn).
- An archived `created` row keeps its gate ticket; it holds its place in line and
  counts against everyone behind it until granted, when `startGranted` drops it
  (`server_session_launcher.dart:663`). `SessionsHandler.archive` should cancel
  the ticket.
- `AwaitedLaunches.admit` has no way for a caller that gave up to leave the line;
  when granted, the reservation is released only by the ten-minute timeout.
- `DelegationResults.detach` does not cancel the child's `_held` timer (harmless:
  the timer finds the row gone).

---

## What was not verified

- Nothing was executed: no test, no analyzer, no live session. Every finding is
  from reading the source.
- Item 3: whether Claude or Codex actually sends two permission requests at once
  was not measured.
- Items 4, 8 and 11 depend on timing I reasoned about but did not observe.
- Not reviewed in depth: `session_rewinds.dart`, `terminal_rewind.dart`,
  `session_continuations.dart` (fork/handoff/switch internals),
  `handoff_delivery.dart`, `session_adoption.dart`, `daemon_session_sync.dart`,
  the SSH-box paths, and the app side of the approval card.
