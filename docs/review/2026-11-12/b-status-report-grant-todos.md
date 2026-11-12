# Review B — MCP-driven bugs in Karmashala (read-only review, 2026-11-12)

Repo: `C:\Users\dlohani\projects\popupbits\projects\.karmashala-worktrees\karmashala-20289127` (branch `session/20289127`, HEAD d55375b58). Paths below are relative to that root. Nothing was edited; no gate was run — every finding is from reading code and git history.

Legend: **[confirmed]** = read directly off the code path; **[hypothesis]** = consistent with the code but not traced to the symptom end-to-end.

---

## 1. `status: "unknown"` in `list_sessions` — severity: **med**

### Title
`list_sessions` prints the row's durable lifecycle word raw; `unknown` is a legitimate stored state ("lost sight of it") that nothing ever revises, and the tool exposes neither liveness nor activity beside it.

### Evidence [confirmed]
- `server/lib/src/mcp/tools/inventory_tool_set.dart:149-151`
  ```dart
  'status': waits.containsKey(session.id) ? 'waitingForSlot' : session.status.name,
  ```
  That is `SessionStatus.name` straight off the row. `delegations` does not use it (it uses `DelegationView.state`, `launch_tool_set.dart:537`), so the "unknown" seen today came from `list_sessions`.
- The enum: `packages/karmashala_session/lib/src/session_status.dart:22-24`
  ```dart
  /// **We lost sight of it**: it was running and nothing can see it now. Not an
  /// ending and not a claim — resuming makes the row `running` again.
  unknown;
  ```
  and `:40-41` has `labelWhen({required bool hostedLive})` — a reader-facing word — which `list_sessions` does not call.
- Who writes `unknown` (all writers of lifecycle status; hooks are **not** among them):
  1. **External-surface launches are born `unknown` and nothing moves them.** `server/lib/src/automations/hosted_agent_launcher.dart:696-703`
     ```dart
     if (launch.surface == SessionSurface.external) {
       // Launched into a window nobody here can see: `running` would be a
       // claim nothing observes. The agent's own hooks move the row from here.
       sessions.updateStatus(id, SessionStatus.unknown);
     ```
     The comment is false today: the only `updateStatus(` callers in `server/lib` are `hosted_agent_launcher.dart:455,699,748,876`, `server_session_launcher.dart:678,690`, `bot/server_bot.dart:312`. Hooks feed `AgentActivityStatus` (`server/lib/src/attention/server_session_status.dart`, `activity/activity_recorder.dart`), never `SessionStatus`. So a session started in an external terminal window stays `unknown` for its whole life.
  2. **The unheld sweep.** `packages/karmashala_session_engine/lib/src/service/hosted_session_status_keeper.dart:42-52` `markUnheld` turns every non-archived row that `claimsLive` (running/idle, `session_status.dart:28-29`), runs on this machine (`session_placement_rule.dart:10-21`: Windows, WSL, local POSIX — not SSH) and is not in the host's snapshot into `unknown` via `SessionLifecycleRecorder.recordUnseen` (`session_lifecycle_recorder.dart:97-101`). It runs at server start **and on every client watch** (`server/lib/src/serve/session_status_recording.dart:54-60`). Rows whose process died with a crashed server, or that the registry never held (host-id collision in `hostSessionIdOf`, `lifecycle_status.dart:42-43`, is lossy), land here.
  3. **Exit with no code** → `unknown` (`lifecycle_status.dart:13,33`).
  4. **A status word this build cannot parse** → `unknown` (`session_dao.dart:519-526`).
- Precedence keeps `unknown` sticky: `session_lifecycle_recorder.dart:131-137` — `unknown` is replaced only by `running` (a resume) or an ending seen by the host; a row that is `unknown` has no process in the registry, so no ending will ever be seen.
- ACP rows do **not** go `unknown`: `server/lib/src/sessions/session_ends_with_server.dart:21-27` resolves a host's silence to `completed`/`failed` for any installation whose adapter speaks ACP. (If the installation row is gone, `_speaksAcp` is false and they do fall to `unknown` — `:41-44`.)
- WSL rows run in the same server PTY host as Windows ones (`lifecycle_feed.dart:9-12,52-56`), so WSL by itself does not cause `unknown`; a WSL row goes `unknown` only through the same sweep as any local row.

### When status *should* be known
- Lifecycle (`SessionStatus`): only from the host feed — PTY and ACP processes the server's registry holds (`lifecycle_feed.dart:52-56`), plus SSH boxes' relayed events (`session_status_recording.dart:66`).
- Activity (`AgentActivityStatus {idle, working, awaitingApproval, failed, unknown}`, `packages/agent_cli/lib/src/agents/domain/agent_status.dart:9`): from hooks, the terminal grid, state files or the ACP protocol — kept by `DaemonAgentStatus` while the host holds the session (`server/lib/src/status/daemon_agent_status.dart:72-73,99-102`), and `DaemonPromptAnswers.holds` (`daemon_prompt_answers.dart:49-52`) says whether anything runs it here. `list_sessions` reads none of this; `ServerToolContext` (`server/lib/src/mcp/tools/server_tool_context.dart`) carries only `modelOf` and the inventory set only `quietSinceOf`/`slotWaits`.

### Reproduction
1. Start a Claude Code session with "Open in external terminal" (surface `external`); call `list_sessions` → `status: unknown` from the first second, and still `unknown` after it has finished.
2. Start an in-app terminal session, kill `karmashala_host` (not the agent), start the server again; call `list_sessions` → the row reads `unknown` forever (the agent's later exit is never observed), even though `session_wait`/`delegations` would say `ended`.
3. Unit test idea (server): build `InventoryToolSet` over a DB with one row `status: unknown` held by nothing and one `running` row the registry holds; expect the first to print a reader-facing word and `live: false`, the second `live: true` with its activity.

### Root cause
Two different questions ("what did the row last durably record" vs "is anything running it, and what is it doing") are collapsed into one field, and the one chosen is the one with a sticky `unknown` state. The external-surface comment promises a hook-driven update that does not exist.

### Proposed fix
1. **`InventoryToolSet._listSessions`** (`inventory_tool_set.dart:138-168`): add two injected readers — `isLive: prompts.status.holds` and `activityOf: (id) => status.statusOf(id)?.report.status` (both already built in `serve_command.dart:1968,1979` for `DelegationResults`) — and emit
   - `status`: `session.status.labelWhen(hostedLive: isLive(id))` — this turns a stale `running` into "no ending was reported" and lets `unknown` be spelled `'not recorded (lost sight of it)'` rather than a bare `unknown`;
   - `live: bool`;
   - `activity: idle|working|awaitingApproval|failed|'not recorded'` (only when live).
   Update the schema text at `inventory_tool_set.dart:339` to define the three words.
2. **External surface**: either make `WatchedSessions`/the hook intake write lifecycle for `surface == external` rows (the comment's promise) or correct the comment and have `list_sessions` say `runs in a terminal Karmashala does not see`. The hook path that could carry it: the `AgentStatusReport` from hooks already flows through `ServerSessionStatus.hookReported` (`server_session_status.dart:161`); a `Stop`/`SessionEnd` hook for an external row could call `SessionDao.updateStatus(id, completed)` guarded by `!row.status.isEnded`.
3. Tests: `server/test/mcp/tools/inventory_tool_set_test.dart` (exists? grep before adding) — cases for the three states above; a `hosted_agent_launcher` test that an external launch's row ends when its agent's end hook arrives.

---

## 2. `open_new_session` with `report: "each_turn"` answered `report: "once"` — severity: **low** (by design, but undocumented to the caller)

### Evidence [confirmed]
- `server/lib/src/mcp/tools/launch_tool_set.dart:212-237` `_openReportMode`:
  ```dart
  if (_isBot(callerSessionId)) {
    // It hears a session it started once, whatever it or a setting names.
    mode = named == kReportModeNone ? named : kReportModeOnce;
  } else if (named.isNotEmpty) {
    mode = _checkedReport(named);
  ```
  `_isBot` (`:239-241`) is `SessionDao.getById(caller)?.isBot` → `role == 'bot'` (`packages/karmashala_session/lib/src/session.dart:126`).
- The same collapse for `subagent_run --mode async` and `delegation_set_report`: `_forCaller` (`:245-248`), used at `:421-423` and `:641-646`.
- `kReportModeOnce` is deliberately outside `kReportModes` (`packages/karmashala_session_engine/lib/src/store/session_delegation_dao.dart:9-17`), and an ordinary session asking for `once` is refused (`server/test/mcp/tools/launch_tool_set_test.dart:230-239`).
- Parsing is otherwise correct: key `report`, values `none|final|each_turn` (`session_delegation_dao.dart:5-7`); the legacy `mode: async` maps to `each_turn` (`:221-228`); the response echoes the computed `report` (`:315-320`) and the delegation row stores it (`:303-313`). `LaunchDedupe` (`packages/karmashala_mcp/lib/src/launch_dedupe.dart:21-25,74-91`) keys on tool+caller+all arguments, so a repeat with a different `report` is a new launch, not a replay — dedupe is not the cause.
- The schema the agent reads (`launch_tool_set.dart:1284-1297`) describes `final`/`each_turn`/`none` only; it never says the bot is collapsed to `once`, and `_reportNote` for `once` (`:327-330`) just says "reaches you once".

### Reproduction
Call `open_new_session {report: "each_turn"}` **from the bot conversation** (the "Karmashala bot" panel session) → answer `report: "once"`. From any ordinary session the same call answers `each_turn` (`launch_tool_set_test.dart` group above). Today's driver was therefore the bot, or a session whose row has `role = 'bot'`.

### Root cause
Intentional product rule (PROJECT.md §26: the bot "hears a session it started once"), implemented silently: the argument is accepted, replaced, and the replacement echoed without saying why.

### Proposed fix
- Keep the rule, make it visible: in `_openReportMode` return a `(mode, note)` and add `'reportNote': 'You are the bot: any report is heard once, then the delegation closes. Use delegations to read later turns.'` to the answer when `named != mode`; add the same sentence to the `report` schema description (`:1284`) and to `delegation_set_report`'s (`:1451-1466`).
- Or, if the owner wants the bot to be able to follow each turn, drop the collapse in `_openReportMode`/`_forCaller` and let `DelegationResults` close on `once` only when the bot chose nothing. Decide with the owner; `server/test/mcp/tools/launch_tool_set_test.dart` "bot" group pins the current rule.

---

## 3. A child session is refused `open_new_session` ("Operate Karmashala" off) — severity: **med**

### Evidence [confirmed]
- The grant is stamped at insert from the global setting only, ignoring the row and the caller:
  `packages/karmashala_session_engine/lib/src/store/session_dao.dart:15-19,54`
  ```dart
  void insert(Session session) {
    final operates = _db.readMetadata(kOperateNewSessionsKey) == 'true';
    ...
        intFromBool(operates),
  ```
- Every agent-started child goes through this insert: `open_new_session`/`subagent_run` → `_open` → `launches.start(SessionStartSpec(... parentSessionId: callerSessionId))` (`launch_tool_set.dart:993-1016`, `:658-670`) → `HostedAgentLauncher` → `sessions.insertWithPrimaryRepository(session)` (`hosted_agent_launcher.dart:502-505`). The `Session` built at `:473-495` does not set `operatorGranted` (defaults false, `session.dart:43`), and insert would ignore it anyway. A waiting row keeps what it was inserted with (`:498-501`).
- The gate: `server/lib/src/mcp/mcp_tool_relay.dart:59-71` refuses when `!granted(callerSessionId)`; `serve_command.dart:871-872` answers from the child's own row. Refusal text: `packages/karmashala_mcp/lib/src/mcp_tool_catalogue.dart:85-92`.
- Pinned by tests as the intended rule: `server/test/mcp/tools/launch_tool_set_test.dart:241-252` ("what it starts takes the global setting, not its grant"), `server/test/mcp/tools/continuation_tool_set_test.dart:283-303` (handoff and fork "do not inherit its source's grant"), `server/test/sessions/launch/capacity/gated_launch_test.dart:225-300`. PROJECT.md §24 (`PROJECT.md:1479-1484`) says the same.
- Nothing lets the parent ask for it: `open_new_session`'s schema (`launch_tool_set.dart:~1240-1300`) has no `operate`/grant parameter, and `SessionPatch.operatorGranted` is "A person's act, never an agent's" (`session_patch.dart:79-81`).

### Reproduction
1. Settings → "Let new sessions operate Karmashala" **off** (default).
2. Turn Operate Karmashala on for session A (chip). From A call `open_new_session` → child B.
3. From B call `open_new_session` (or `session_send` to A, `subagent_run`) → refused with `mcpOperatorRefusal`.
Unit test: in `launch_tool_set_test.dart`, `insertCaller('caller')`, write `operatorGranted: true` on it, `open_new_session` → expect child `operatorGranted` true (fails today).

### Root cause
Design choice: the grant is a per-session, person-only act, and the only inheritance path is the global default. That is safe but makes any multi-level delegation (parent → child → grandchild, pipelines of agents, a child that must `session_send` to its parent) impossible without the person clicking the chip on every child. Note `report_to_parent` is exempt (`mcp_tool_catalogue.dart` / schema at `launch_tool_set.dart:1491-1499`), so a plain child still reports; only tools reaching *other* sessions are blocked.

### Proposed fix (needs the owner's yes — it widens a permission)
- **Rule:** a child *spawned by an agent call* inherits its parent's grant, capped by the parent's (a parent without the grant could not have called `open_new_session` anyway). Person-made handoffs/forks keep today's rule.
- **Where:** add `inheritOperatorGrant: bool` to `SessionStartSpec`/`HostedLaunch` set by `LaunchToolSet._open` when `callerSessionId != null`; in `HostedAgentLauncher` after `insertWithPrimaryRepository` (`hosted_agent_launcher.dart:503-504`) do `if (launch.inheritOperatorGrant && parentGranted) sessions.write(session.copyWith(operatorGranted: true))` (the "row that needs another value writes it after inserting" pattern PROJECT.md §24 already allows). Keep `SessionDao.insert` untouched so no client path can supply the grant.
- Optionally an explicit `operate: "inherit" | "none"` argument on `open_new_session`/`subagent_run` (default `inherit`), echoed in the answer as `operatorGranted`.
- Update PROJECT.md §24 and the tests at `launch_tool_set_test.dart:241` (the bot case stays: the bot's children should probably *not* inherit — the bot's grant is store-forced, `session_dao.dart:63-69`).
- Cheaper alternative if the owner declines inheritance: make the refusal say *how* to get it for a child ("ask your parent's person…") and have `open_new_session` echo `operatorGranted: false` so the parent knows up front.

---

## 4a. Todo "codex initial trust folder in chat view was not showing" (todo-1791253502117783-0, 2026-10-06) — severity: **med**

### Evidence
- The todo postdates the switch of Codex chat to Codex's own app-server (`33b62fb89`, 2026-10-04: "Codex spoken to over its own app-server, translated to ACP"), so "chat view" means `server/lib/src/acp/codex/codex_app_server_bridge.dart`. [confirmed]
- The bridge answers exactly these server requests and fails everything else with `methodNotFound`: `codex_app_server_bridge.dart:1185-1232` — `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, `item/permissions/requestApproval`, `mcpServer/elicitation/request`, `item/tool/requestUserInput`, `execCommandApproval`/`applyPatchApproval` (denied), `currentTime/read`. There is no trust-folder request anywhere under `server/lib/src/acp` (grep `trust` → only the `untrusted` approval-policy comment in `codex_acp_mapping.dart:30-31`). [confirmed]
- `thread/start` is sent with only `cwd` and `config` (`:276-286`); nothing says "trusted" and nothing reads back a trust state. [confirmed]
- The terminal form *does* know the prompt: `codex_descriptor.dart:270-281` declares the "Trust this folder?" markers, `FirstRunPromptWatch` (`server/lib/src/automations/first_run_prompt_watch.dart:9-16,45-74`) reads it off the screen and reports it as blocked, and `AgentFolderTrust` (`server/lib/src/agents/agent_folder_trust.dart:28-70`) writes `[projects."<folder>"] trust_level = "trusted"` into `~/.codex/config.toml` — but only for **scratch folders**, via `trustScratchFolder` (`serve_command.dart:1385-1395`). Project folders are never trusted by Karmashala. [confirmed]

### Root-cause hypotheses
- **H1 (most likely) [hypothesis]:** Codex's app-server never asks the trust question — it is a TUI-only onboarding screen — so the chat view has nothing to show. In an untrusted cwd Codex then runs with its untrusted-project defaults (project `.codex/config.toml`, hooks, skills not loaded; possibly stricter sandbox), silently. The person expected the same card the terminal form shows (`startup_trust_card_test.dart` in `app/test/features/sessions/`), and nothing told them the folder is untrusted.
- **H2 [hypothesis]:** If some Codex build does send an unlisted request for it (e.g. a `thread/...`-level `requestApproval`), the bridge's `default:` (`:1228-1232`) refuses it with `methodNotFound`, which Codex would treat as "no", with no card drawn. The bridge logs nothing for that branch, so it would be invisible.

### Reproduction
1. Pick a project folder Codex has never been run in (no `[projects."…"]` entry in `~/.codex/config.toml`).
2. Open a Codex **chat** session there; send a message. Observe: no trust card; check `config.toml` afterwards — no entry written. Compare with the terminal form: the prompt appears and `FirstRunPromptWatch` reports it.
3. To test H2: run the probe with host stderr captured and grep for `Karmashala does not answer`.

### Proposed fix
- In `CodexAppServerBridge._newSession` (or the launcher before it), read the folder's trust state (`AgentFolderTrust` already knows the TOML shape; add a `isTrusted(agentId, folder)` reader beside `trust`) and, when untrusted, either (a) call `trustScratchFolder`-style trust for the project folder after an ACP `session/request_permission` card "Trust this folder for Codex?" (one card, mapped like `item/permissions/requestApproval` at `:1202-1217`), or (b) at least emit a `session_info_update`/notice in the chat ("Codex runs here untrusted: project config, hooks and skills are off") so the state is visible.
- Log unlisted server requests at `:1228` with their method name (`_log`) so H2 can be confirmed from stderr.
- Tests: `server/test/acp/codex/...` — a fake app-server where the cwd is untrusted expects the card/notice; `agent_folder_trust_test.dart` gains the reader.

---

## 4b. Todo "notification is taking to empty screen after agent dashboard fix" (todo-1791514746998396-3, filed 2026-10-09 02:59Z = 08:44 NPT) — severity: **low** (likely already fixed; verify and close)

### Evidence [confirmed]
- Same day, later: `8ee6ae4bd 2026-10-09 17:34 +0545 feat(app): a notification opens where the session is; the dashboard is pinned` created `app/lib/src/app/shell/reveal_session.dart`, whose header reads (`:1-3`): "the one decision every one of them asks (owner, 2026-10-09: a session chatted with only in the dashboard's peek opened onto an empty screen)". `CHANGELOG.md:183`: "Notifications open where the session is: its tab, or the dashboard peek when it has no tab, never an empty screen."
- Routing today: desktop toast click → `notification_providers.dart:198-216` → `revealSession`; phone tap → `openNotifiedSession` (`:392-422`) waits for `sessionsPrimedProvider`, then `_whenShellUp` (`:427-443`), then `revealSession`. `revealSession` (`reveal_session.dart:41-87`): bot → panel; imported → selection; no row/archived → `_gone` (dashboard + notice); a pane in a tab → that tab; otherwise `_openDashboard` + `focusWatchedSession(selectSession: false)` + `peekOnDashboard`.
- `peekOnDashboard` (`app/lib/src/app/shell/quick_open/typed_command_runner.dart:60-73`) sets the board view, then polls `container.exists(overviewFocusProvider)` for at most **4 post-frame callbacks** and silently gives up; `overviewFocusProvider` is `autoDispose` (`overview_providers.dart:484-487`) and exists only while the board is built.

### Root-cause hypotheses
- **H1 [hypothesis, likely]:** The todo describes the pre-`8ee6ae4bd` behaviour (selecting a session with no pane drew its paneless page over every tab — the "empty screen" the `_activate` comment at `reveal_session.dart:124-126` still guards against). It was filed before the fix landed and never ticked. Verify once by tapping a toast for a session that has no tab, on desktop and phone; if it lands on the peek, mark the todo done.
- **H2 [hypothesis, residual]:** On a cold start or a minimised window the dashboard may take more than 4 frames to build (tab contents are built on activation: `workbench_tabs.dart:183-191`, `phone_shell.dart:209`), so `peekOnDashboard` drops the peek and the person lands on an un-peeked dashboard — not empty, but not the session either. Fix: replace the 4-frame poll with a listen on the board mounting (e.g. keep the requested peek in a non-autoDispose `pendingPeekProvider` that `BoardBody` consumes in `initState`), or raise the bound and call `ensureVisualUpdate()` as `_whenShellUp` does.
- **H3 [hypothesis]:** `_gone` fires when the notified session is archived/deleted or its row has not arrived yet; on desktop (`notificationPresenterProvider`) there is no `sessionsPrimedProvider` wait as there is on the phone (`openNotifiedSession:415`). A toast clicked while the client is reconnecting goes to the dashboard with the "no longer here" notice. Fix: route the desktop click through `openNotifiedSession` too (it already handles stores and pipeline ids identically).

### Test idea
`app/test/app/shell/reveal_session_test.dart` (check for an existing one): a session with no pane, dashboard tab not yet built → after N frames `overviewFocusProvider.peeked == id`; the same with the board taking 10 frames to mount.

---

## Summary table

| # | Severity | Status | One-line |
|---|---|---|---|
| 1 | med | confirmed | `list_sessions` prints raw `SessionStatus`; `unknown` is sticky (external launches, unheld sweep), hooks never write lifecycle; add live/activity, use `labelWhen` |
| 2 | low | confirmed | Bot callers are collapsed to `once` silently (`_openReportMode`); document/echo it or lift it |
| 3 | med | confirmed | Grant comes only from the global setting at `SessionDao.insert`; agent-spawned children never inherit; add capped inheritance in the launcher after insert |
| 4a | med | hypothesis | App-server bridge has no trust request to show; folders other than scratch are never trusted; add a trust reader + card/notice, log unlisted requests |
| 4b | low | hypothesis | Likely fixed by `8ee6ae4bd` the same day the todo was filed; residual 4-frame peek race and desktop missing the primed wait |
