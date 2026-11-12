# Fable review — 2026-11-12

Reviewed at `d55375b58` (1.34.23). Four read-only reviewers, each on Fable; their
full reports — evidence quoted, reproduction, root cause and fix for every
finding — are beside this file:

| Report | Covers |
| --- | --- |
| [A](2026-11-12/a-prompt-delivery-trust-checklists.md) | Opening prompts, folder trust, checklist menus |
| [B](2026-11-12/b-status-report-grant-todos.md) | Status "unknown", `report`, Operate Karmashala for children, two todos |
| [C](2026-11-12/c-agent-family-integration.md) | Claude Code, Codex and Antigravity: launch, hooks, menus, chat bridges, usage |
| [D](2026-11-12/d-lifecycle-approval-relay.md) | Session lifecycle, delegation, approval flow, the MCP relay |

**What this is and is not.** Every finding was read off the code. No test or
gate was run for the review and nothing was reproduced live, except one look at
Claude Code 2.1.316's trust dialog in a pane. "Confirmed" below means the faulty
path is visible in the source; "hypothesis" means the trigger depends on timing
or on how a CLI behaves and was not observed.

Ids are `A1a`, `C2`, `D7`: the report and its own numbering.

## High

| # | Finding | Where | State |
| --- | --- | --- | --- |
| 1 | **`session_answer` approve/deny presses a bare Enter or Esc when no menu can be read.** On the trust dialog the highlight is "No, exit", so "approve" declines; at an idle composer Enter submits the draft; while working Esc interrupts the turn. A decision record is filed and success returned. | `session_tool_set.dart:251-258` (`requireOpenPrompt: false`), `approval_answerer.dart:134` — A2a, D2 | confirmed |
| 2 | **The typist presses Return blind when the status keeper does not track the row yet, and the unverified send is reported delivered.** `markersFor` is null until the keeper's first 1.2 s tick; Return then follows the text with no wait, Claude folds it into the paste, and the message sits unsent. `session_send` answers `delivered: true`; the opening handoff row is consumed and never retried. | `message_typist.dart:124-133`, `session_input.dart:306-313`, `handoff_delivery.dart:258-260` — A1a | confirmed |
| 3 | **Nothing refuses typing into a dialog while the status is null.** `ready` falls back to "screen quiet 8 s", which a trust or MCP dialog satisfies. The dialog eats the brief; what is still unread when it closes lands in the composer as the "tail". | `handoff_delivery.dart:64-68`, `session_tool_set.dart:486-505`, `session_input.dart:286-288` — A1b | confirmed |
| 4 | **The chat runtime keeps one pending permission.** A second concurrent request overwrites the first, whose tool call is never answered and has no card; the turn hangs until Stop. | `acp_session_runtime.dart:239,1548-1549` — C1, D3 | confirmed; that an agent sends two at once not measured |
| 5 | **A delegated child waiting for a concurrency slot is reported as ended.** "No live screen" is read as ended: sync `subagent_run` answers `state: ended`, async parents hear "its process ended", and the child starts later unsupervised. The bot (`once`) hears only the false end. | `child_turn_wait.dart:103-104`, `launch_tool_set.dart:673,709`, `delegation_results.dart` `_follow` — D1 | confirmed |
| 6 | **Codex terminal sessions read "working" for good after an interrupted or failed turn.** Codex fires no hook then and has no idle marker; the keeper restores the last stale hook whatever it said, so the rollout is never consulted. Claude and Antigravity: same shape, bounded at five minutes. | `hosted_status_keeper.dart:282-283`, `server_session_status.dart:487-503` — C2 | confirmed |

## Medium

| # | Finding | Where | State |
| --- | --- | --- | --- |
| 7 | **A long typed message can split into two.** Return is pressed after 300 ms of still screen with no bracketed paste; a gap in Claude's reads sends the head and leaves the tail as a second paste, which the retry sends as its own message. Long openings could go by file pointer instead. | `message_typist.dart:21,126`, `session_tool_set.dart:860`, `handoff_routes.dart:33-35` — A1c, A1d | hypothesis |
| 8 | **Trust is pre-written only for scratch folders and the bot**, and fails silently when the agent's home or settings file is not found. Worktrees Karmashala creates and registered projects still ask. | `server_session_launcher.dart:384`, `agent_folder_trust.dart:52-77` — A2c | confirmed |
| 9 | **Checklists cannot be answered from `session_answer`.** Parser, keys, answerer and request all exist and the app uses them; only the tool refuses, and the transcript's `menu` omits the ticks. | `session_tool_set.dart:305-311`, `session_tool_schemas.dart:88-115` — A3a | confirmed |
| 10 | **`list_sessions` prints the stored lifecycle word raw, and `unknown` is sticky.** External-terminal launches are born `unknown` and nothing moves them (the comment promising hooks do is false); rows the host does not hold are swept to `unknown` at start. The tool shows neither liveness nor activity. | `inventory_tool_set.dart:149-151`, `hosted_agent_launcher.dart:696-703`, `hosted_session_status_keeper.dart:42-52` — B1 | confirmed |
| 11 | **Claude chat: a failed reopen leaves the bridge with no process**; every later prompt fails while the session reads running. | `claude_stream_json_bridge.dart:160-193,465-471` — C3 | path confirmed; trigger a hypothesis |
| 12 | **Claude chat: background-task and rate-limit state survive a process replacement** — working for ever, or a later error read as a usage limit. | `claude_stream_json_bridge.dart:447-462,543-554,1439,1458` — C4 | confirmed |
| 13 | **A turn the agent started itself cannot be stopped, and Stop reports success** (Claude and Codex chat). | `acp_session_runtime.dart:624-630`, `session_input.dart:399-406` — C5 | confirmed |
| 14 | **Menu answering: a re-pressed arrow that was only late lands before Enter.** On a wrap-around menu a deny can become an approve. | `menu_answerer.dart:271-294` — C6 | logic confirmed; needs a slow terminal |
| 15 | **After a restart, a cut-off child turn is reported "done"** with its mid-turn text, and the continued turn is not followed. | `delegation_results.dart:630-645` — D4 | confirmed; timing-dependent |
| 16 | **`session_answer optionId` skips the mode ceiling** (an agent can pick `auto` or `allow_always`), and nothing refuses answering one's own prompt. | `acp_session_runtime.dart:768-778`, `session_tool_set.dart:110,161-166` — D5 | confirmed |
| 17 | **A send that resumes a stopped session says "delivered, live" when the resume only joined the slot line.** | `session_tool_set.dart:518-525`, `session_queue.dart:1013` — D6 | confirmed |
| 18 | **`session_end` on a waiting child fails, leaves it in line, and still closes its delegation.** | `session_tool_set.dart:203-211,769-803` — D7 | confirmed |
| 19 | **Windows hooks name their temp files with `%RANDOM%`**, which repeats for `cmd` processes started in the same second: a lost `Stop`, or another session's payload. | `agent_hook_installer.dart:643,650` — C7 | mechanism confirmed; frequency not |
| 20 | **An opening prompt that starts with `-` is parsed as an option** on the argv route (Claude, Codex). | `agent_launch_arguments.dart:45`, `handoff_routes.dart:13-16` — C8 | confirmed |
| 21 | **A child started by a granted parent does not get "Operate Karmashala".** By design and pinned by tests, but it makes any second level of delegation need a click per child. Inheriting widens a permission: the owner's call. | `session_dao.dart:15-19,54`, `launch_tool_set_test.dart:241-252` — B3 | confirmed; needs a decision |
| 22 | **Codex chat never shows a trust prompt** (todo): the app-server bridge has no such request, so Codex most likely runs untrusted silently. | `codex_app_server_bridge.dart:1185-1232` — B4a | hypothesis |
| 23 | **A cancel the agent ignores holds a Codex or native-ACP chat session for ever**; only Claude escalates. | `acp_session_runtime.dart:478-483,624-630` — C9 | confirmed |
| 24 | **`session_send {wait: true}` can answer `idle` before the turn it sent begins.** | `hosted_session_wait.dart:166` — D8 | hypothesis |
| 25 | **Claude Code 2.1.316 no longer carries the idle footer strings the descriptor matches**; default-mode idle may read unknown, which pushes delivery onto the 8 s quiet rule (feeds 2 and 3). | `claude_code_descriptor.dart:866-873` — A, other notes | binary read; screen not re-measured |

## Low

| # | Finding | Id |
| --- | --- | --- |
| 26 | The bot's `report` is collapsed to `once` silently; the schema and the answer never say so. By design (PROJECT.md §26). | B2 |
| 27 | Todo "notification → empty screen": most likely fixed by `8ee6ae4bd` the day it was filed. Residual: a four-frame peek poll, and the desktop click skips the primed wait. | B4b |
| 28 | `worktree_remove` and `project_merge` use a narrower liveness check than `serverCheckoutOccupants`. | D9 |
| 29 | An agent's `session_send` lifts a pause the person put on the target's queue. | D10 |
| 30 | `SessionRegistry.close` removes by id, not identity. | D11 (hypothesis) |
| 31 | `decision_record`, `checkpoint_capture`, `checks_run` take another session's id ungated. | D12 |
| 32 | Results that claim more than was done (`detached`, `ended: true`). | D13 |
| 33 | Wrong-typed tool arguments surface as raw `TypeError` text. | D14 |
| 34 | Wait deadline timers never cancelled; an archived waiting row keeps its gate ticket. | D15 |
| 35 | Codex usage windows labelled by position, not length. | C10 |
| 36 | `CodexAppServerClient`: a stale handle's exit tears down a newer connection; colliding ids. | C11 |
| 37 | A second `stop()` on a chat session records a false ending. | C12 |
| 38 | ACP `terminal/*` reports negative exit codes. | C13 |
| 39 | Antigravity: undeclared termination reasons, hourly token expiry for usage. | C14 |

## How the reported bugs map

| Reported | Findings |
| --- | --- |
| Opening prompts lost or truncated; `session_send` loses its start | 2, 3, 7, 25 |
| Folder-trust prompt blocks new sessions; approve "sends Enter" | 1, 3, 8 |
| Checklist menus cannot be answered | 9 |
| Status says "unknown" | 10 (and 6 for a wrong "working") |
| `report` ignored | 26 — the caller was the bot |
| Settings do not reach child sessions | 21 |

## Fix order

1, 2 + 3, 9, then 4, 5, 10, 6, then the rest of medium by number. 21 waits for
the owner; 8 is done for folders Karmashala itself created and no further
without a yes.
