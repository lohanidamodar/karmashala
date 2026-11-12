# Review C — agent-family integration (Claude Code, Codex, Antigravity)

Scope: launch, hooks and status, screen parsing, chat bridges (ACP, Claude stream-json,
Codex app-server), usage. Read-only: nothing in the repository was edited, and **no test
or gate was run** — every finding below is from reading the code. "Confirmed from code"
means the faulty path is visible in the source; where the trigger depends on how a CLI
behaves, that part is marked as a hypothesis.

Paths are relative to
`C:\Users\dlohani\projects\popupbits\projects\.karmashala-worktrees\karmashala-20289127`.

Not re-derived (other reviewers): opening-prompt typing/truncation, Claude's folder-trust
prompt, the checklist refusal in `session_tool_set.dart`, status "unknown", the
`open_new_session` `report` argument, Operate-Karmashala grants.

---

## Ranked findings

### 1. HIGH — shared chat runtime (hits Claude chat hardest; Codex chat too) — a second permission request overwrites the first, whose tool call then hangs for the rest of the turn

Confirmed from code.

- Evidence
  - `server/lib/src/acp/acp_session_runtime.dart:239` — one slot: `_PendingPermission? _pending;`
  - `:1548-1549` — `final pending = _PendingPermission(call, options, title, question); _pending = pending;`
    with no check for a request already open.
  - `:1580` — `return await pending.completer.future;` The overwritten request's completer is
    referenced by nothing afterwards: `_resolvePending` (`:1624`) and `answerPermission`
    (`:759`) only ever see the newest.
  - The layer below expects several at once: `packages/karmashala_acp/lib/src/client/acp_agent_client.dart:39`
    keeps `Map<String, Set<AcpIncomingRequest>> _pendingPermissions`, and each request is
    dispatched in its own async `_onRequest`.
  - Senders that do ask concurrently: `server/lib/src/acp/claude/claude_process.dart:142`
    runs every `control_request` in an unawaited `_answer`, and
    `claude_stream_json_bridge.dart:1644` forwards each `can_use_tool` straight to
    `session/request_permission` (subagents carry `agent_id`, `:1720`). The Codex bridge does
    the same per approval request (`codex_app_server_bridge.dart:1182-1237`), and its
    non-blocking `item/tool/requestUserInput` can stand beside an approval.
- Reproduction (unit test in `server/test/acp/acp_session_runtime_test.dart`): risk `ask`;
  during one prompt have the fake agent send two `session/request_permission` calls
  (tool A, then tool B) before either is answered. Answer the open one
  (`answerPermission(approve: true)`). Expect both agent requests answered; actual: B is
  answered, A never is, `hasOpenPermission` is false, status reads working, the turn never
  ends. Answering with A's `toolCallId` is refused as "prompt changed". Only a cancel frees
  it (`AcpAgentClient.cancel` answers every open request `cancelled`), which costs the turn.
- Root cause: the runtime models "the" open permission; the protocol and both bridges allow many.
- Fix: in `_requestPermission`, queue instead of overwrite — keep a FIFO of
  `_PendingPermission`, publish the head as the open ask, and publish the next when the head
  is answered, withdrawn (`_permissionWithdrawn`, `askWithdrawn`) or cancelled;
  `_resolvePending(cancelled)` must drain the whole queue. Tests: two concurrent asks answered
  in order; withdraw of the queued one; cancel resolves both; an auto-answered (autoRun) ask
  arriving while another is open does not disturb it.

### 2. HIGH — Codex (terminal sessions) — a turn that is interrupted or fails leaves the session "working" indefinitely

Confirmed from code (the "no hook" premise is the descriptor's own documented measurement).

- Evidence
  - `packages/agent_cli/lib/src/agents/codex/codex_descriptor.dart:557-565` — "a turn that
    ends in an API error or an abort fires **no hook at all**"; `:682-685` — no `idle` grid
    marker is declared for Codex.
  - `packages/karmashala_agent_reporting/lib/src/agent_status_service.dart:63-72` — a hook
    older than `hookFreshness` (5 min) is dropped, so compose gets `hook == null`; with no
    marker on the idle Codex screen `gridReport` is null and compose returns `unknownFor`
    (`source: none`).
  - `packages/karmashala_agent_status/lib/src/service/hosted_status_keeper.dart:282-283` —
    `next = composed.source == AgentStatusSource.none ? _reports.latest(...) ?? composed : composed;`
    The "last hook, however old" is restored whatever it said — here `PreToolUse` /
    `PostToolUse` / `UserPromptSubmit` = `working`.
  - `server/lib/src/attention/server_session_status.dart:487-503` — the rollout transcript
    (which does record `turn_aborted` / `task_complete`, descriptor `:638-675`) is consulted
    only when the hosted reading is null or `unknown`. It is `working`, so it never is.
  - The pinned test covers only the benign case:
    `packages/karmashala_agent_status/test/hosted_status_keeper_test.dart:579` ("a stale hook
    is still the word when the screen says nothing") uses a stale `Stop`.
- Reproduction: hosted Codex terminal session with hooks trusted; start a turn that runs a
  tool, press Esc (or let the API fail). Status stays working for five minutes by design
  (fresh hook), then stays working for good. Unit test: keeper tracking a Codex row,
  `hook('PreToolUse')`, advance 6 min, `screen(row, ['some rows with no marker'])` →
  expected `unknown` (so the server reads the rollout), actual `working` from the hook.
- Impact: queued messages, `session_wait`, turn-settlement and parent reports wait on a turn
  that ended; the dashboard shows work that is not happening.
- Root cause: the stale-hook fallback was written for a `Stop` nobody watched and does not
  distinguish a settled status from an in-flight one.
- Fix: in `HostedStatusKeeper._recompose`, fall back to the stale hook only when its status
  is settled (idle, failed, or it carries an `ending`); a stale `working` hook with no
  in-flight work yields `unknown`, which `_observeHosted` already hands to the transcript.
  Better still for Codex: once the screen was read after the hook and its declared working
  marker (`esc to interrupt`) is absent past the redraw lag, stop believing a `working` hook
  early rather than after five minutes. Tests: the keeper test above; a
  `server_session_status` test where the rollout ends `turn_aborted` and the row goes idle.
- Same shape, bounded: Claude Code and Antigravity fire no `Stop` on Esc either, and read
  working for up to five minutes until the grid's idle marker wins (pinned for Antigravity
  in `antigravity_screens_test.dart:100-118`). The early-distrust rule above fixes those too.

### 3. MED-HIGH — Claude chat — a failed reopen of the open conversation leaves the bridge with no process, and every later prompt fails

Code path confirmed; the commonest trigger is a hypothesis about Claude (see below).

- Evidence
  - `server/lib/src/acp/acp_session_runtime.dart:513-541` — before a prompt, changed attached
    roots cause `client.loadSession(sessionId: agent, …)`; any failure is only a notice and
    `send` goes on to `client.prompt` (`:495`).
  - `server/lib/src/acp/claude/claude_stream_json_bridge.dart:160-162` — `_open` retires the
    live process first: `final old = _claude; _claude = null; if (old != null) unawaited(_retire(old));`
  - `:178-193` — on a `ClaudeControlError` it sets `_claude = null` and throws
    (`No conversation found` → `resourceNotFound`). Nothing restores a process and
    `_abandoned` stays false.
  - `:465-471` — `_prompt` resumes only `if (_claude == null && _abandoned && _turn == null)`;
    otherwise it throws `no Claude Code conversation is open`.
  - `:219` — `_ended` ignores the dead process because `identical(_opening, claude)`, so the
    bridge never reports an exit: the session's lifecycle stays "running".
- Reproduction: start a Claude chat session; before the first prompt, attach a checkout
  (`session_checkout_attach`); send the first message. `--resume <id>` is run for a
  conversation Claude has not written yet. Result: notice "was not told of the checkouts…",
  then the turn fails with "no Claude Code conversation is open", and so does every later
  send until the session is ended and resumed. Unit test with `FakeClaude`: the fake
  currently records a conversation at process start (`server/test/acp/claude/fake_claude.dart:161`),
  which hides this — add a mode that records it only after the first user message, attach a
  root, prompt, and expect the turn to run.
  Hypothesis: real `claude --resume` refuses an id with no persisted transcript. The same
  dead end is reached by any other reopen failure (spawn refused, `initialize` error).
- Root cause: `_open` gives up the working process before the replacement is known good, and
  only the abandon path knows how to recover.
- Fix: in `_loadSession`, when `reopening` and `_open` throws, either (a) start the
  replacement before retiring the old process and keep the old one on failure, or (b) on
  `resourceNotFound` reopen with `--session-id <same id>` plus the new `--add-dir`s (nothing
  was said yet, so nothing is lost), and for other errors set `_abandoned = true` so the next
  prompt retries. The runtime should also skip `_retellRoots` until a first prompt has been
  sent. Tests as above, plus "reopen failure then prompt resumes".

### 4. MED — Claude chat — background-task and rate-limit state survive a process replacement, so the session reads working for ever, or a later error reads as a usage limit

Confirmed from code.

- Evidence
  - `claude_stream_json_bridge.dart:1017` `_background` is removed from only by a
    `task_notification` (`:1355`). `_resetConversation` (`:447-462`) and `_abandon`
    (`:543-554`) do not clear it, nor `_rateLimit` (`:1498`) or `_compaction`.
  - `:1439` — at each prompt's result: `if (_background.isNotEmpty && !_agentTurnOpen) _openAgentTurn();`
    and `:1430` closes the agent turn only when `_background.isEmpty`.
  - `:1458` — `final limit = _rateLimit?['status'] == 'rejected' ? _rateLimit : null;` used
    for any non-success result.
- Reproduction (bridge test): a turn starts a task with `is_backgrounded: true`; cancel;
  the fake does not end the turn, so `_abandon` kills it after 5 s. Send a new prompt
  (resumes in a new process, which knows nothing of the old task id) and let it succeed.
  Expected: idle. Actual: `agentTurn started` with the dead task in `inFlight`, never
  ended — the runtime publishes working indefinitely (`acp_session_runtime.dart:983`).
  Second case: a `rate_limit_event` with `status: rejected`, then a process replacement,
  then a turn ending `error_during_execution` → reported as "usage limit is reached; it
  resets at <a past time>", which the usage-limit machinery acts on.
- Fix: clear `_background`, `_rateLimit`, `_limitUnsent` and `_compaction` in
  `_resetConversation` and in `_abandon`; when clearing a non-empty `_background`, send
  `agentTurn ended`. Tests: the two above.

### 5. MED — shared chat (Claude, Codex) — a turn the agent started itself cannot be stopped, and Stop reports success

Confirmed from code.

- Evidence
  - `acp_session_runtime.dart:624-630` — `cancel()` returns when `_turn == null`.
  - Agent-own turns set `_agentWorking`, never `_turn` (`:996-1010`): Claude continuing after
    a background task (`claude_stream_json_bridge.dart:1032-1037`), Codex answering an async
    question (`codex_app_server_bridge.dart:1051-1076`).
  - `claude_stream_json_bridge.dart:527-530` — the bridge's `_cancel` also returns when its
    own `_turn == null`.
  - `server/lib/src/sessions/session_input.dart:399-406` — `_interrupt` pauses the queue,
    calls `runtime.cancel()` and returns `DataAck` regardless.
- Reproduction: Claude chat; a turn launches a background shell and ends; when the task
  finishes Claude starts working again on its own; press Stop. Nothing is sent to Claude,
  the UI is told it worked, and the queue is paused.
- Fix: `AcpSessionRuntime.cancel()` should also act when `_agentWorking` (send
  `session/cancel`); `ClaudeStreamJsonBridge._cancel` should interrupt when `_agentTurnOpen`
  (same 5 s abandon timer, keyed on the process); the Codex bridge already interrupts on its
  own `_turn`. `_interrupt` should refuse in words when there is nothing to stop. Tests: a
  cancel during an agent turn reaches the fake as `interrupt` / `turn/interrupt`.

### 6. MED — shared terminal menus (all three; worst on Claude's wrap-around menus) — a re-pressed arrow that was only late, followed by Enter, chooses the wrong option

Confirmed from code as a logic race; whether it occurs depends on terminal latency.

- Evidence: `packages/karmashala_agent_status/lib/src/service/menu_answerer.dart:44`
  (`_step => patience ~/ 6`, 500 ms), `:271-294` — after one step's budget the loop breaks
  ("A key the menu dropped is pressed again") and presses the arrow again; as soon as a read
  shows the highlight on the target the loop ends and `choose` presses Enter (`:82`).
- Reproduction (unit test with a fake screen that applies each key 600 ms after it is
  pressed, in order): menu `Yes / Yes, and don't ask again / No`, highlight on 0, ask for
  option 2. Keys sent: Down, Down (re-press), …; the first late Down shows, the loop
  continues, and when the highlight reads 2 Enter is sent while a duplicate Down is still
  queued ahead of it. The TUI applies Down then Enter: on a menu that wraps, "No" becomes
  "Yes". Realistic on SSH hosts, a WSL distro waking, or a TUI busy redrawing.
- Root cause: "no change within 500 ms" is read as "key dropped", and nothing accounts for
  keys already sent before Enter.
- Fix: in `_moveTo`, count arrows sent and never press Enter while more arrows were sent
  than the highlight has moved — after any re-press wait one quiet step and re-read, and
  refuse (`unconfirmed`) if the highlight then differs from the target. For numbered menus
  (Codex, Antigravity) prefer the option's digit over arrows. Test: the delayed-screen test.

### 7. MED — Windows-native hooks (Claude, Codex, Antigravity) — two hook callbacks started in the same second share their temp files

Mechanism confirmed from code; frequency is a hypothesis.

- Evidence: `packages/karmashala_agent_reporting/lib/src/agent_hook_installer.dart:643`
  `set "KS_PROBE=%TEMP%\…%RANDOM%.code"`, `:650` `set "KS_BODY=%TEMP%\…%RANDOM%.body"`, then
  the body is written, sized, posted and deleted by name (`:651-663`). `cmd.exe` seeds
  `%RANDOM%` from the clock at one-second resolution, so two `cmd` processes started within
  the same second draw the same sequence — the same two file names.
- Effect: one callback deletes the probe or body file the other is about to read
  (`set /p` finds nothing → `exit /b 0`; `KS_SIZE` undefined → no POST), or posts the other
  callback's payload under its own event name. Across sessions that is a `Stop` lost (the
  session stays working until the hook goes stale) or a body carrying another session's
  `session_id`. Parallel tool calls in one session, and several busy sessions, both produce
  same-second callbacks.
- Reproduction: start the installed `.cmd` twice in one second with different stdin against
  a recording listener; one POST is missing or carries the other's body.
- Fix: make the names unique per invocation without `%RANDOM%` alone — e.g. have the
  PowerShell wrapper that already launches the script (`_scriptCommand`, `:330-336`) create
  the temp names (`[guid]::NewGuid()`) and pass them in, or stream stdin to `curl
  --data-binary @-` and let the receiver enforce the size limit. Note Codex trusts the hook
  command by hash, so keep the config command constant and change only the script.
  Test: a Windows-only integration test firing 20 callbacks concurrently and counting POSTs.

### 8. MED — Claude Code and Codex terminal launch — an opening prompt that begins with `-` is parsed as an option

Confirmed from code (not the PTY-typing route the other reviewer covers: this is the argv route).

- Evidence: `packages/agent_cli/lib/src/agents/domain/agent_descriptor/agent_prompt_support.dart`
  — positional style returns `[prompt]`; `packages/karmashala_session/lib/src/agent_launch_arguments.dart:45`
  appends it last with no `--`; `server/lib/src/sessions/launch/handoff_routes.dart:13-16`
  (`argvCarries`) accepts any non-empty text under the length limit. No check for a leading
  dash exists in `packages/karmashala_session`, `karmashala_launch` or the launcher.
- Reproduction: `open_new_session` on Claude or Codex in WSL with the prompt
  `- [ ] fix the failing test` or `--verbose logging is broken, fix it`. The CLI exits on
  "unknown option" / "unexpected argument" before drawing, or takes it as a flag (`-p …`
  would run Claude non-interactively). Antigravity is unaffected (`--prompt-interactive <text>`).
- Fix: in `argvCarries` (or `openingRoute`) return false for text starting with `-`, so it
  goes typed or by file; or emit `--` before a positional prompt where the CLI accepts it
  (verify per CLI: Codex's `resume <id> <prompt>` subcommand form too). Tests: route test for
  a dash-led prompt; `agentPaneArguments` test.

### 9. MED-LOW — Codex chat and native ACP agents (Antigravity chat) — a cancel the agent ignores holds the session for ever

Confirmed from code.

- Evidence: `acp_session_runtime.dart:624-630` sends `session/cancel` and nothing else;
  `:478-483` refuses every later send while `_turn != null`. The Codex bridge's `_interrupt`
  (`codex_app_server_bridge.dart:715-727`) swallows a refused `turn/interrupt`. Only Claude
  has an escalation (`claude_stream_json_bridge.dart:533-537`, 5 s then abandon). No call
  after `initialize`/`session/new`/`session/load` has a timeout (`_within`, `:1220`, covers
  only the start).
- Reproduction: fake ACP agent that ignores `session/cancel`; cancel; `awaitTurn()` never
  completes and `send` refuses until the session is ended.
- Fix: after `cancel()`, start a patience timer in the runtime; when it lapses, settle the
  turn as cancelled locally (answering open permissions), and say in the chat that the agent
  did not stop; for the Codex bridge, complete `_turn` with `cancelled` when
  `turn/interrupt` is refused or no `turn/completed` arrives in time. Test: the fake above.

### 10. LOW-MED — Codex usage — the two windows are labelled by position, not by their length

Confirmed that the code ignores the length; which accounts are affected is a hypothesis.

- Evidence: `packages/agent_cli/lib/src/agents/codex/codex_usage_endpoint.dart:79-80` —
  `add('primary_window', '5-hour', kUsageFiveHourWindow); add('secondary_window', '7-day', kUsageSevenDayWindow);`
  The rollout reader beside it does read the span (`codex_rate_limit_reader.dart`,
  `window_minutes` → `_labelFor`).
- Effect: an account whose primary window is weekly (or any other length) is shown as
  "5-hour", and pace/throttle maths (`UsageWindow.span`) use the wrong period.
- Fix: read `limit_window_seconds` from each window in `parseCodexUsage` and label through
  the same `_nominal`/`_labelFor` logic, falling back to position only when it is absent.
  Test: a payload whose `primary_window.limit_window_seconds` is 604800.

### 11. LOW — Codex store client — an old connection's exit tears down a newer one and leaks its process; server requests are matched as replies

Confirmed from code; needs a failed handshake plus a concurrent call.

- Evidence: `packages/agent_cli/lib/src/agents/codex/codex_app_server_client.dart:480`
  registers `_onExit` per handle; `:667-677` clears `_handle`/`_ready` and fails every
  pending call without checking which handle exited. `_teardown` sets `_ready = null` before
  `await handle.kill()`, so a call arriving during the kill opens connection B; A's exit then
  fails B's `initialize`, and B's own `_teardown` finds `_handle == null` and never kills B.
  Separately `:605-609` treats any line with an integer `id` as a reply, without checking
  for `method`, so a server-initiated request whose id equals a pending call's completes that
  call as "answered without a result object".
- Fix: capture the handle in the exit callback and ignore exits of a handle that is not
  `_handle`; in `_teardown` kill the handle captured by `_open`; in `_onLine` route lines
  that carry `method` away from `_pending`. Tests: handshake timeout with a second call
  in flight; a server request with a colliding id.

### 12. LOW — shared chat — a second `stop()` records a false ending

Confirmed from code.

- Evidence: `acp_session_runtime.dart:911-927` and `:1848-1850`. A second `stop()` while the
  first is waiting for the exit returns from `_tearDown` at once (`_torn`), finds the
  lifecycle not ended, and records "asked to stop, killed after 5 s, and not reaped within
  another 5 s" — before any kill, and for a process that then exits cleanly.
- Fix: keep the teardown future and have every `stop()` await the same one. Test: two
  unawaited stops against a fake that exits after 100 ms → `SessionExited(0)`.

### 13. LOW — ACP `terminal/*` — exit codes can be negative

Confirmed from code; no installed agent calls `terminal/*` today (owner's note).

- Evidence: `server/lib/src/acp/acp_terminals.dart:283` (`exitCode = -1` on error), `:211`
  and `:224` report `exitCode` as is with `signal: null`. Dart reports a signal-killed POSIX
  process as a negative code and a crashed Windows process as a negative NTSTATUS. ACP's
  `exitCode` is an unsigned integer or null, with the signal named separately.
- Fix: map a negative POSIX code to `{exitCode: null, signal: <name>}`, a negative Windows
  code to its unsigned 32-bit value, and the error case to `null`.

### 14. LOW — Antigravity — six termination reasons, and an expired token, read worse than they need to

- `antigravity_descriptor.dart:623-630` leaves `UNSPECIFIED`, `HALTED_STEP`,
  `EARLY_CONTINUE`, `INJECTED_RESPONSE`, `TERMINAL_STEP_TYPE`, `TERMINAL_CUSTOM_HOOK`
  undeclared on purpose; a `Stop` carrying one is dropped (`agent_hook_receiver.dart`,
  unknown subtype → not recorded), so the row says working until the hook goes stale and the
  grid's `? for shortcuts` wins — up to five minutes. Deliberate, but finding 2's
  early-distrust rule would close it.
- `antigravity_usage_endpoint.dart` refuses once the stored access token's `expiry` has
  passed ("Run the agent once to refresh"); Google access tokens last about an hour, so the
  usage reading fails whenever `agy` has been idle that long, and the failure carries no
  `UsageFailureKind` (Claude and Codex set `auth`). Hypothesis on how often this shows.
- Antigravity has no approval or failure hook and `PreToolUse`/`PostToolUse` are left out
  (they gate the tool), so approval is read only off the screen (`↑/↓ Navigate ·`).

---

## Checked and found sound (no finding)

- `AcpPeer`: ids, unknown-id replies, `$/cancel_request` both ways, close failing every
  pending call, a dead sink closing the peer (`io_process_handle.dart` turns a broken stdin
  into a `StateError` on the next write). Process stdin is UTF-8, so non-ASCII prompts are
  safe; the comment in `codex_app_server_client.dart` claiming otherwise is harmless.
- Codex bridge: turn id matching, interrupt before `turn/start` answers, plan → implement
  hand-off, process exit mid-turn, login link and timeout, `serverRequest/resolved`.
- Claude bridge: `can_use_tool` withdrawal, interrupt then abandon then resume, exit
  mid-turn, own-turn results (`origin`) not answering a prompt.
- Launch order (`agentPaneArguments`): Codex globals left of `resume`/`fork`; Claude's
  `--add-dir=` joined so the variadic flag cannot swallow the prompt; WSL launches cross as
  a base64 payload; PowerShell literals are ASCII-only.
- Hook installer: atomic write with concurrent-save detection, token file hardened before
  the token is written, entries recognised by marker rather than URL.

## Tests that pin behaviour vs gaps

- Pinned: Antigravity screens (`antigravity_screens_test.dart`), stale-`Stop` fallback,
  Claude abandon/resume, Codex approvals/questions/login, ACP start/auth/stop.
- No test: two permission requests open at once (1); a stale `working` hook on an agent
  with no idle marker (2); a reopen that fails (3) — `FakeClaude` records a conversation at
  process start, which masks it; state across a process replacement (4); cancel during an
  agent turn (5); a late key in `_moveTo` (6); concurrent Windows hook callbacks (7);
  dash-led prompts (8); a cancel the agent ignores (9); a Codex usage payload with a
  non-5-hour primary window (10).
