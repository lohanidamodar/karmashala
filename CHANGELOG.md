# Changelog

This file records **1.1.0 (2026-08-31) through 1.21.0 (2026-09-10)** and
**1.24.0**, and what is on `main` past them. 1.22.x and 1.23.0 have no entries:
no release notes were written for them and this file does not invent any.
Anything before 1.1.0 is not recorded, for the same reason.

Entries are derived from the repository's own history: the `chore: release`
commit bodies where they exist, and the commits in each version's range where
they do not. Every entry here is traceable to a commit. Where the history is
genuinely ambiguous about which release something shipped in, the entry says so
rather than guessing.

Versions are listed newest first. The number in brackets is the build number
from `pubspec.yaml`, which is what a shipped binary reports — useful when two
installs claim the same version name.

---

## 1.26.2 — 2026-09-24 (build 47)

- **A resumed pane is rebuilt from the session's screen, as tmux does**
  (`7357029f`, `dbd01ddf`). The session host feeds each session's output into
  a headless terminal of its own; a pane attaching with nothing of the session
  yet gets that screen at its own grid — scrollback, colours, wrap flags,
  cursor and modes — then live output from the offset it stands for. Replaying
  raw output onto an empty terminal stacked an agent's relative redraws into
  debris. Sessions started before the host was replaced still replay as
  before; an older host or client falls back the same way.

---

## 1.26.1 — 2026-09-24 (build 46)

- **Changing a pane's width no longer leaves pieces of Claude Code's input box
  behind** (`xterm2` divergence 12). Narrowing wrapped each full-width rule
  onto a second row, so the agent's redraw fell short and left a `────`
  fragment under every rule and a stale status row below the box. The rows
  from its parked cursor down now keep their row count and are only cut to the
  new width; history above still reflows.

---

## 1.26.0 — 2026-09-24 (build 45)

**Local terminals run in the session host by default, and it reaches Macs and
phones.** 552 commits past 1.25.0 (165 features, 196 fixes); the headlines:

- **Local panes run in the session host** (`e60fc697`), with shell integration
  (`c9f7bcd8`), recorded resizes (`085ba6d3`) and links that reconnect
  (`0cad3e5a`). The host deploys to a Mac over SSH (`ab3c0f08`) and can be
  installed, stopped and removed from an SSH host's card (`9dad1c9c`,
  `ed13e599`); `karmashala_host relay` lets a box be its desktop's relay
  (`4e303630`).
- **The phone does more**: answers an agent's question and menu (`658f339f`,
  `6215097a`), changes a session's model and permission mode (`b2c633b8`),
  shows usage limits (`c6f671b6`), and pairs by scanning a machine's QR
  (`5e773db4`, `f7e5eb7c`).
- **Automations**: resume a session when its usage window resets (`481107c2`),
  recurring runs (`91e32efc`), and event triggers with a dry run (`fe7f4b51`).
- **Sessions and checkpoints**: fork from a checkpoint (`94d4ae4a`), hand a
  session over as one archive (`dca07fbd`), checkpoints titled by what their
  turn asked (`6acffdcd`).
- **Explorer**: an Activity-by-day lens (`5e2dffcf`), an Agents entry by state
  (`fd1eb57e`), multi-select (`cbaada94`) and keyboard navigation (`d081c88e`).
- **Editor**: SSH files through document sources (`b874b0f8`), autosave
  (`03c6c02a`), and files changed on disk picked up (`f3e93c8c`).
- **Probe mode** runs a second instance with no global side effects
  (`f226f9f9`, `bb20c368`).

Fixed on 2026-09-24:

- **The session host could stop answering for good on macOS** (`0d392509`).
  Ending a pane whose shell had started a job in a group of its own (a
  `claude login` typed at the prompt) left that job holding the terminal, and
  closing the pty under its blocked reader froze the host's only isolate.
  The close now runs in an isolate of its own, and ending a session reaches
  every process in it through libproc. `stop --force` reaches a host that
  will not answer (`2a502ad3`), and Settings offers Restart for one and Start
  when none is running (`d637a60a`).
- **Resizing no longer garbles an inline TUI** (xterm2 divergence 11). Shrinking
  the height popped the rows Claude Code draws below its cursor, so its next
  redraw erased history and left the old frame on screen.
- **Every way of copying trims each line's trailing padding** (`00ebccf9`).

---

## 1.25.0 — 2026-09-16 (build 44)

**Browsing for a file is Karmashala's own job now, and a project can be
edited.** Schema head moves to **v49**.

- **A session can be resumed when its usage window resets** (on `main`, past
  1.25.0; schema head moves to **v53**). Right-click a session, or take the
  offer its bar makes when a turn ends on a limit: the account is read again at
  the reset, the session resumed on its own conversation and told to continue,
  or the wait moved to the new reset. Every waiting one is listed under
  Settings › Automations. `docs/SETTLED.md`, *A session can be resumed…*.
- **The host's file dialog is gone from the desktop.** It had stopped drawing
  at all in this process: measured on a hung app, `IFileDialog::Show` had been
  entered and **no dialog window ever existed**, while the same dialog opened
  in 2.1 s in a plain process on the same machine. Two shell lists were feeding
  it `\\wsl.localhost` paths and both are now dropped before any dialog —
  `LastVisitedPidlMRU`, which is keyed on the executable and so ours to delete,
  and the WSL/UNC rows of `OpenSavePidlMRU`, which is keyed on the *extension*
  and shared with every other application. That second one is the whole
  difference between two pickers here: `*.exe` read a clean key and opened in
  828 ms, `*.apk` found no key of its own, fell back to `*`, and bound the two
  `wsl$` rows there.
- **A browser that lists directories itself**, with `dart:io` — whose listing
  is asynchronous, so a slow path costs a spinner rather than the window. It
  browses every environment the workspace knows: this computer, a WSL
  distribution over `\\wsl.localhost` (under a millisecond warm), and a host
  over SFTP. Tap a folder to walk into it, Back and Forward, a typed path, and
  one Hidden toggle — dot-files everywhere, plus the Windows hidden and system
  attributes — now shared by the picker, the SSH browser and the device file
  manager, which each answered that question differently before. Which dialog
  opens is a setting: Karmashala's on Windows, the system's on macOS and Linux,
  and a folder on another machine always uses ours because no local dialog can
  reach one.
- **A project can be edited rather than only made and deleted.** Its name, its
  context, its root folder, and the checkout its one-click session runs in.
  Moving a root reads the new folder before it writes anything, and rebases the
  checkouts under it **in place, keeping their ids** — that id is what every
  session, worktree and pinned default references. Anything that was not under
  the old root is reported rather than guessed at.
- **`project_add` and `project_update`** give an agent the same two doors
  through the same controller the dialog uses, so adopting a folder or cloning
  a repository does not depend on somebody opening a window.
- **A session with a live pane sorts above everything but a pin** in the
  Explorer.
- **The phone is answered again.** `sessions.list` awaited a git probe once per
  session, and that probe waits on a UI frame; a desktop that was not rendering
  produced none, so the request was never answered and the phone sat on a link
  it could prove was alive. The stage is read now, never waited for.
- **Quick Open no longer red-screens a debug build.** Its cache was harvested
  from `initState`, which modifies a provider during a widget life-cycle.
- `host/` and `mcp_bridge/` moved under `packages/` beside `relay`, which was
  already there. They are still not workspace members — they resolve on their
  own lock files so `dart compile exe` can reach them — but naming `packages`
  in the analyze gate now reaches all three, and `mcp_bridge` had been in no
  analyze command at all.

---

## 1.24.0 — 2026-09-14 (build 43)

**Code is read and written in the app now.** Schema head is unchanged.

- **An editor tab.** A file opens in the workbench beside your terminals —
  syntax highlighting, a line-number gutter, Tab/Shift+Tab that moves a selected
  block, Ctrl+S. It is a document pane, so it comes back after a quit and
  re-reads the file. Tapping a file in the Files panel, picking one in Quick
  Open and Ctrl+clicking a path in a terminal all open it here; the external
  editor moved to the right-click menu.
- **Large files open, and fast.** The line numbers used to be four widgets a
  line: a 50,000-line file took **52 seconds** to appear. They are painted at
  the viewport now — 1.7 s for the same file, and 0.47 s for 20,000 lines.
  Past 512 KB a file opens read-only in a viewer that draws only the rows on
  screen, because a text field lays the whole buffer out on every keystroke; a
  69 MB file of a million lines opens in 197 ms. The pane says why it is
  read-only rather than leaving you to find out by typing.
- **Binary files are refused with the reason**, in the words VS Code uses,
  because "binary" and "an encoding we cannot read" genuinely cannot be told
  apart. Only the first 8 KB is read to decide, so a 64 MB binary never reaches
  memory. A UTF-8 BOM is text and is written back; a UTF-16 one is refused.
- **Unsaved work is asked about on every route that closes a tab** — the chip,
  the bulk closes, the tab picker, a group, and the agent-facing
  `terminal_close`, which reports what it discarded. Closing the *window* still
  does not ask; that is written down in `BACKLOG.md` rather than promised.
- **Reading a diff is a tab too.** The Changes panel is a list again — file
  name, the folder it sits in, `+N −M` from one `git diff --numstat`, and git's
  status letter — and a row opens the diff with room to read it. A staged
  change now shows in that tab instead of reporting "no textual diff", and a
  file whose name git has to quote is one name everywhere instead of four
  different broken ones.

---

## 1.21.0 — 2026-09-10 (build 39)

**Fifteen packages, a third of the app's source out of `lib/`, and two freezes
whose real causes were nothing like the first diagnosis.** Schema head is still
**v48**.

- **The file picker no longer freezes the window.** One picker had started at a
  `\\wsl.localhost` folder, and Windows keeps that memory per executable, so
  every later dialog had to enumerate the Network root to draw it — measured at
  **30.7 seconds** cold, against 72 ms to reach the WSL folder itself. Pickers
  now start at a local folder and refuse a network path outright, and the
  poisoned entry heals on first use.
- **Closing a terminal pane no longer hangs the app**: releasing the pane's
  console waited on a child that had not died. Measured 5,005 ms before, 1.4 ms
  after.
- **A session checks its agent's executable before it starts or resumes**, and
  says which agent, which path and where to fix it, instead of failing inside
  the pane after the session row was written.
- **The Antigravity CLI's own stream-json protocol** is parsed, its `.pb`
  conversation files are read, and the signed-in email comes from the token
  rather than a network round trip.
- **The phone can search** projects and sessions, pins running sessions above
  the list, and every session says when it was last active — as does the
  desktop's sidebar and Quick Open, now ordered by it.
- **Sixteen packages under `packages/`**, `lib/` down from 754 files and
  181,959 lines to 579 and 119,813, and a change inside a package is proved in
  30–63 seconds instead of a seven-minute gate.

---

## 1.20.2 — 2026-09-10 (build 38)

**A day of repair, and the phone learned to find things.** Schema head is still
**v48**.

- **SSH panes reach the session host.** The deploy wrote to a literal `$HOME`
  over SFTP and every pane fell back to tmux; the home is resolved once now.
  A session that already lives in tmux keeps attaching there; new sessions
  take the host, which carries command blocks, links, exit codes, selection
  and the context menu intact.
- **Install… in the device pane has a typed-path field**, and the file picker
  quiets the device stream while it is up. The stream was measured and is not
  what freezes the window; the field is the way out either way.
- **The phone can search**, over the snapshot it already holds, and shows
  running sessions in a group above the projects with the reading's age; each
  session says when it was last active.
- **Sessions are ordered by when they were last active** in the sidebar, Quick
  Open and on the phone, each saying "active 3m ago". A session nothing has
  seen sorts last rather than claiming a time.
- **Closing a terminal pane can no longer hang the app.** Releasing the pane's
  console waited on a child that had not died; it now happens off the UI thread,
  after a bounded kill. Measured against a child that ignores being closed:
  5,005 ms before, 1.4 ms after.

---

## 1.20.1 — 2026-09-10 (build 37)

**The package split, end to end, and nothing else the user sees.** The build
exists to prove the release recipe with a pub workspace in place. Schema head
is still **v48**.

- **Package split, step 0.** The database takes the directory it opens in, and
  the provider files that draw no widget import plain `riverpod`; 585 of 1,027
  library files and 302 of 868 suites are now Flutter-free. Seven cost/soak
  suites are tagged `cost`. Nothing changes in the app.
- **`karmashala_core` is the first package out of the app** — logging, small
  utilities, path probing and the media layer, a pub-workspace member with 95
  tests that run in two seconds. `tool/gate.ps1 -Package core` gates a change to
  it in 36 seconds. Nothing changes in the app.
- **`karmashala_browser` is built beside the app** — 326 tests in four seconds,
  no dependencies; the app still runs its own copy until the cut-over.
- **`karmashala_remote` is built beside the app** — the wire and both ends of
  it, 440 tests in three seconds, one runtime dependency.
- **`agent_cli` is built beside the app**, on top of the public repo's own
  history — discovery, launch, stream, one-shot ask, store reading and usage
  over one descriptor table; 500 tests in two seconds; no local dependency.
- **The app now uses `karmashala_browser`** — its own copies are gone; a
  change to the browser layer is gated in 24 seconds.
- **`karmashala_devices`, `karmashala_git` and `karmashala_flutter_apps` are
  built beside the app** (687, 238 and 127 tests, seconds each), and the media
  layer is its own package, `karmashala_media`, so core is logging and paths
  only.
- **The app now uses `karmashala_remote`** — its own copies are gone; a change
  to the wire or the companion client is gated in under a minute.
- **The app now uses `agent_cli`** for discovery, launch arguments, streaming,
  store reading and usage; 1,758 import lines rewritten, and a change to the
  coding-agent interface is gated in 52 seconds. Gemini CLI, which the public
  repo carried, is removed: Google retired it on 2026-06-18 in favour of
  Antigravity CLI, which Karmashala already runs.
- **The app now uses `karmashala_devices`**; the device pane converts to the
  package's plain geometry and key records at five sites and draws the same
  tree. A device-layer change is gated in 68 seconds.
- **The app now uses `karmashala_git`**, with no glue: every git command already
  ran through `agent_cli`'s runner. A git-layer change is gated in 20 seconds.
- **The app now uses `karmashala_flutter_apps`**, the last cut-over. The split
  is complete: the app's own gate is 7,627 tests in about seven minutes, and
  `tool/gate.ps1 -Package <name>` gates a package change in 15 to 68 seconds.

---

## 1.20.0 — 2026-09-09 (build 36)

**Two days, 2026-09-08 and -09, 409 commits, and almost all of it new capability
rather than repair.** Schema head is **v48**: a database written by this build
cannot be read by 1.19.0.

### Our own session host, remote first and then local

`host/` — `karmashala_host`, pure Dart, cross-compiled from Windows for linux
x64 and arm64 in `build_release.bat` — deployed over the existing `dartssh2`
connection and used by SSH panes, with tmux kept as the fallback that says so in
the pane. The refusal that had stood against writing a termio was overturned by
two measurements: tmux's rendering path is lossy where its control mode is not,
and the Windows Dart SDK cross-compiles to Linux.

**Decisions the proof forced.** `forkpty` is resolved and never called — after
`fork` in a multithreaded VM only async-signal-safe code is legal, and forkpty's
child returns into Dart — so the pair comes from `openpty` and the child from
`posix_spawn` with `POSIX_SPAWN_SETSID`; on glibc ≥ 2.34 `forkpty` lives in
`libc.so.6` and older in `libutil`, resolved in that order. Output is a blocking
`read` in its own isolate and the exit code is the `waitpid` after EOF, so
nothing polls. A 4 MiB ring per session with absolute offsets; a reattach sends
`since` and gets exactly the missing bytes — a test caught the resume offset
being read from the *new* link, which would have replayed every session from
zero on each reconnect. Ended sessions are kept to the 16 most recent, so a pane
reconnecting a moment late can still read the exit code.

**The local stage, behind a setting that defaults off.** `AF_UNIX` binds from
Dart on Windows — measured on build 26200: bind, round-trip, unlink on close, as
on Linux — so the unix-socket listener already *was* the Windows listener, and
the "only genuinely new code" premise the item was written on was false. A named
pipe was refused for the defect the old `local_ipc` had, a blocking
`ConnectNamedPipe` that `Isolate.kill` cannot interrupt, measured as the app
failing to quit at all; loopback TCP was refused for the control server's own
reason, no peer credentials. The socket directory is restricted to the current
user and `serve` refuses to bind if that fails.

**ConPTY fit behind `Pty` call for call** — `CreatePseudoConsole` for `openpty`,
`CreateProcessW` with the pseudoconsole attribute for `posix_spawn` — with four
traps recorded at the line: the attribute takes the HPCON itself rather than its
address (the wrong one "succeeds" and attaches the child to the host's own
console); `STARTF_USESTDHANDLES` with three nulls is required or the child
inherits the host's stdout; a pseudoconsole pipe never reaches EOF while conhost
is attached, so the exit code is its own wait rather than following EOF; and
`ProcessSignal.sigterm.watch()` throws from `onListen`'s microtask on Windows,
which no try/catch around `listen` sees. A job object per session
(`KILL_ON_JOB_CLOSE`) takes the children when the host dies.

**A bug in the shipped POSIX launcher was found on the way:** the writer memoised
on the result, so three writes in one turn spawned three isolates and the PTY
received them third, first, second.

Settings → Terminal shows the host's version, whether this app started it, and
the age of that reading; reading Settings with the switch off launches nothing.

**Untested:** the real SSH deploy (there is no sshd in the WSL stand-in), arm64
execution, and macOS, which the Windows SDK cannot build at all. The `live-wsl`
suite drives the real binary inside WSL end to end and is the proof to re-run.

### Scheduled automations, behind an unattended gate (v43)

`features/automations/`, Settings → Automations, cron and one-shot only, and
**never an MCP tool** — a test fails if any served tool name starts with
`automation`. **One function owns every refusal:** `unattendedRefusal()` is what
the arm form shows, what the fire path throws with, and what the `failed` row
stores; seven refusals, with the environment resolver's own sentence carried
verbatim for the two environment ones.

The permission rule reads `PermissionRisk`, the half with evidence behind it:
`ask` and `acceptEdits` are refused, `bypass` is not — it is already
`isDangerous` and the arming human confirms it, so a second refusal would be the
gate re-deciding that. A null rung is refused, never read as "does not prompt".

**Reconcile:** the floor is `max(newest recorded occurrence, armedAt)`; one
catch-up inside a 15-minute grace; beyond it one `missed` row; several misses
run the newest once and fold the rest into one row, which is stricter than
openrun. A punctual fire is a catch-up nought minutes late, so a machine that
slept through 03:00 lands in the miss rules at 09:00. One unattended owner per
checkout, and a fire during a run queues with the row naming who is running.

**Limits kept:** cron in local time with `cron(8)`'s DST behaviour, no `@daily`,
`L`, `#` or seconds (refused, not half-parsed), and a run uses the checkout
itself rather than a fresh worktree — the queue is what makes that safe.
`undoCommitsRefusal(RunCommits)` is both the checkbox tooltip and the message
`dropCommits` throws with; a reading git could not take is `published: null` and
refuses separately.

**Not done, and its own item:** the per-project checks gate arming and firing but
are never executed, so a night's run can finish with nobody knowing whether the
work still stands. `project_verification` (off by absence) and `project_checks`
(name + argv) exist as configuration because verification had been
agent-recorded evidence with no per-project switch at all.

### First-class Flutter, end to end

`pubGet` → `run` → attached → reload/logs → `analyze`/`test` → a recorded
verdict, with no user step, and an agent can close that loop itself through
`flutter_run`.

**Decisions worth not re-deriving.** Detection keeps two signals apart — a
top-level `flutter:` section and `flutter: {sdk: flutter}` under dependencies —
because a plugin has only the second and cannot be `flutter run`; depth outside
the root is null, never zero. The SDK reading per environment reuses the agent
discovery request shapes, and **refuses a WSL `flutter` under `/mnt/<letter>/`
before the version probe**, because the probe is the run that does the damage; a
test asserts the third call is absent.

**The VM service URI comes from `--vmservice-out-file`, not `--machine` and not
the printed line.** `--machine` would take away the visible pane and its keys,
and the printed line wraps at the pane's width on the space before the address
(reproduced at 40 columns), while DevTools sits on the same host and port — so
"first URL after *available at*" would attach a VM client to a web server. For
WSL the out-file is spelled under `/mnt/c/` so it lands on the disk the watcher
watches, since `Directory.watch` over `\\wsl.localhost` never fires. SSH gets no
auto-attach and says so.

Gates record through `VerificationService.recordCommandCheck` without taking the
recording slot, so an agent mid-review can still run one; **no exit code observed
is inconclusive, never a pass**. The run tool returns the log only when something
failed or is still going. No migration: the SDK reading is not persisted, and
verdicts reuse `verification_runs`. A hand-set SDK path per environment went into
`Settings.flutterSdkPaths` rather than a migration, which makes the rule
structural — discovery writes `execution_environments` and cannot sweep a
different store.

**Deferred:** `deviceId` is taken as the caller's word, and a long run outliving
its two-minute device claim is by design, the pane check refusing a second launch.

**A running app is found, not pointed at.** The empty Flutter pane used to hand
over a `--vmservice-out-file` flag to paste into someone else's command, aimed
at another program's folder. Now three readers run on their own: the out-file
for runs Karmashala started, **the Dart Tooling Daemon's pid file** for any
`flutter run` on this machine (its socket answers the VM service address with
its token, no secret needed), and the VM's own `listening on` line out of
`adb logcat` for an app on a device, forwarded to a free host port. Each row
says where it came from and how old the reading is. A run on another machine is
the one case left for *Attach by address*; the Copy button and the suggested
flag are gone.

### One agent hands work to another and waits

`session_wait`, and `session_send` gained `wait: true`. The engine is the status
registry's broadcast, which publishes only when evidence moves, so nothing polls.

**What each CLI can and cannot say, measured:** Codex can report `blocked` only
from the screen grid — no hook can say it — and can never report `failed`,
because its stop hooks run only on success and errors are dropped from the
rollout; Codex hooks do not fire at all until the user grants trust in the CLI's
own review. Antigravity has hooks and nothing else — no state file, no grid, no
approval — so where hooks are unreachable it is permanently `unknown`, and
**`unknown` never settles**: the wait runs to its bound.

**The timeout wall** is `kLocalRpcTimeout` (60 s, applied as an idle timeout on
the response stream), and Claude Code abandons a call at ~60 s *and re-sends
it*, so the bound is 30 s by default and capped at 45, clamped rather than
refused. A blocked session is refused before anything is sent; a timeout answer
says `inputSent: true` so the caller does not send twice; `transcriptChanged` is
null, not false, when nothing could see the conversation. The DAG and a
wait-for-any stay refused until the single wait has been used.

### The handoff packet: a file, in the source agent's words, with owners

**Per CLI, measured.** Claude Code takes `--append-system-prompt-file` — named
only inside `--bare`'s help text, proven by the "file not found" error — so the
packet is written to a file named by the receiving session's id and handed over
rather than typed, which is what stops it collapsing into `[Pasted text #N]`.
Codex has no such flag; its `model_instructions_file` **replaces** the base
instructions rather than appending, so it was deliberately not used and Codex
keeps a typed packet, said so in the launch diagnostics. Antigravity has none.
The support is a three-way value — append, absent with evidence, unchecked — and
an unchecked agent is never reported as lacking one.

Packet files outlive their launch on purpose: a restored pane replays its
arguments, and deleting at shutdown would turn a restart into "file not found";
the directory is swept only when it is written to.

The source agent's own brief is asked for through `session_send` and
`session_wait`, bounded at 45 s, rendered under *"In &lt;agent&gt;'s own words"*
with the evidence rule applied to every line of it; not answering is said, and
declining leaves the packet byte-identical. Quoted recaps have an owner and no
editors, because an edited quotation is not evidence; the decision record and
`## Don't do` may be added to under one's own name. The fork dialog says the fork
is a new process and only the conversation crosses — agent-neutral, because a
list of grants read off Claude Code would be a claim about Claude Code.

### Checkpoints have a reachable UI, and the restore sentence is said

`CheckpointsView` compiled but its wiring had rotted: it read a selection
notifier nothing ever wrote, so mounted as-is it would have shown every
session's checkpoints at once. It is now a side-panel surface scoped to the
active pane's session the way the Plan surface is, with a Capture now and a
per-path restore beside the whole-tree one; a closed panel costs **0** DAO reads
and an open one **1**, re-read only on the revision the recorder and the tools
already bump.

**The dialog and the service share one function for their words**,
`checkpointRestoreRefusal`, and the sentence a person needed is in it: *files
only — the agent's conversation is not rewound; it still believes it made these
edits, so tell it what you rolled back.* A test asserts identity between the
thrown message and the on-screen text, not similarity. Found on the way and
fixed: `RestoreOutcome.files` reported the whole tree for a per-path restore, to
the panel and to the tool.

**Deferred:** a label prompt on manual capture, per-hunk restore, and the view's
own note that a checkpoint belongs beside the turn it came from.

### One resolver for where a checkout's commands run

The survey was the finding: **47 places** resolved an `ExecutionEnvironment`
from an id, **17 of them in order to run a command**, with six different
phrasings of one failure and none at all for the WSL and SSH cases, which threw
out of `CommandRunnerFactory` after the site had committed to running. Those 17
now go through `ExecutionEnvironmentResolver`, which answers with the
environment or one of four worded refusals — `noCheckout`, `environmentUnknown`,
`wslDistributionUnknown`, `sshUnavailable` — the last being exactly "this app
cannot reach where the agent would run", which is what the unattended gate
needs. The other 30 sites resolve for labels, path spelling or display and were
left alone on purpose.

### Devices: one task at a time, and a tap that looks first

**The lock.** A claim ends two ways, both evaluated on the next request and never
by a timer: the holder's session is over (`Session.isOver`, the same predicate
that retires its MCP token), or the holder went quiet for `kDeviceClaimLapse`
(2 min). `unknown` is not "over" — a blind spot is not a death. Acting claims;
reading never does and is never blocked, so a refused agent can still look. The
refusal names the holder, the session, the age of the claim and its last call.

**The safety net.** `device_tap` reads the screen once before it acts — the same
read `device_tap_element` already pays, so a vetted tap and an element tap both
cost **6** adb calls and `verify: false` costs 2 — and refuses when the screen's
*structure* moved since this app last read that device. The fingerprint is
`resourceId`/`className`/`bounds`/rotation/foreground app and **excludes text**,
because a clock or a streaming reply changes text on a screen that has not
moved, while a scroll leaves every label identical and moves every rectangle.
Two rules worth not re-deriving: **a match never weakens with age, a mismatch
does** — beyond `kDeviceLookWindow` (5 min) a differing reading is a note rather
than a refusal, because it says nothing about where these particular numbers
came from; and **a refusal does not file the screen it just read**, or the
identical retry would pass against a screen the caller never looked at. No prior
read is a warning, never a refusal: an unknown is not evidence.

**Untested on real hardware:** whether an OEM `uiautomator` dump is stable enough
between idle reads. If not, fingerprint `interestingNodes` instead of `allNodes`.

### Six tool-only capabilities gained surfaces

Each over the *same* service its tool calls, never a second path: a Decisions
side-panel surface, where a person can read what the handoff prompt will say and
record one by hand under their own name (an empty record reads "Not recorded" in
the packet's own words, never "nothing was decided"); a logcat strip under the
device pane's live view, bounded at 2,000 lines with drops counted, where "not
running", "attached and quiet" and "not started" are three sentences;
install/launch/force-stop in the device pane through the device claim, where the
window respects a claim and takes none; a browser console with evaluate,
selector and text as three modes rather than one field and a guess, deliberately
outside `BrowserCapability.evaluate` because that gate is about an agent acting
invisibly; a viewport screenshot in the same strip; and a standalone New
worktree on the Explorer heading, running the post-create setup.

`side_panel_close_test` is the layout tripwire this found: a third labelled
button in the browser pane's action row overflowed a 304 px panel by 108 px.

### Run something when a worktree is created (v42)

**The hook runs in the repository's own environment for all four kinds** —
`CommandRunnerFactory.forEnvironment` maps every one, and a wiring test proves a
WSL checkout's setup reaches a pane carrying its distribution and an SSH
checkout's carries its host. The copy is intra-environment (`cp -a` through the
runner; `dart:io` only where the host *is* that filesystem), because a worktree
is created beside its checkout and a remote repository's files are reachable only
as commands, never stat-ed. The worktree is created whether or not the setup
succeeds; the copy is awaited, the command is not; **a missing exit code is never
a healthy verdict**; and no pane available is a refusal rather than a background
run. Nothing in the setting can ask for a symlink. Settings → Worktrees writes
the setup and reads the verdict of its last run.

### An agent's own plan, beside its pane

Read from the transcript the app already parses. **Per CLI, measured:** Claude
Code publishes `TodoWrite` as a full snapshot (`todos[].content/status`, 164
calls in one session, sizes 1–15); Codex publishes `update_plan` as a full
snapshot with **different keys — `plan[].step/status`, and `arguments` is a JSON
string** — so Claude's shape reads Codex as nothing, silently, and a test pins
that; Antigravity publishes **none** (4,451 steps across 21 conversations, no
plan tool; `manage_task` describes background shell commands). An empty list is
treated as "nothing new" rather than as an empty plan, because it cannot be told
from a misread shape. **Known gap:** a plan is read only while its conversation
is on screen.

### Relay to LAN without a drop

The LAN candidate is dialled on a second transport while the relay stays up,
adopted only when its first sealed frame round-trips, and the relay is held
until the new link has carried a frame. The link sentence goes from
`Connected · Relay (127.0.0.1) · 4m` to `Connected · Direct (LAN) · 4m` with the
age still counting. Three frames per promotion, no duplicate rows, no gap.
Re-probing backs off in beacons (1, 2, 4 … 64) instead of a 30-minute refusal.

### A quit that finishes, and leaves nothing behind

Measured by a 20-cycle launch-and-close soak (`tool/app_soak.ps1`): before,
18 of 20 quits left the MCP handshake and socket on disk, 2 of 20 hung, and the
log lost its own last line. After: 20 of 20 exit clean, nothing left but the
database and the log, every quit writes its own account. The hangs were the
pseudoconsole close waiting on a console host that outlives the pane; the
stale handshake was a close landing inside the control server's own start.

### The companion's delivery model — presence is not delivery

**What was actually wrong:** a reconnecting phone re-fetched the *tail* and hoped.
`transcript.get` with `after: 0` answered the last 300 messages, so any gap
larger than one page was replaced by its end behind an "earlier messages are not
loaded" notice; `after > 0` answered the whole remainder unbounded, which the
transport dropped over `kMaxEnvelopeBytes`; and `transcript.appended` had the
same hole with teeth — an oversized delta was rebuilt and refused on every poll,
forever, silently, because the cursor moves only on a delivered frame. Now every
page is bounded at both ends and carries `hasNewer`, and the phone walks until it
reads false; with the walk stubbed, the reconnect test times out at 301 of 615
turns.

**Presence gated nothing**, because no presence frame exists on the wire. The one
focus-shaped gate is the phone's own explicit `transcript.get`, which cannot go
stale, and the invariant is now pinned rather than accidental.

Tool output was bounded on **none** of the three paths except rehydration; one
function, `boundedText`, 64 KiB in bytes walked back to a code point, serves all
three. The reconnect floor was 250 ms — four dials a second on an idle phone —
and `reconnect()` never reset the schedule, so a resume from the pocket was
answered with sixteen seconds; now 1, 2, 4, 8, 16, 30 s, reset on success,
visibility and explicit reconnect. The transport's backlog was bounded by frame
count (256) and not bytes; now 4 MiB too, newest never dropped, drops logged by
count.

**Compatible both ways:** an old phone never sends `after > 0` and ignores
`hasNewer`; a new phone reads an absent `hasNewer` as false, which is what an old
host meant. Single writer / many readers was **deliberately not built** — every
prompt is typed into one PTY, so last-writer-wins is already the physical truth,
and a token would refuse a keystroke with no failure behind it.

### Settings › Tools, and the three shipped skills

The agent's tools *were* in Settings already — 94 bare chips under the bridge
verdict, complete and unreadable. Now four bands by the kind of statement each
makes (preferences, a measurement, a catalogue, a consent), every served tool
listed by family with a summary compressed from its own schema description, and
a gate that fails on a served tool with no line, a line with no tool, a summary
over 80 characters, or a family with nothing under it. **Two hints are shown and
two are not, on purpose:** read-only and no-undo are facts a person acts on;
idempotent answers "is a retry safe", which a client decides with nobody
watching and is true of 50 of 94 tools; open-world marks exactly the device,
browser and Flutter families, so as a tag it would repeat the heading above it.

`karmashala-instructions`, `-advisor` and `-committee` ship as skills — hyphens
because `:` is the alternate-data-stream separator on Windows. **Where each CLI
discovers a skill, read off the binaries:** Claude Code
`~/.claude/skills/<name>/SKILL.md`; Codex `~/.codex/skills/<name>/SKILL.md`;
Antigravity `~/.gemini/config/skills/<name>/SKILL.md` — **not under its store
home** `.gemini/antigravity-cli`, so `AgentSkillSupport` is home-relative rather
than store-relative. Fixed path, constant bytes, per agent that is actually
there, removed only by the code that wrote it and by marker, and **nothing
retired at shutdown**, because a skill has no volatile half and taking constant
bytes out on quit to put identical ones back is the race that made hook entries
constants. User level rather than project level, because most checkouts are
worktrees the app made and a per-checkout install lands in the user's
`git status`. **Unobserved:** Antigravity actually picking one up.

### Also

- **A session's row ends only when the agent says it did** — `SessionEnd` →
  `completed` for Claude Code and Codex, `StopFailure` and Antigravity's
  `ERROR`/`MAX_*` → `failed` — never from a pane exit. Codex can never say
  `failed` (asserted), a terminal word is never overwritten, and where no CLI
  can say, the Explorer reads "no ending was reported" instead of `running`.
- **A Claude Code compaction summary is written as a `user` message.** On a real
  2,793-row transcript, row 1,287 is a 17,795-character `user` row summarising
  everything above it, and row 2,556 another — so the chat view drew both as
  something the person typed. The boundary is recognised on `compactMetadata`
  (since `agents_killed` is also a `type: system` line), everything before the
  *last* boundary is replaced by one notice naming the count and the trigger, and
  the index sees exactly what it saw before: length, order, roles and text
  unchanged at 2,793 rows.
- **Antigravity's Windows install holds no transcript** — one empty brain
  directory beside a 177 KB protobuf — so the refusal stands on the primary
  target, while WSL's 25 conversations read as evidence-carrying JSONL: one tool
  call per record, answered by the very next line in 2,261 of 2,310.
- A stopped merge can be aborted from the Changes pane, behind a confirm. The
  button does not probe for a merge in progress — that would cost a process on a
  poll — and `abortMerge` already answers exactly.
- A diff is ordered by what a reviewer reads first, and the order **tiers and
  never filters**: an unclassified path is first, then generated, then lockfiles,
  then `build/`.
- `inbox_list` returns the prompt an agent is blocked on.
- The benchmark `tool/benchmark/agent_process_cost_bench.dart` refuses without a
  root pid and never matches on a process name. Measured on the way:
  `Get-Process -Id` exits 1 whenever any named pid has gone and still prints the
  rest, so the exit code is not the verdict, and `/proc/<pid>/stat` splits at the
  *last* parenthesis.
- `device_tools.dart` is five device-family files behind one composition; the
  served tool schemas are byte-identical.
- `terminal_panel.dart` is nine files behind one composition; a 23-state tree
  golden did not move.
- `session_launcher.dart` is five parts and two libraries behind a 9 KB class;
  a golden of 266 launch shapes did not move.
- `workbench.dart` is seven parts behind a 20 KB composition; an eleven-state
  tree golden did not move.
- **The usage chip shows both limit windows** — `◑ 12% · 4h   59% · 3d` — each
  slot chosen by the window's period, never by which resets soonest. A period
  nothing reported draws nothing rather than `0%`.
- **Antigravity's chip no longer says `0%`.** Its API reports tiers and no
  quota, so the chip says so (`usage —`, "No quota reported for this account")
  and shows when the sign-in expires instead of calling it a reset. `get_usage`
  omits the percent for such a window.

---

## 1.19.0 — 2026-09-08 (build 35)

**A minor bump rather than a patch, because it carries a schema migration to v41
and the conversation index behind it.** The release was cut with a version bump
alone and no entry at the time; this is written from the release commit body and
the 71 commits in the range.

The build number moves with it, and that is the whole reason the version is
passed in as `--dart-define=KARMASHALA_VERSION` rather than guessed: the
installed build reports its version through `buildIdentity()`, and a build that
shares a number with the one already on the machine makes that reading useless.

### Search every conversation, not one (v41)

Quick Open gained an eighth source — **what was said, not only what a thing is
called** — over an FTS5 index fed by the triggers that already fire.

**FTS5's availability had to be proved against the loaded library, not the
build.** `sqlite3_flutter_libs` ships a **pre-compiled download** rather than
building from its own defines, so the `SQLITE_ENABLE_FTS5` in
`hook/description.dart` is not evidence about what the app opens. Measured
instead: SQLite 3.53.2, `COMPILER=msvc-1944`, `ENABLE_FTS5` present, and a
virtual table actually created, inserted into and `MATCH`ed. Both kept as
`test/core/database/fts5_availability_test.dart`, so a dependency bump that
dropped the module fails on the gate rather than inside a migration on a user's
machine. **No `LIKE` fallback exists**, deliberately: a search that quietly
degrades to a full-store scan is the cost the item was nearly refused over.

**The shape that made it cheap.** `conversation_turns` as an ordinary table
indexed by `session_id`, an *external-content* FTS5 index over `text` alone, and
a per-conversation watermark in `conversation_index_state`. That split is the
whole trick: re-indexing one conversation becomes an indexed delete — asserted
with `EXPLAIN QUERY PLAN`, not assumed — where a plain FTS5 table would have
needed a full-store scan. An idle app costs **zero**: `drain` returns before
touching disk or the database. A trigger on an unchanged transcript costs 1
SELECT and 1 stat with no file read; on a moved one, 1 parse and 5 statements
for 300 turns. The one-off backfill against the owner's real store: 108
conversations and 394 MB of transcripts became 4,919 turns, 447 statements and
5.83 MB in 7.5 s, nearly all of it parsing; re-triggering all 108 with nothing
changed costs 0 parses and 85 ms.

**Visible turns only, and the exclusion is the feature.** Of 17,050 parsed rows
on the real store, **12,131 — 71% — are tool rows and are not indexed**. Tool
calls, tool output and thinking blocks are unsearchable so that searching a
filename returns the messages that *discussed* it rather than every run that
touched it, held by a gate that fails if `tool` is ever added to the set.

**Query syntax is refused rather than escaped.** Every token is wrapped as an
FTS5 string literal with internal quotes doubled, and only the last is a prefix,
so `NEAR(`, `^start`, `((()))`, `-`, `:` and an unclosed quote are all just
characters. There is no escaping scheme that makes user input safe as an
*operator expression*, and a palette answering `fts5: syntax error near "("` to
a half-typed query is worse than one that cannot express a boolean.

**Deliberate limits, all of them open rather than hidden.** A live conversation's
newest turns are not searchable until its next trigger. Index rows for a deleted
session are never pruned; a hit no table can name is dropped at read time. 50
results, unranked — `ORDER BY rank` is one clause away. The stored ordinal is
unused, so there is no jump to the matching turn: a best-effort parse shifts it,
which makes it a hint rather than a key. And **Antigravity is not searchable at
all** — protobuf with an unpublished schema, which `readCliTranscript` already
refuses by name.

### A recording is a file a player opens, not a command you are told to run

**The terminal side.** The tap sits on the bytes arriving from the process,
upstream of the ingest tier on purpose: a cold pane's output never reaches
`terminal.write` at all, so recording downstream of that would have produced a
video that stopped the moment the user looked at another tab. The recording
lives in a `NotifierProvider` rather than a `State` field — the `_liveSerial`
lesson from 1.17.2, which a terminal pane has in its own form, since a tab or
group change unmounts the pane. It is visible for as long as it runs and
stoppable from where it is said, in a per-pane banner; deliberately no elapsed
clock and no byte count, because one needs a ticker and the other rebuilds per
chunk.

**The render and the encode are different seams, and the seconds are in the
second one.** A cast is cut into fixed-rate frames with any gap longer than two
seconds collapsed to it, because a recording of real work is mostly waiting for
a build. The render is `dart:ui` and has to run on the isolate that owns the
engine, because `Picture.toImage` rasterises nowhere else. Measured on this
machine, 80x24 over 74 frames: render 5.3 ms/frame at 960x540 and 13.5 ms at
1920x1080; GIF encode 49.5 ms and 252 ms for the same frames, PNG 31.6 ms and
161 ms — four to nineteen times the render. On the UI isolate a thirty-second
Full HD export would freeze the app for a minute and a half, so
`IsolateFrameSink` puts it on a worker and moves the frames as
`TransferableTypedData`.

**The OS writes the MP4.** `libmpv-2.dll` was the first candidate — 29.7 MB of it
already ships for the device live view, and libmpv is built on FFmpeg — and it
cannot: its FFmpeg is configured `--disable-encoders --disable-muxers` with
nothing re-enabled, it re-exports only `mpv_*`, `FT_*` and `archive_*`, and it
says so in its own voice. So Media Foundation, straight from Dart FFI:
`mfplat.dll` and `mfreadwrite.dll` ship with Windows and the encoder is an OS
transform, so this costs **zero added bytes**. FFI rather than a shim in the
runner because a method channel only answers on the platform thread, and the
encode has to stay behind the `FrameSink` seam on a worker isolate — verified
across 40 frames, which is where COM would have minded the thread. Verified by
opening the output: FFmpeg 6.0 reads it as h264 in mov/mp4, 1920x1080, 12 fps.

**The device side needed no second capture.** This app does not run the scrcpy
client — it pushes `scrcpy-server`, speaks the protocol itself, and therefore
already holds the encoded H.264 elementary stream the live picture is made of.
What it needed was a container, and `TsMuxer` was already here, written so
libmpv could open the live view at all: pure Dart, already carrying scrcpy's
per-frame timestamps and already restarting its own clock across a
discontinuity. So a recording is the bytes the picture is already made of,
written to a file — no re-encode and nothing extra on the handset.

The banner sits above the picture and outside both platform branches, so it
survives a pane switch, and it shows the destination path selectably, because
the point of it is something to paste into a player. A pane switched away from
and a device that has gone wear the same missing frame stream and get different
sentences, so it never invites the user to wait for nothing.

Four MCP tools — `terminal_record_start`/`stop` and `device_record_start`/`stop`
— over the two controllers the menus already call, so an agent's recording is one
the person beside it can see and stop. The format is per call and is resolved by
*start*, so an impossible ask cannot leave the cast written and the caller with
nothing. `device_record_start` with no live view says there are no frames to
record instead of reporting a recording that is not running.

**Named rather than fixed:** a remux leaves a one-frame offset. A sample's
duration is the gap it closes, because the gap it opens is not known until the
next frame arrives; MP4 accumulates durations, so the track sits one frame late —
a fixed offset, not a growing drift — and the length is short by the last frame.
Exactness would mean holding a frame of the live recording in memory for nothing
anyone can see.

### One connection to every running Flutter app

Karmashala could pick an element in a web page and knew nothing about a running
Flutter app — its own primary domain. It is a *registry*, because a desktop
build, an Android build on the mirrored phone and a simulator build are all
normal at once: each is its own row with its own connection, console and answer
to "can this be hot reloaded".

Verified against Flutter 3.47.2 / Dart 3.13.2 with a real `flutter run` rather
than reasoned about, and three findings changed the design. **The reload service
is `s1.reloadSources` on *our* connection, not `s0.`** — DDS numbers the
registering client per connection, and guessing the prefix produced a request
that was accepted and never answered, a hang rather than an error; the name is
read off the `ServiceRegistered` event, which DDS replays to a new subscriber.
`--vmservice-out-file` writes exactly `ws://host:port/token=/ws` while
`flutter run` *prints* `http://host:port/token=/`; both are accepted and neither
is stored. And `streamListen('ToolEvent')` is accepted, with the framework
pushing a `navigate` event there on every inspector selection change.

Five tools go with it, because the agent is the one holding the change and the
intent, and the two questions it cannot answer from the repository are "did that
compile into the running app" and "what did the app say when it did". Making it
read a panel over the developer's shoulder is the version of this that does not
work. `flutter_apps` is the registry, and an empty answer carries the exact
`--vmservice-out-file` path rather than just the news; `flutter_attach` takes the
address `flutter run` printed, for a run that had no flag, and is idempotent;
`flutter_reload`'s reply says what a success does *not* prove, since the reload
reached the VM and a widget that then failed to rebuild is on `flutter_logs`;
`flutter_logs` is the debug console — stdout, stderr, `dart:developer` records and
every caught exception, as prose rather than JSON, so nobody has to paste a stack
trace; and `flutter_pick_widget` returns the widget plus its file, line and column.

### The activity strip stopped hiding long calls, and background subagents

`kOutstandingCallMaxAge` was thirty minutes, chosen against what the shipped CLIs
were believed to produce, and **the belief was wrong on the owner's own machine**.
Measured across that Claude Code store on 2026-09-08, the longest unanswered tool
window is a `Bash` call at **514.8 minutes — seventeen times the ceiling** — with
476.0, 298.9 and 273.7 minutes behind it. A ceiling above every real call cannot
be chosen, because the age of a call is not evidence about whether it is running.
The evidence that *is* evidence already exists and is already taken every 1.2 s:
the `AgentActivityStatus` the badge, the tray and the notifications read.

**Claude Code runs the `Agent` tool as background work**, so the parent's call is
answered at once with `{"isAsync":true,"status":"async_launched"}` — 0.2 minutes
typically, longest 1.5 across the owner's 518 calls — and the outcome arrives much
later in a `<task-notification>`. The two runs on 2026-09-07 that took 76 and 80
minutes were therefore never outstanding calls, and no rule about a call's age
could have found either. Every record used to rebuild the ledger is one the CLI
writes for its own reasons, and **the `system/compact_boundary` is the
load-bearing one**: 95 of 311 background subagents in the owner's largest session
never reported back at all, so "launched and unreported" alone would have drawn
95 running agents on a session that had four. Measured against that store on
2026-09-08 the ledger holds exactly the four that were really running, and
nothing at all in four finished sessions. It costs no file — everything is in the
one transcript the chat view already reads.

The strip and the phone both show it now. Neither kind is marked as which:
whether the CLI held the parent's tool call open or answered it with a stub is a
fact about the CLI — a detail that already changed once — and not about the
user's work. The distinction a reader needs is subagent versus tool, which the
robot glyph and the collapsed count already draw.

**Fixed while there: the subagent tool is called `Agent`, not `Task`.**
`kSubagentToolName` had been `Task` since it was written, and counted over the
owner's whole Claude Code store on 2026-09-08 there are 650 `Agent` calls and
zero `Task` calls. Two things were silently dead as a result: a subagent never
read as one in the activity strip, and a delegate's turns were never hung under
the row that spawned it. Both names are kept, because an older CLI still writes
`Task` and a store is read long after the binary that wrote it was replaced.

### A recorded version becomes a dated reading (v40)

`agent_installations.version` was a bare number: written once by the first scan,
refreshable only by a manual "Detect agents". The app reported Claude Code
2.1.252 for a binary answering 2.1.263, and nothing on screen could tell a
current reading from a year-old one. **No refresh rate fixes that** — a bare
number reads exactly like a fresh one however often it is written.

So v40 records *when* the version was read. `version_read_at` is nullable and
never backfilled from `created_at`, because an unknown reading time is not a
reading time, so every pre-v40 row reads as "a number, read at an unknown time".
`recordVersion` replaces `updateVersion` and stamps the time on **every**
reading, including one that merely confirms the stored number. A stale version is
re-read on the launch that already checks paths, rather than on a cadence.

Settings renders the number through `describeVersionReading`: *"0.153.4 · read 5m
ago"* when recent, *"2.1.252 · last read 2d ago, may be out of date"* past the
freshness bound, and *"2.1.245 · read at an unknown time"* where there is no
record — never "just now".

### What a session changed

Codex answers out of its own turns, Claude Code out of its own transcript, and
Antigravity out of git, because its conversation payloads are protobuf in an
unpublished schema and there is nothing else to read. The git fallback is the
checkpoint chain, which is the only per-session baseline this app records —
sessions are not isolated in worktrees, so a bare `git diff` can attribute
nothing — and it costs no process and no git invocation, because it is already in
the database. Its limit is the first link, measured against the commit the
repository was on, and the caveat says so. There are **six outcomes rather than
an empty list**, because "changed no files", "could not be read" and "keeps no
record, so only git can answer" are three different sentences. A Files changed
dialog hangs off the session row, and the companion learns what a session is
running.

### Fixed

- **A message sent from chat reached the terminal and was not sent.** The
  carriage return was already being written, so something downstream was eating
  it. Measured 2026-09-08 against real ConPTYs, driving the app's own `Terminal`
  into `flutter_pty`: Claude Code 2.1.263 and Antigravity `agy` submit on body +
  CR, PowerShell and bash run it — and **Codex 0.153.4 leaves it in the composer
  on both Windows and WSL**, submitting only on body + `0x05` + CR.
- **Send follows the face that is already showing.** The owner: *"from todo and
  notes it's going to chat window, but it should go to terminal if terminal is
  active and chat if chat is active"*. 1.18.2's fix had made Send *reveal* the
  conversation, which landed the text somewhere visible and took the user out of
  the pane they were working in to do it. The group's face is now **read, never
  written**: terminal showing, typed at the prompt and left there; chat showing,
  queued for the composer with the face untouched; no live pane, queued, and the
  report says it is waiting.
- **The Send label names who, never where.** It is drawn without watching the
  selection, deliberately, and `notes_view_cost_test.dart` guards exactly that —
  a label that refuses to observe the state cannot name a destination that
  depends on it. So it names the recipient and stops; the snackbar, which
  resolves after the click, says where the text went.
- **A quota says when it resets, not only how long.** The chip said "97% · 2h14m"
  and the tooltip "resets in 2h14m", which answers how long and not when.
  `toLocal()` is the whole correctness of the new formatter: the two services
  hand back reset times in different zones — `DateTime.tryParse` on an ISO string
  with a `Z` gives UTC, Codex's `reset_at` epoch seconds give local — and nothing
  had noticed, because the only use was `difference(now)`, which compares
  absolute instants either way. A weekday is prefixed when the reset is not
  today, because a bare "11:55" three days out is a worse answer than none.
- **The snippets palette offered nothing in an agent pane.** The owner has one
  snippet, tagged `wsl`, and both panes he works in carry a `profile_id` of
  `agent:claudeCode` and `agent:codex`; `terminalProfileFromId` resolves
  `powerShell`, `commandPrompt`, `posix:` and `wsl:` — not `agent:` — so the
  shell read as unknown, and an unknown shell is offered only untagged snippets.
  His Claude Code pane *is* WSL, one field from the null it was producing, so the
  launch is asked. Only the WSL case is inferred, because it is the only one the
  launch states.
- The browser stopped telling users to pass a flag Chrome now ignores, and raises
  the page before a pick and the app when one lands.
- A URL in a note's or a todo's body is clickable, and Ctrl+Shift+J walks to the
  next agent waiting for you — `J` for jump, since `A`, `B`, `K` and `N` are the
  side panel's own surface shortcuts, and Flutter sees the modifiers, so taking
  Shift+J leaves a shell's `Ctrl+J` untouched.

### Also

The phone can attach a picture to a prompt, and **it knows what the desktop would
take before anybody opens the picker**: the paperclip is simply absent for a
session whose agent cannot be handed a file, for a host that was never asked, and
for a pairing that was never granted the bit, so nobody picks a 4 MB photo over
mobile data and learns afterwards. Progress is reported as slices the host has
actually acknowledged — a 4 MB photo is thirty-two of them. A prompt carrying a
file answers `offered` and the phone says *"Waiting in the desktop's message box
— send it from there"*, not "sent", because a person at the desktop still has to
press Enter.

The five `flutter_*` tools an agent could not reach are served, and `BACKLOG.md`
was split, with the closed half moved verbatim into `SETTLED.md`.

---

## 1.18.2 — 2026-09-07 (build 34)

**Everything found by using 1.18.1 for an afternoon.** The build number is
deliberately unchanged: 1.18.1+34 and 1.18.2+34 are different binaries, and on
Windows the installer filename is what tells them apart. An Android companion
at the same `versionCode` reinstalls over itself locally but cannot be
distinguished from its predecessor, and Play would refuse it.

### Fixed: the shell threw on its own status bar

Two exceptions and two ~98,000px `RenderFlex` overflows, on an ordinary session
launch:

```txt
setState() or markNeedsBuild() called during build.
  This _ChangesSurface widget cannot be marked as needing to build…
  The widget which was currently being built was: ShellStatusBar
Bad state: Tried to rebuild Provider<List<Repository>>#83d42
  multiple times in the same frame
```

`ShellStatusBar` and the side panel's `_ChangesSurface` both wanted the name of
the selected repository, and both got it by watching a
`Provider<List<Repository>>` and picking one element out. A `List` has no value
equality, so a rebuilt one is never `==` to the last and Riverpod's dedupe can
never fire: every announcement reached both widgets whether or not the
repository had changed. They are siblings, and Flutter allows only a
*descendant* of the widget being built to be marked dirty — so one redundant
announcement during the build phase threw, and took the frame's layout with it.
That is where the absurd overflow numbers came from; a layout pass that throws
part-way leaves the tree measured against unbounded constraints.

**The obvious fix was the wrong one, and there is now a test saying so.**
Guarding `ProjectsController._refresh` with `listEquals` silences the redundant
announcement — and also the only signal a new repository has, because
`ProjectService.rediscover` adds repositories to an *existing* project without
touching one project row and the repositories table has no notifier of its own.
That would have traded an exception for a stale panel. So the list keeps
announcing freely and `selectedRepositoryProvider` absorbs it: `Repository?`
has value equality, so a re-read that found the same row reaches nobody and
neither sibling rebuilds at all.

### Fixed: sending a note or a todo to a session did nothing visible

Broken since 2026-09-02, by a change that was right on its own terms.
`bb4283f0` stopped the workbench mounting a session's conversation until it had
been asked for — it was a whole-transcript read on every tab switch — and the
composer a note lands in *is* that conversation. Send was an unnamed asker, so
text offered to a session showing its terminal queued a draft into a box that
did not exist, under a snackbar claiming it had arrived.

The perf change stays: an ordinary tap still reads no transcript. Sending is now
an explicit asker, through the mirror of the reveal that already existed for the
other face — `revealConversationForPane`, which inherits the rule that matters
once the workspace is split: *that* group, not whichever one has focus.

A pane is required, and that is not a detail: falling back to the focused group
would open whichever *other* session it holds, so a note offered to A would flip
a group showing B into B's chat. Without a pane the draft waits, which is what
`ComposerDrafts` is for, and the report says so instead of claiming delivery.

Why five days of green gates missed it: every assertion checked that the draft
was *queued*, never that it reached anything.

### Middle click closes a tab

The gesture every browser and editor binds, and it gets the **reversible**
close. A wheel press is mushy and easy to fire while scrolling, so it must not
be the action that kills an agent mid-turn: it runs the same
`shouldDetachOnClose` policy the tab's own X does, which parks a pane holding
real work and releases an idle shell — one gesture behaving correctly for both
without a second one to tell them apart. Ending a session stays behind a menu
item with a word on it.

It lives on the chip both strips share, so a window split into groups behaves
the same in every one of them.

### A `file://` URL in the terminal is a link, and it is a path

`/insights` prints `file:///home/<user>/.claude/usage-data/…html` and there was
nothing to click. It fell between the two scans: the path scan skips anything
with a scheme in it, and the URL scan rejects any scheme but http(s).

That rejection is deliberate — terminal output is untrusted and must not reach
a scheme handler — and it applies to `file:` more than to most schemes. So the
allowed schemes are unchanged. A file URL resolves to a **path**, which means
it goes through the translation that already existed:

```txt
WSL non-/mnt path /home/x  ->  Windows UNC \\wsl.localhost\<distro>\home\x
```

and then through reveal. A host is refused: `file://server/share/x` is a UNC
path, and revealing one makes Windows authenticate to a share whose address came
from whatever printed the line.

### The phone's clipboard, and a real file manager

Copy on Windows and paste on the phone, and the reverse. There is **no adb
route** — `cmd clipboard` answers *"No shell command implementation"*,
`dumpsys clipboard` prints nothing, and `service call` structurally cannot
carry a `ClipData`, which is a parcelable and not among the argument types that
binary can marshal. What works is scrcpy's control socket, which this app
already opens for touch and keyboard, and the reason it can read a clipboard adb
cannot is a permission: scrcpy-server runs as the shell uid and presents as
`com.android.shell`, which holds `READ_CLIPBOARD_IN_BACKGROUND` and is therefore
exempt from the Android 10+ foreground-or-IME rule. No companion app, no new
dependency, and every wire constant read out of the bundled jar rather than
guessed.

Two costs stated rather than hidden. It needs the live view running, because
without a stream there is no control socket — both buttons disable with that
reason, deliberately not the generic adb one. And **no clipboard has yet
crossed to a real phone**: proving it needs pushing a jar and starting a
process. Whether Android 16 still grants that permission is recorded as
unknown, not assumed, so the code reports what the device answered rather than
what it expects.

Device→host costs zero processes: the server pushes on change, so nothing polls.

The device file browser gained copy, cut and paste performed **by the device** —
one `cp -p` or `mv`, so a 2 GB move costs nothing on the wire — drag onto a
folder, and host↔device transfer through the Windows file clipboard. Dragging to
and from Explorer still needs a native drop target and is not here.

### Fixed: a device id is not always serial-shaped

A wireless device identifies itself as `192.168.1.24:37129`, or as
`adb-<serial>-<random>._adb-tls-connect._tcp` — both shapes occur for one phone
depending on how adb reached it. Three host filenames were built straight from
that id, and on Windows a colon does not fail: it opens an **alternate data
stream**, so `adb pull` wrote to a stream hanging off a truncated name and the
read-back found nothing — an empty file with every step reporting success.

---

## 1.18.1 — 2026-09-07 (build 34)

**Codex could not be started or resumed on Windows at all.** It self-updated to
0.153.4, moved to a versioned standalone layout, and turned the stable path its
own installer advertises into a chain of junctions:

```txt
…\OpenAI\Codex\bin  ->  …\.codex\packages\standalone\current\bin
                    ->  …\releases\0.153.4-x86_64-pc-windows-msvc\bin
```

Windows refuses to traverse that — *"the path cannot be traversed because it
contains an untrusted mount point"*, errno 448 — while Settings went on showing
a healthy-looking Codex row, because the row was reading a value written once by
the workspace's first scan. WSL and SSH sessions were unaffected: DrvFs resolves
junctions itself.

### A stored path is state; whether it resolves is a measurement

The check runs on every launch, behind the first frame, and it is the durable
half of this. What the resolver *finds* is `releases\<version>\…`, which the
next Codex update will move again — so the answer is not a cleverer path, it is
looking again, cheaply enough that it can afford to. A workspace with nothing
wrong costs one `existsSync` per local installation and spawns no process at
all; only rows that actually failed are re-probed.

`File.existsSync` on a path behind an untrusted mount point answers a flat
**`false`** rather than throwing, so an exception cannot tell an unreachable
file from an absent one — any check built on catching one reports a working CLI
as uninstalled. What does work from plain Dart is asking about the junction
*itself*: `Link.targetSync()` and `typeSync(followLinks: false)`. The resolver
walks a path one component at a time on that basis, so the traversal the OS
refuses never happens, and the reparse walk — not an errno — is the
discriminator: a route that completes and finds nothing is `missing`, a route
that cannot be completed is `unreachable`.

Nothing in `path_probe.dart` knows the word "codex", so the next tool to install
itself behind a versioned junction is already covered.

### Three rules the reconciler follows

**An unreachable row is never deleted.** A junction chain answers `where`,
`existsSync` and `Process.run` exactly like an uninstalled CLI, and deleting on
that evidence turns *"installed somewhere I cannot reach"* into *"not
installed"* — the worse of the two, because it takes the agent out of Settings
and leaves nothing to correct. It gets its own line and is counted among neither
found nor missing.

**A move keeps the row and its id.** The id is what settings pin as the default
agent and what every session references; the earlier delete-and-reinsert
repointed the sessions and silently unpicked the default.

**A working hand-set path is never overruled by a sweep.** Recorded in schema
v39 as `executable_by_user`, the way `sessions.title_by_user` already is — and
never inferred from "the path differs from what discovery would find", which
cannot be recovered after a restart. A hand-set path that stops working is still
repaired, and reverts to detected, because a stale path helps nobody whoever set
it.

### Executables are editable, and per-environment scans see the junction too

Settings → Agents → Executables lists what is stored, what each path currently
measures as, and when that was measured. A path can be typed or browsed to, and
the same sweep the launch runs is available as a button.

The per-environment scan had the same blind spot and is fixed with the same
probe, so a host that reaches an agent through a junction is no longer reported
as not having it.

### Pair a phone over Wi-Fi, both ways Android offers

**Wireless debugging, from the device pane's toolbar.** A QR code the phone's
*Pair device with QR code* screen scans, and the six-digit code its *Pair device
with pairing code* screen shows — both, because Android offers both and each
fails in situations the other survives.

It went in the toolbar rather than the section header because
`DeviceSectionHeader.action` is unreachable exactly when it is needed: the list
collapses to nothing when there are no devices, no AVDs and no simulators, which
is the state of a machine with no cable. Settings is wrong in kind — pairing is
an act, not a preference, and Settings → Tools is a read-only health surface
(§19). The button appears only where adb does, and the pane's empty-state
sentence now names pairing as one of its ways out.

**What was read out of adb rather than guessed.** Every string the parsers match
was lifted from the shipped `platform-tools 37.0.0` binary — `Successfully
paired to … [guid=`, `Failed: Wrong password or connection was dropped.`,
`Failed: Unable to start pairing client.`, `ERROR: mdns discovery disabled`, and
both spellings of the daemon banner (`adb discovery` and `Openscreen
discovery`). `already connected to` counts as success rather than a lost race,
because `ADB_MDNS_AUTO_CONNECT` means adb may well have connected first.

Two things are reasoned rather than observed, and are marked as such: the
`WIFI:T:ADB;S:…;P:…;;` payload, which adb never parses because the phone's
Settings app does, and the tab-separated shape of an `mdns services` row, which
needed a phone advertising to see. The row parser is built for that uncertainty
— tabs with a whitespace fallback, a trailing `.` stripped from the service
type, the port split at the **last** colon so an IPv6 host keeps its own, and
any row that is not three fields with a valid address dropped rather than
half-read.

**Failure states say which failure it was.** mDNS switched off in adb and mDNS
that could not be checked are different sentences — §19's rule, applied to a
new probe. A pairing port that does not answer names both of its causes, since
adb cannot tell them apart: the phone's dialog has closed, or the two are not
on the same network. Pairing that succeeds without a connect port advertised is
its own state rather than a failure, and it says where to read the port off the
phone — a different port from the one in the pairing dialog, which is the
mistake this flow exists to prevent.

**What it costs, counted at the `CommandRunner` seam.** A QR pairing that works
spends five adb spawns, a typed one three, mDNS switched off one, and a
malformed address or a short code none — refused before a process exists. A
pairing nobody answers stops at 61: `kMdnsPollBudget` of 60 at two seconds,
which is longer than anyone holds a phone up. The interval is a cancellable
`Timer` rather than a bare `Future.delayed`, because the widget tests caught the
naked version as a pending timer after teardown — a wake-up for a closed
dialog. The provider is `autoDispose` and the dialog holds its only listener, so
closing it ends the watch, and a test asserts the spawn count stops rather than
timing anything.

**The invite is a secret, and the redactor could not see it.** A QR payload
delimits its password with `;` rather than assigning it to a keyword, so the
catch-all rule missed it; `pairing code` written with a space — how a human and
adb's own prompt write it — missed too. Both closed, with the service name left
intact, because that is how one attempt is followed through a log. One residue
is unavoidable and worth stating: `adb pair host:port <code>` puts the code in a
process command line, visible in the host's process list. That is adb's CLI,
and Android Studio does the same.

`qr_painter.dart` moved to `core/widgets/`, since the remote-access pairing
dialog and this one now draw with the same painter.

### Fixed: a device id is not always serial-shaped

A wireless device identifies itself as `192.168.1.24:37129`, not as a hardware
serial, and three host filenames were built straight from that id. On Windows
the colon does not fail — it opens an **alternate data stream**, so `adb pull`
writes to a stream hanging off a truncated name and the read-back finds nothing:
an empty screenshot with every step reporting success. `fileSafeDeviceId` maps
anything outside `[A-Za-z0-9._-]` to `-`, leaving hardware serials and
`emulator-<port>` byte-identical.

Audited and found already safe: `parseAdbDevices` splits on whitespace and keeps
the colon, `isEmulator` tests a prefix so a wireless phone gets the hardware
encoder like any handset, scrcpy names its jar and socket from a random `scid`,
and the device picker reads its ids back by length rather than by splitting on a
colon.

Two things are deliberately unchanged. There is no `adb disconnect` — a wireless
device can still only be dropped from outside the app, which is the obvious next
row action. And with two ready devices and no explicit choice,
`selectedDeviceProvider` picks nothing: pre-existing, identical for a second USB
phone, and now pinned by a test rather than left to be discovered. A cabled
phone showing by default will stop being the pane's device when a second one
connects, until the picker is used.

### Not fixed here

An endpoint antimalware product quarantined this app's whole installation on
this machine twice on 2026-09-07 — every plugin DLL, the uninstaller, the Start
Menu shortcuts and the app's own MCP session files. Nothing in this release
addresses that: an unsigned executable that spawns processes and binds a local
socket is what tripped it, and the answers are a policy exclusion or a signing
certificate, neither of which is code.

`sessionDirectoryPresentProvider` still ends `on Object { return true; }`, so a
session can still be spawned into a directory the OS will refuse. That is a
change to session launch rather than to agent discovery, and it is written down
in `CLAUDE.md` §20 rather than folded in here.

---

## 1.18.0 — 2026-09-07 (build 33)

**The phone can manage projects and resume sessions, not just watch them.** Add
an existing desktop folder as a project from the companion, list the projects it
can see, and resume a session rather than only starting a new one.

### The capability split is the interesting part

Adding a project is genuinely new power — it takes a folder on the desktop and
makes it a project — so it gets its own bit, `addProject`. A phone paired before
this build holds a bitset without that bit and is refused, in words, for ever.
That is the rule the protocol already stated for `startSession`: nothing already
granted quietly grows into permission to do more.

`session.resume` reuses `startSession`, because resuming runs a process, and a
phone that may not start one may not resume one either.

`projects.list` reuses `viewSessions`, which **does** widen an existing grant: a
phone paired earlier can list projects without being asked again. It learns no
name it could not already read — it already sees those sessions grouped by
project — so this is deliberate rather than an oversight, but it is a widening
and worth knowing.

`project.add` refuses unsafe paths without writing anything. That is the defence
that matters once a remote device can name a folder on this machine, and it is
tested as a refusal rather than assumed.

---

## 1.17.2 — 2026-09-06 (build 32)

### A terminal selection can become a todo or a note

Right-click a selection and keep it. Both open a pre-filled composer rather than
saving on the spot — the app's two existing patterns disagreed, and the
discriminator is whether the captured thing is a unit somebody wrote. A
transcript message is; a rectangle of characters dragged over a terminal is not.

Provenance comes from the pane's own session and nowhere else: not a sibling
pane in the same tab, not the Explorer's selection, not the panel's filter. A
pane with no session tags nothing and says "No project" — `Todo` already held
that null is a first-class answer, not a hole to fill with a guess. A selection
is not a message, so the message ordinal and role stay null.

A multi-line selection collapses for a todo and the composer says so — "N lines
were joined into one" — because a selection carries each row's padding out to
the right edge, and joining alone is not enough. A note keeps it byte for byte.

### Sending a note or a todo to the session you are working in

Both offer their text to a session's message box through the existing composer
queue, which offers rather than taking the person's turn.

The Notes card used to subscribe to a session just to name and disable its Send
button, which put every source-less card on a signal that changes whenever the
active session does. It resolves on the click now. A note that came from a
session still names its target — that is on its own row, and free. A source-less
one says "the active session" and answers an empty click with a message rather
than sitting greyed out; a card that refuses to watch the state cannot gate on
it either.

The cost test that guards this panel got stronger: changing session went from
repainting one card to repainting none, and because zero rebuilds could be
bought by a card that simply stopped working, it now also asserts that tapping
afterwards still reaches the new session.

### Fixed: the Android live view did not come back

Switching the side panel to another surface unmounted the device pane, and
`_liveSerial` — the flag meaning "the live view is on, for this device" — was a
widget `State` field that died with it. Collapsing the panel and zen mode did
the same. It was never the workspace groups; the side panel is a sibling of the
workbench.

The intent now lives beside the other "which device" answer and survives the
unmount. The **session** deliberately does not: an invisible pane is worth no
handset battery and no host decode, so unmount still stops scrcpy and coming
back starts it again. A remount shows the spinner rather than a stale frame,
because holding the frame would mean holding the stream.

Found alongside it: the "stop streaming a device that went away" check read a
still-*loading* device list as an *empty* one, so a mid-refresh remount would
have destroyed the intent before the resume could use it.

The iOS Simulator path never had this bug — its state was always in a provider —
but it is the mirror image: nothing tells it nobody is watching, so its video
feed runs for a hidden pane. Left alone, because it is macOS-only and nothing
here can prove a change to it.

---

## 1.17.1 — 2026-09-06 (build 31)

A fix-only release for three things found by using 1.17.0, two of which are
older than it.

### Copying from a terminal ate the spaces

Pasting agent output gave back `Crashandanalyticsvendors.` — every gap deleted —
while the next line came through intact. `BufferLine.getText` skipped any cell
whose code point was 0 and emitted nothing at all for it. An untouched cell
holds 0, and so does a cell a CLI stepped over with a cursor move instead of
writing spaces, which is why the same paste was half right.

Blanks now accumulate and flush as spaces only when a glyph follows, so a
200-column line of `hi` still copies as `hi`, and a wrapped line's blank tail is
dropped before the continuation joins rather than injected into the middle of a
word. Two cases are deliberately not spaces: a wide glyph's spacer, which has
code point 0 *and* width 0 exactly like an untouched cell, and a run directly
after a real `HT` — spelling that one out would paste a tab plus seven spaces
and land the text at column 15 where it was drawn at 8.

Fixed in the `xterm2` fork (`5ea40a7`).

### A group's chat showed the window's selection

Introduced in 1.17.0. A group drew its own tab's panes on the terminal side and
the Explorer's selection on the chat side, so picking `s1`, clicking that
group's `s3` tab and pressing Chat read `s1`. With two groups it was worse: a
selection with no pane was drawn by whichever group held the keyboard, and
moving focus dragged it across — moving the keyboard is not a request to see
something.

A selection that has a pane already resolves itself, because opening it focuses
the group holding that tab. One with no pane has no tab to become, so the group
it was opened into is recorded and only that group draws it.

### A conversation could stream another session's events

Older than the split, and unrelated to it. `sessionTranscriptProvider` and
`selectedSessionRepositoriesProvider` were keyed on the Explorer's selection
from inside a view that has always taken its session as an argument — so a
conversation titled `s3` streamed `s1`'s events and listed `s1`'s repositories.
Both are families keyed by session now, so the compiler stops the next one.

### Also

A still Android phone froze its own live view. media_kit's `network-timeout` is
finite at 5 s and a static screen sends no frames, so libmpv decided the stream
had ended and paused; the app then re-attached the player, saw the same, and
looped. The session already knows whether scrcpy is running, so it owns liveness
and the timeout is off.

---

## 1.17.0 — 2026-09-06 (build 30)

**The middle workspace splits like VS Code's editor groups.** Until now a split
divided only the terminal area, under one tab strip and one status bar. The unit
is a whole group now — its own tab strip, its own content, its own status bar —
and the splitter divides those. Tabs drag between groups and carry everything
with them, because a tab *owns* {session, terminal, chat, status} rather than
pointing at one.

Three agents side by side each keep their own tabs, their own repository and git
state, their own model, and their own usage budget counting down separately.

### Two words, and only two

A **group** divides the workspace and holds tabs. A **region** divides one tab
and holds panes. Those are now the only two words used for it in the palette,
the menus, the tooltips and the domain doc — "move a tab into this split…" named
neither and is gone. The palette gained split commands in both directions for
both acts; it had none at all before.

A tab dropped on a division makes a **group**, never a bare region. The Ctrl-drop,
the region header, the empty region and its picker, and the palette all refused
to be the exception, and the five methods that allowed it were deleted rather
than left unreachable — which retires by deletion a latent bug where
`splitPaneWithTab` removed the source tab *before* an early `return false`.

### The chrome went up, because a group is narrow

The seven-button cluster — find, snippets, commands, `+`, the profile chevron
and the two splits — moved to the title bar. Applying one test to each, *does it
need to know which group?*, none of them did. A group is left with just its tab
strip, which is the reference exactly. Compact widths keep `+` and its chevron,
because dropping the row wholesale would leave no visible way to make a terminal.

The status bar then still did not fit: **413px of content in 363px**, and 286px
is a group's ordinary width once the workspace is split a few ways. Below 820 it
drops the model chip, below 560 the words but never the glyphs, tooltips or
semantics labels, and below that it scrolls rather than squeezing. Deliberately
no overflow menu — `Commit` is what most visits to that bar are for, and two
clicks away is worse than small.

### Focus is visible

A tab chip has three states, not two: not showing, showing, and showing-and-
focused. Exactly one strip in the window draws the third. Unfocused groups keep
their selection, because deselecting them would make their terminal and status
bar appear to belong to nothing.

### Fixed

- **The attention inbox could badge a session you were looking at.**
  `foregroundTerminalPaneIdsProvider` decides that a visible pane raises no
  notification, and it read the *focused* group's tab — so with a split
  workspace it would have badged sessions plainly on screen in another group.
  Found while making chat per-group, not by looking for it.
- **A write reachable from a read path.** The group tree was reconciled inside
  `_snapshot`, which `build()` calls. It reconciles on publish now, and a
  debug-only diagnostic reports which write landed inside a build — Riverpod's
  own message names no location, which is why that error has to be hunted
  rather than read.
- Chat is part of the group, so three agents can show three transcripts at once.
  The transcript poll gate asks whether *any* group is showing chat, so nothing
  polls while every group is on its terminal.

### Known, not fixed

A group has no minimum width. `kMinPaneWeight` is 5%, so a group can be dragged
to about 70px; the status bar survives that by scrolling, but a terminal there is
roughly ten columns. The repository selection is still workspace-wide rather than
per group, and a divider drag is not persisted until the next structural save —
which the in-tab divider already did.

---

## 1.16.0 — 2026-09-05 (build 29)

### A Codex rename shows the moment Codex makes it

Renaming a conversation inside Codex used to take up to ten seconds to reach
the sidebar, because the name only arrived on the status registry's store
sweep. The app-server emits `thread/name/updated` on the same pipe as its
replies, and the client had been dropping every id-less line — correct for call
bookkeeping, where a reply that answers nobody could only be charged to the
wrong request, and wrong for this one message, which is application state. The
row now updates immediately.

**A title you typed in Karmashala is still never replaced.** This landed as an
exception to that rule — the argument being that a Codex rename is also the
user, and newer — and the exception was removed. A name typed into the app in
front of you is the answer to that conflict, whichever CLI is behind the row.
The consequence is worth knowing: rename a session here and then rename the
same conversation in Codex, and the two disagree permanently, because this side
keeps yours.

### Developer-facing

The gate runs eight testers by default, from `dart_test.yaml` rather than a
flag, so a local run and automation cannot drift apart. Measured on a quiet
machine: **5:19 at the old four, 3:24-3:40 at eight, 3:55 at thirty-two** —
past eight, contention costs more than the parallelism buys.

`docs/BACKLOG.md` records why it had been pinned at four, and why eight is safe
now: companion tests with fixed 800 ms windows flaked 0.8% per instance at four
against 26% at eight, caused by a fixture that kept no reference to its socket
so the VM finaliser closed it mid-window. That was fixed, and eight ran 153
instances clean afterwards.

It also gains what the test-harness investigation actually produced. Moving
pure logic tests off `flutter_test` onto `dart test` was built end to end and
**not** landed, because the finished state measured slower — 326.4s against
350.5s. `flutter test` shares one incremental compiler across every suite while
`dart test` compiles per isolate, so the comparison inverts with how much real
code a test imports; on the same 152 files the two runners were within 2%. The
priced seam table names the real lever: `app_database.dart` imports
`path_provider` for a single call and drags Flutter into 158 test files.

`tool/vm_probe.dart` samples a running app's VM service — frames, stalls, heap
— for when the Dart MCP server will not connect.

---

## 1.15.0 — 2026-09-05 (build 28)

**Karmashala stops reading Codex's files and starts talking to Codex.** The CLI
ships an app-server — JSON-RPC over `codex app-server --listen stdio://` — and
it answers `thread/list` out of its own state database in **15–49 ms**, against
a walk that opened every rollout under a date tree. Two user-visible defects
fall out of that change, and one that looked like a third turned out to be the
opposite of what it seemed.

### A session's label was Codex's preamble, not the user's words

`_extractUserMessage` took the first `role:user` `input_text` in a rollout,
which on a real Codex session is an injected preamble. Measured against the
owner's store: **15 of 16 sessions differed**, and 10 of the 16 have no name, so
that preamble *was* their whole display title.

```
ours='<recommended_plugins> Here is a list of plugins that'
srvr='You are one judge on a panel scoring content ideas f'

ours='# AGENTS.md instructions for /mnt/c/Users/dlohani/pr'
srvr='review whole codebase with a goal to make correct, p'
```

`thread/list` returns the real first message.

### A rename typed into Karmashala never reached Codex

The mirror image of the reported symptom, and the reason it resisted diagnosis.
`session_index.jsonl` is a **write-through mirror Codex maintains and never
reads**; `state_5.sqlite`'s `threads.name` is authoritative. Proven by planting
a sentinel in each under an isolated `CODEX_HOME`: the file's was ignored and
left untouched on disk, the database's came straight back.

So `_renameCodex`, which rewrote that file, wrote somewhere Codex would never
look and would overwrite on its next naming event. `renameNative` was worse —
it wrote the row and propagated to no store at all, so a Codex session launched
by Karmashala and renamed here reached nothing.

Both now call `thread/name/set`. A Codex that cannot be reached leaves the local
rename applied and writes **nothing**; the tests assert that as a positive,
because a consolation write is exactly how the original bug looked fixed.

### Parity, because the default silently drops sessions

`thread/list` with `sourceKinds` omitted applies an "interactive sources"
default and answered **11 of 16** real threads on the owner's store — the `exec`
ones vanished. Every kind is now sent explicitly, and a test asserts the full
list on every page. Verified live: 16 threads, matching the 16 rollout files
exactly, same ids and same six names. On the Windows install, 45 threads
against 51 files on disk — the six extra are a pre-`session_meta` rollout format
from 2025 carrying no `cwd`, which the file walk has never surfaced either.

The walk stays as a per-install fallback, chosen per Codex rather than globally,
with a backoff counted in scans rather than seconds.

### Expanding a project no longer scans the CLI stores

Expanding scanned every store — and so did merely *selecting* a project, so an
expand cost two walks. Five expands went from **5 scans to 0**. The import now
runs once per app lifecycle, after the first frame, on a `karmashala.store-scan`
isolate, with a refresh kept in each project's menu and a freshness stamp that
is only written by work that actually re-read the stores.

The Claude store turned out to be *addressable* — a working directory maps to
the `projects/` subdirectory name Claude writes it under — so that walk narrows
instead of listing 663 files across 2.6 GB.

**No date cutoff for Codex.** A day folder's mtime moves when a rollout is
created but not when one is appended to, so a mtime-gated walk would silently
drop every resumed conversation. Measured, rejected, and recorded where the next
person will look.

### Creating a process no longer blocks the thread that draws

`Process.run` only looks asynchronous: `CreateProcessW` runs on the **calling**
thread before the future exists. Spawning moved to a worker isolate, git probes
are bounded and kept out of the frame that draws them, and two questions that
were being answered by spawning `git` — "is this a repository?" and "what is
origin?" — are now read off the filesystem. A checkout's status reads as
`--porcelain=v2`, so ahead/behind come from a call the row already makes.

A pane whose folder is not a repository says so, instead of showing a
`GitException` after Riverpod's ten retries had spent 38 seconds behind a
spinner.

### Fixed, smaller

- A rollout rewritten in place to the same length was served from cache forever;
  mtime is now compared when the size is unchanged.
- A non-ASCII thread name reached Codex as `?`, because `ProcessHandle`'s stdin
  defaults to the ANSI code page on Windows. The protocol line is escaped.
- An agent nobody installed no longer reports as a broken machine.

### Known, not fixed

`thread/list` lowercases the `cwd` it returns on WSL — 13 of 16 rows come back
`/mnt/c/users/...`. Attribution is unaffected, since the merge key lowercases on
every branch, but a WSL Codex project's **displayed** path changes case. Windows
rows keep theirs. Left alone rather than re-casing a value the server owns.

The `cwd` staleness this change also guards against — Codex re-stamps `cwd` in
every turn while the rollout's header keeps the original — was **not observable**
in the owner's store: no rollout there has a `turn_context` cwd differing from
its `session_meta` one. That half is preventive, not corrective.

---

## 1.14.0 — 2026-09-04 (build 27)

**The first release driven by a profile of the app running against the owner's
real database.** They ran 1.13.0+26 in profile mode and reported *"very slow
initially"*, *"explorer is loading something that made the ui laggy for quite
some time"* and *"it's taking a lot of memory and cpu"*. Every change here
answers a measurement rather than a suspicion, and two suspicions were measured
and discarded.

### Startup: 1053 ms of 1910 ms leaves the critical path

From the app's own log, `Agent hooks: 6 installed` took **1053 ms — 55% of a
1.91 s launch**. `AgentHookInstaller` did every file operation synchronously,
and some store homes are inside WSL, reached over `\\wsl.localhost` where a
synchronous Dart file operation has no timeout.

Counted per `(agent, store home)` pair: a normal launch put **60 synchronous
file operations on the UI isolate, 30 of them across the share**, and 18 more on
quit inside a 150 ms shutdown step that could not interrupt them — a cap can
only stop an await. Now zero synchronous operations on that path, nine async
ones on a normal launch, the sweep concurrent per pair, and the whole thing
below `runApp` behind `endOfFrame`.

Why that matters beyond the second: the freeze investigation in 1.13.0 proved a
native file dialog runs its modal loop on the platform thread, which *is* the
Dart isolate's thread — so every synchronous WSL read on that isolate was a
candidate freeze, not merely a slow one.

An unreachable store home now gets **10 seconds and reports `unknown`** rather
than blocking indefinitely or claiming "not installed" — a false negative sends
someone hunting a configuration bug that does not exist. Ten seconds because the
first touch of a WSL store home *starts a stopped distribution*.

A session started before the sweep lands loses less than the change's shape
suggests: the hook *entry* is a constant written once, so on any launch but the
first it is already on disk. What a launch writes is the *endpoint file*, which
the script reads when a hook **fires**. Settings → Tools says so until the sweep
reports.

### Sessions that name a conversation the CLI never wrote

*"i've sessions when i start new session, there are sometimes sessions without
cli sessions attached, either i need a quick button that will remove all those
or i should be able to start new session on that session which is in our db but
not in cli"*

Both, per row, neither as the other's fallback — because they preserve different
things. A bulk clear is right for debris from failed launches; restarting keeps
the row's title, creation date, lineage, pins and notes.

Restarting turned out to be nearly free. For an agent that takes `--session-id`
the launcher stamps `externalSessionId = row.id`, so **the promised conversation
id *is* the row id**: a restart is a launch with no `--resume` that reuses the
row — the same promise, re-made to a CLI that will keep it.

Finding these rows cannot be done on nullability. The id is recorded at launch,
so a dead row and a live row are identical on that field; what separates them is
*who chose the id*. Screening is three SQL statements total and no disk, and one
store listing per (store, agent) pair runs **only when asked** — O(stores), not
O(rows), nothing at startup or on a timer.

`unknown` rows get **neither** verb. An unreadable store, a stopped
distribution, a session twenty seconds old: shown and counted, never actionable,
because restarting one could abandon a conversation that is merely unreachable.
A test drives the review and the resume path over the same fixtures and asserts
they never disagree.

### The Explorer's corner

*"same icon repeated 3 times doesn't look clean"* — it was one glyph meaning
three things. `AppIcons.treeStructure` stood for the Explorer surface, a
project, and the whole workspace's scope, and their centres sit at x=17, x=18.5
and x=16 in rows 30px apart. Same mark, three sizes, one column.

Now: `treeStructure` is the surface alone, `folder` one project, `folders` all
of them, `stack` a context — plates in a pile, because a context holds projects
and is not a place on disk. The closed scope bar wears the glyph of whichever
menu row is selected, so the control and its menu agree; "no context" used to
draw a folder, which was wrong twice. The Explorer's pane header drops its glyph
entirely, because the title-bar toggle draws that exact mark 30px above it in
the same column.

Measured while there: the chrome above the list is **109px — 2.02 project
rows**, 12% of the column at 1440x900 and **21.5% at the 720x560 minimum**. The
pane title gets `paneWidth − 185`, of which 150px is five icon buttons, leaving
**2.6px of headroom** at the default width and 125% text — which is why the
labels in the screenshot were all truncated. Now 23.6px.

### Measured and discarded

Two things this release does **not** change, because the numbers refused them.

**The glyph atlas is not rebuilt per frame.** It looked like it — `CreateGlyphAtlas`
runs exactly 1.00 per frame — but every call is 0.19–0.83 ms with no call over
1 ms and no tail. A real rebuild would show one expensive call and cheap ones.
It is Impeller's normal incremental path finding its glyphs already cached.

**CPU is not being spent in Dart.** In a 60 s window Dart accounted for 2.5 s —
about 4% of one core. The work counts are also exactly 1.00 per frame for every
raster operation, so nothing is drawn twice. What the profile *does* say is that
`io.flutter.raster` does **3322 ms of work against the UI thread's 860 ms** —
roughly 4:1, on the OpenGL backend. This app is raster-bound, so build-side
tuning has little left to give and the terminal's painting is the cost centre.

### Still open, deliberately unclaimed

The Explorer's per-row git probes — three to five subprocesses per visible
checkout, every one crossing the 9p boundary into WSL — are **not** fixed here.
That is the *"laggy for quite some time"* half of the report and it is being
worked on separately. `CliStoreLocator.locate` also still resolves each WSL
`$HOME` through a serial login shell, which is likely a large share of what
remains of startup. And ~100 MB of non-Dart memory growth over a session is
measured but unattributed; it is native, and that is all the evidence supports.

---

## 1.13.0 — 2026-09-04 (build 26)

**SSH hosts become real workspaces, and five things the owner reported in one
sitting are fixed.** Every fix below started as a report from using 1.12.0, and
three of them turned out to be caused by something other than the obvious
suspect.

### SSH hosts: clone, sessions, terminals

A remote host is no longer a place you can only reach — you can clone a
repository onto it, run agent sessions there, and open a plain terminal on it.
Picking a project folder on an SSH target browses **that host** over SFTP
instead of opening a local dialog that cannot see the remote disk.

### Shift+Enter inserted two newlines

Not the dictation change that enabled the text-input path — measured identical
with it on and off. The **xterm2 migration**: xterm 4.0.0 dropped key releases
before they reached an input handler, and xterm2 forwards them so the kitty
protocol can report them. Every handler in xterm2's own chain opens with a
release guard; ours was written when releases did not exist, so it encoded
`ESC CR` on the press *and* on the release. Plain Enter never doubled, because
it is delegated and the keytab guards its own release — the same reason Ctrl+C
was fine. One line, and the bytes on the wire are now `['\x1B\r']` where they
were `['\x1B\r', '\x1B\r']`.

### A message sent from the phone typed but never sent

Also not the chat redesign — the submit path is byte-identical across it.
`TextField` chooses its keyboard when you do not name one, and `maxLines > 1`
makes it `TextInputType.multiline`, which Android draws with Return instead of
an action key. No action was ever reported, `onSubmitted` was never called, and
the key inserted a line break. The send button always worked, which is why the
desktop looked fine. The keyboard now draws Send, and the box keeps focus after
one.

### Browse froze the window

Reported as a crash; it is a hang, and the file picker is the victim rather than
the cause. `IFileDialog::Show` runs its own modal loop on the platform thread —
which, in the Windows embedder, is the Dart isolate's thread. An occupied
isolate therefore leaves the dialog **created and never shown** with both
windows Not Responding, recovering only when the isolate frees. Measured: the
`#32770 "Open"` window exists with `visible=0` and `IsHungAppWindow=1`.

So the picker was never the bug. `AgentHookSpool.drain` was doing synchronous
`existsSync`/`listSync`/`readAsStringSync` over `\\wsl.localhost` **every 400
ms**, with three spool directories live; it is now async. Every picker call
announces itself to the log and **flushes** first, so a recurrence names the
button — which it could not before, because `LogFileSink` queues behind its own
400 ms timer *on the isolate that is about to stop*. That is why the log ended
mid-run with no exception and read as a crash.

**Still open**, and deliberately not claimed as fixed: `flutter_pty`'s
`Pty.start` cost 1.6 s of isolate in a measured run, and `flutter_pty_win.c`
already documents `ResizePseudoConsole` sometimes not returning at all. The
instruments that measured this are kept in `integration_test/` and
`tool/verification/`.

### An Antigravity session showed no transcript

Correct, and now it says so. Antigravity's conversation store is protobuf in an
unpublished schema, so there is nothing readable to show — the desktop terminal
shows live PTY output, not a parsed transcript. The desktop knew the reason and
sent the phone an empty list, indistinguishable from "this session has not
spoken yet", so the phone had to hedge across both. The reason now travels, as
a field rather than a new action; every *other* empty case stays unexplained on
purpose, because inferring one would be a guess.

### The chat redesign, measured

The composer's text area was **19px of 113px** — 17%. The largest single item in
the remaining chrome was a permanently drawn `Enter to send · Shift + Enter for
new line` strip at 31px, bigger than the field, and at 390 wide it overflowed
its row by **138 unclipped pixels**. Text area is now 57px; the hint moved to
the send button's tooltip.

Inter-message spacing ran 49/41/49/41/46/44 — four values encoding nothing,
traced to one card's unexplained 8-top/12-bottom asymmetry plus each card
paying its own padding inside a list that already padded. Now one margin, 11%
tighter over seven messages.

Two bugs found while measuring: the input painted a second hard-edged surface
inside its own rounded card (`filled: true` still paints under
`InputBorder.none`), and both composer buttons rendered 18px because the theme
is already `VisualDensity.compact` and the redesign subtracted that a second
time. The empty state's four prompt chips all overflowed at 390 and are gone
from desktop, where Ctrl+P and Snippets hold phrases the user chose themselves;
the phone keeps them, where typing is expensive.

On mobile: the message box went 24px → 56, tile gutters 48px → 16/22, the hint
stopped changing size when you typed, and its contrast came up off 3:1.

### Also

A `dial_honesty` test gave a real loopback connect and a hello 300 ms between
them, so under gate load the verdict inverted — a relay that *had* taken the
socket was reported unreachable. The last two raw NUL bytes in source are
escaped, which is what made one file undiffable and invisible to `grep`.

---

## 1.12.0 — 2026-09-04 (build 25)

**A false "Agent finished" no longer fires mid-turn, and the quota belongs to
the session rather than to the app.** Sixty-two commits, most of them
correcting something the app claimed and could not see.

### Notifications told you a turn had ended when it had not

Claude Code runs a `Task` subagent as *background work*: the main thread fires
a real `Stop` the moment the worker launches, then wakes on a fresh
`UserPromptSubmit` when it returns. Read as `idle`, that announced **"Agent
finished"** three seconds into a turn with ten to run — and for a real
subagent, its whole run early. The CLI hands over the discriminator and
documents it for exactly this: a non-empty `background_tasks` means paused, not
done. `session_crons` is deliberately not consulted, because a `/loop` session
really has finished and is waiting on a clock.

Two more, from reading the installed 2.1.260 rather than the 2.1.258 the
comments were written against:

- **A finished turn can now say what finished.** `Stop`, `StopFailure` and
  `SubagentStop` carry their prose under `last_assistant_message`; only
  `Notification` uses `message`, so every completion toast had been a session
  name and nothing else while the answer arrived and was discarded.
- **Four `Notification` subtypes that stop a session dead** — two elicitation
  dialogs and two quota-resume notices — were unmapped, so a session parked on
  one kept reporting `working` indefinitely. Nothing else can see them: a
  transcript cannot express "a dialog is open".

`SubagentStop`, `SessionStart`, `PreCompact` and `PermissionRequest` remain
undeclared, each for a stated reason.

### Usage: per session, and at a rate the payload dictates

The chip moved out of the app status bar into the terminal session's own bar.
Panes run different agents and different accounts, so one app-level figure
attributed one account's remaining quota to a pane spending another's.

The 60-second poll turned out to bound **one** of five triggers.
`SessionChangeKind.status` — published from ~10 sites on every launch, every
pane that stops, every project rescan — was unbounded, as were the chip's own
click, Settings' refresh and the MCP tool. The floor now lives inside
`AgentUsageService.fetch`, ahead of the 429 check, so no caller can route
around it, and it is **derived from the reply**: every window is a percentage
of a named period, so one point of a five-hour quota is three minutes, and
polling faster spends requests to re-read the same integer. An idle ladder
reaches fifteen minutes and collapses the instant anything moves, clamped never
to overshoot a window's own reset.

Per account, an idle focused hour costs **6 requests where it cost 60 plus one
per status change**; twenty runs ending at once cost one; the ceiling is 20/hour
whatever asks. A 429 or 5xx is now a wait rather than a failure — `Retry-After`
when the server sends one, else 1m→2m→4m→8m→16m jittered upward only, per
account. Every surface keeps its last number **with its age**; a reading never
observed shows the question glyph, never a zero.

### The database

Query plans were extracted for all 84 `SELECT`s in `lib/`. Two scans on the one
table that grows are now indexed (v36, v37), including the cost no plan shows:
foreign-key enforcement made deleting one installation two whole-table scans —
998 fullscan steps at 500 sessions, now none. `journal_mode = WAL`, with
`synchronous = NORMAL` gated on WAL actually being adopted, because that
setting under a rollback journal risks corruption rather than mere loss: one
scrollback autosave had been writing 86,696 bytes of journal on top of the
pages the database received, twice fsynced, on the UI isolate.

**`karmashala.sqlite` alone is no longer a complete backup** — `-wal` and
`-shm` sidecars now sit beside it. A crash or kill loses nothing; only an OS
crash or power loss can roll back the last seconds.

Three optimisations were measured and **declined** with numbers: `cache_size`,
`mmap_size` (an I/O error becomes a segfault) and `page_size` (which made the
hot read worse). No index on `sessions.status`, which would tax the app's most
frequent write forever to save one scan at launch.

### The interface

- **Right-click menus everywhere on desktop** — Todos, Notes, Inbox, Files,
  worktree chips, Snippets, Env vars, SSH hosts, all of Explorer — each
  answering right-click, `Shift+F10`, the Menu key and a screen-reader action.
  Two surfaces had right-click and **no keyboard path at all**; a Notes card
  with a disabled Send button had no focus stop, so its menu was unreachable.
- **Hovering an Explorer row no longer repaints the row.** The hover flag went
  through the card's builder, so crossing one row rebuilt every chip, note and
  glyph in it — twice. Menus are built on open now, not on every build of every
  row.
- **A split's two headers stop reading as one drawn twice.** Both rows drew the
  same widget at the same height; the region header is now its own shape, and
  the tab renames itself as soon as the split exists rather than once both
  halves are filled.
- Tabs drag along the strip to rearrange. A tab switch resizes no terminal grid.

### macOS

Discovery probed with `$SHELL -lc`, which reads `~/.zprofile` but never
`~/.zshrc` — where most Macs set `PATH`, including the line Claude Code's and
Codex's own installers add. Launched from Finder, the app found neither agent
while both worked in a terminal. Invisible during development, because an app
started *from* a terminal inherits the terminal's `PATH`.

One uninstalled CLI also stopped the app seeing any of them: the re-detection
sweep deleted rows that `sessions` references `ON DELETE RESTRICT`, and the
raise from mid-loop killed the whole sweep. A missing installation is now
either *moved* (its sessions repointed, so they stay resumable) or *gone*
(deleted only if nothing depends on it).

### Security

A prompt reaching a WSL pane can no longer be executed by the distribution's
login shell. `wsl.exe … -- <command>` is not an argv hand-off — the line is
parsed twice, and Windows quoting satisfies only the first parser, so
`` `id -u` `` ran and `$(touch …)` created files. The whole quoted command is
now base64, the POSIX counterpart of what the Windows path already did with
`-EncodedCommand`.

### Also

System health is probed rather than stat-ed, with four verdicts and the age of
its reading. An agent can read and move a device's files. Explorer filters
sessions by agent. `codex_accounts` gives Codex the account visibility Claude
already had.

---

## 1.11.0 — 2026-09-03 (build 24)

No release notes were written at the time; this entry is derived from the 19
commits in the range, and says so rather than implying a summary that existed.

Device file browsing and transfer, per driver capability, reachable from an
agent as well as the UI. A session can say where it runs, and the project's `+`
starts one without a dialog. OSC 8 hyperlinks are honoured through the link
path that already existed. Search paints through xterm2's own highlight API,
and `KarmashalaMouseHandler` was dropped for xterm2's own.

Fixes: an idle nudge is no longer called an approval; the inbox says what the
agent said, as the toast does; a missing agent is no longer blamed on its
config; density follows the input device rather than the window width; tearing
down a live pane no longer raises an unhandled exception. The release history
for 1.1.0–1.10.2 was written in this range.

---

## 1.10.2 — 2026-09-03 (build 23)

**The version to be on.** It carries 1.10.1's fix for the 1.10.0 freeze, plus
macOS and device-tool fixes that were missing from the 1.10.1 binary.

1.10.1 was built without pulling first, so fixes that were already on the branch
never made it into the binary that shipped as 1.10.1. Rather than rebuild under
the same number and leave two different binaries answering to it, the version
was moved.

### Fixed

- Resizing the window after opening a pane can no longer freeze the app. (Same
  fix as 1.10.1 — see 1.10.0 below for what went wrong.)
- **macOS:** the startup log no longer warns that "agents inside WSL will not be
  able to reach this server". WSL environments only ever exist on a Windows
  host, so on a Mac this pointed its owner at machinery that cannot exist there.

### Fixed — device tools

Five issues found over a day of driving these tools against one emulator and two
simulators:

- `device_type(submit: true)` was silently ignored. There was no `submit`
  parameter at all, so the argument was dropped and the reply still said
  `typed` — a no-op that read like success. It now sends a real Enter key,
  reports `submitted` only when the key actually went, and refuses on a device
  with no keys.
- A tap could land on the invisible full-screen scrim Android puts behind every
  modal dialog, closing the dialog instead of pressing the button asked for —
  and reporting success. Such a target is now refused outright.
- `device_ui_dump` now says when a screen is painted rather than composed. A
  `CustomPaint`, a canvas game or an embedded terminal appears as a single empty
  node, so a partial dump used to read like a complete one; it now names the
  offending node and points at `device_screenshot`.
- A failed install reports how full `/data` is, and notes that uninstalling
  wipes app data. The underlying error named neither the partition nor the
  remedy.
- A WebDriverAgent that will not attach now names both its own pinned version
  and the simulator's runtime, and says that booting, screenshots and launches
  keep working without it.

Not fixed: a reported bad tap-target ranking could not be reproduced from the
evidence. Replies now name the runner-up match (`chosen from 2 matches
(also: …)`) so a recurrence is diagnosable.

---

## 1.10.1 — 2026-09-03 (build 22)

Hotfix for the freeze shipped in 1.10.0. **Superseded by 1.10.2**, which is the
same fix in a binary that also has the macOS and device-tool work.

### Fixed

- The app could freeze permanently after opening a pane and resizing the window.
  1.10.0 removed a startup delay that turned out to be load-bearing; it is back.
  The performance work it was part of stands.
- The Android emulator live view is no longer streamed at roughly a fifth of the
  device's resolution and scaled back up. A 1344x2992 emulator was being
  captured at 288x640, which is why the picture looked soft. Capture is now
  1024 on the long edge at 10 fps instead of 640 at 20; measured tap latency
  (p50) is unchanged, and the image is drawn with a better filter on the way up.

---

## 1.10.0 — 2026-09-03 (build 21)

> **Do not use this build. It shipped a defect that can freeze the app
> permanently — hard enough to need Task Manager.** Install 1.10.2 instead.
>
> Removing a one-second ConPTY startup delay looked safe: it was not protecting
> the process spawn. It was protecting every later ConPTY call. Resizing the
> window lays out the pane, which calls `ResizePseudoConsole` directly on the
> UI thread; against a console host that had not finished starting, that call
> never returns and the app never draws another frame. Opening a pane and
> resizing the window shortly after was enough to trigger it. Fixed in 1.10.1
> and 1.10.2. The verification that would have caught it existed and was named
> in the change itself, and was not run.

Everything below is real and survives into 1.10.1 and 1.10.2.

### Performance

- Starting a session no longer freezes the window for a full second. That delay
  was a bare one-second sleep inside the terminal plugin, run on the UI thread
  from the Start button's own handler — against roughly 10 ms for everything
  else in the start path combined. (Reintroduced in 1.10.1 as the safe fix for
  the freeze above; the honest fix is to stop making blocking console calls from
  the UI thread.)
- The rest of the start path went from 10.5 ms to 2.4 ms: a pane's history is no
  longer rewritten wholesale to record a single flag, a pane's stored encoding
  is carried across a start rather than recomputed, and a restored pane parses
  its history at the width it will actually be drawn at instead of at 80 columns
  and reflowing in the same frame.
- A row that claimed to be running a process that had already gone was costing a
  status subscription and a store sweep per stale entry.

### Fixed

- **Devanagari was rendering the wrong letters, not merely rendering badly.**
  Glyphs that overflowed their cell were clipped, and in Devanagari the
  right-hand vertical stem *is* the letter — क rendered as व, झ as इ. Clusters
  that overflow are now condensed instead of clipped.
- A session row no longer claims to run a process that is gone.

### Added

- Tabs say what the agent in them is doing.
- Going to a session's tab retires its inbox item.
- Double-clicking the empty part of the tab strip opens a terminal.

---

## 1.9.0 — 2026-09-03 (build 20)

### Fixed — things that were failing silently

These three matter precisely because they never announced themselves.

- **Dictation and IME could not reach a terminal pane at all.** The pane never
  opened a text-input connection, so physical keypresses worked while anything
  injected through the platform's text-input service went nowhere. This is why
  dictation worked in quick open — an ordinary text field — and did nothing in a
  pane. (The flag responsible was working around a bug that blanked the terminal
  on Windows; that bug was fixed properly upstream, so the workaround could
  finally go.)
- **A snippet added from the command palette was discarded, not saved.** You
  typed a command, pressed Save, and the snippet was simply gone — not stale, so
  waiting for a refresh never brought it back. The palette had already closed by
  the time Save ran, and the resulting error was swallowed, so nothing was ever
  written and nothing was ever reported.
- **The Start button on a restored agent pane re-ran the session's opening
  prompt instead of resuming it.** For a session first launched with a prompt,
  pressing Start opened a *new* conversation and ran that prompt again — a turn
  spent and tools re-run — while the transcript you came back for stayed on
  disk. The button on a restored agent pane now reads **Resume** and resumes.
  A shell pane still re-runs its recorded command, which is what you want there;
  an agent pane that ran and exited still offers Restart. A resume that cannot
  happen leaves the pane alone and says why rather than falling back to a re-run.

### Added

- Every restored session can be resumed at once, one pane per frame, instead of
  starting each tab by hand.
- The snippet library has a home in Settings.

### Fixed — macOS

- A Mac's environment is no longer labelled "windows".
- Hooks are no longer installed for an agent that is not installed.
- A pane's pty is handed back when the pane ends.
- A fresh clone builds for macOS.

---

## 1.8.0 — 2026-09-03 (build 19)

### Changed

- **The terminal now runs on our own xterm2 fork** instead of a vendored copy of
  xterm 4.0.0. Five local divergences were carried across; three were dropped
  because upstream had fixed them properly.
- **Permission modes are per agent.** Each CLI declares its own from its own
  binary's vocabulary — Claude's six, Antigravity's four, Codex's two axes —
  with a shared risk ranking so a handoff can compare them. (Database schema
  v35.)

### Added

- Command snippets: keep commands and type them at the prompt, reach the library
  from the palette and from every terminal, and let agents use the saved
  snippets over MCP.
- A Todos side-panel surface, with a project filter shared with Notes.
- User environment variables are loaded into every terminal, from a vault
  encrypted under a key that does not travel with it.
- Read another worktree's changes without moving the checkout; the Repository
  pane's worktree list is navigable and its chips selectable.
- Switch context from the command palette; move a project between contexts from
  its own row; a context can carry a description.
- Notifications say *what* needs approval, not just which session.
- The session's model is named in the terminal's state line.

### Fixed

- "Not checked" and "No check recorded" no longer read as a lost file.
- A verification pane that came up white.
- A pane reconciles its grid with its box instead of caching it, and a pane
  divider drags against its own split rather than the panel.

### Also shipped as 1.7.0 build 18

Before the 1.8.0 bump, 1.7.0 was rebuilt as build 18 with a per-environment
transport: a WSL hook writes to a spool the app drains over `\\wsl.localhost`,
and a WSL session's MCP entry names the stdio bridge instead of a URL on the
switch address — neither crosses the network path that machine resets. macOS and
Linux keep the loopback transport unchanged.

---

## 1.7.0 — 2026-09-03 (build 17)

Eighty commits since 1.6.0. The ones that change what the app was getting wrong:

### Fixed

- **The device live view froze permanently on a device-clock step**, because the
  muxer latched every later frame to a single timestamp. Recovery now asks the
  device for a fresh keyframe over the still-healthy control socket instead of
  tearing the session down.
- **Our hooks were being wiped from the agents' own settings files on every
  launch**, because the command string carried a port and token and so was
  rewritten each time. It is a constant now, with the volatile half in a file
  the script reads when it fires. Antigravity had never received a script at
  all.
- A turn that died on an API error read as idle, so a broken session reported
  "finished".
- Codex reports `working` for the first time; its session classification went
  from 39 unknown of 52 to 1.
- Resuming a Windows-native agent uses PowerShell, not `cmd.exe`.
- The emulator Slimming button disappeared exactly when Restore was needed, and
  one staged scrcpy jar is now used per start rather than one per machine.
- The New project dialog scrolls.

### Performance

- **Typing lag.** A conversation view mounted behind the terminal kept parsing a
  43.8 MB transcript every two seconds — 888 ms a tick — for a surface nobody
  could see.
- Three device probes are asked together rather than one after another, and the
  environment uses one login shell rather than one per variable.

### Added

- Workspaces (contexts): a project belongs to one, with a scope selector, a
  surface to manage them, and prefill from where the folder sits.
- Explorer multi-select — checkboxes, and deleting a ticked set on the batched
  path.
- A per-agent default model, including "let the agent choose".
- A design pass, a chord registry, and one readable width on the companion so a
  tablet is not a stretched phone.
- The app says on screen when status callbacks are not arriving.

---

## 1.6.0 — 2026-09-02 (build 16)

### Performance

- **Deleting a project no longer walks a store index per session** — 33 scans
  became 2, 289 index records became 33, 34 row deletes became 1, 34 publishes
  became 1 — and its CLI-store purge runs behind the workspace rows rather than
  on the UI path.

### Changed

- The terminal's "workspace" is now called a **layout**, freeing the word
  "workspace" for the context feature that follows.

### Added

- Explorer saved sections, filed by rules you can reorder.
- The delivery strip can name five states it previously could not.
- Review threads that survive an edit.

### Fixed

- The status bar is three zones with budgets that hold at any width, sits on the
  right edge, and follows the session you are looking at.
- **macOS:** the Keychain is no longer asked for something already held.
- A device picture that outlived its device, and a dark mode that would not turn
  back off.

---

## 1.5.0 — 2026-09-02 (build 15)

Six fixes, four of them things the app was quietly getting wrong.

### Fixed

- **The device live view restarted about every 11 seconds on a static screen.**
  scrcpy sends no frames when nothing moves, and the watchdog could not tell
  that from a freeze — 113 restarts in one afternoon's log, none of them a real
  fault. A device with a static screen is now read as idle.
- **"Finished" fired while tool calls were still outstanding** — 6,291 such
  points in one real transcript, 18 hours of wall time classified as idle.
- **Approve/Deny appeared on ordinary output.** Either half of the prompt's
  footer matching anywhere on screen was enough; an agent printing "Esc to
  cancel" in a reply would do it.
- The phone offered Approve/Deny for a session that was merely idle — the
  desktop's fix for the same thing had never reached the wire.
- A restarted pane is the one you can see and type into.
- On a mirrored device: power stops the device you are looking at, the mirror
  keeps the keyboard, and the toolbar acts on the device whose picture is up.

### Added

- File paths in a transcript are clickable, and a clicked path reveals itself in
  the Files panel.
- Cmd chords on macOS, and a tab you open comes back running.
- Apply a permission mode immediately by restarting the session.

### Changed

- The approval card is gone from the terminal surface, which answers its own
  prompts.

---

## 1.4.0 — 2026-09-02 (build 14)

> The release note for 1.4.0 also credits the design-system pass, the tab
> menu's bulk closes and the phone chat opening on its newest message. Those
> commits landed *before* the 1.3.0 version bump, so which of the two builds
> first carried them is not something the history settles. They are listed under
> 1.3.0 below.

### Added

- Live agent quota in the status bar, with a usage chip that says which of three
  ways it failed when it cannot report.
- A model picker: a session carries its own model, live where the CLI allows it,
  and each agent declares whether it can be told which model to use.
- Per-session and all-time usage in one labelled dialog.
- An activity strip above the composer showing what the agent is doing, derived
  from what is genuinely in flight rather than guessed.
- Android emulator slimming — launch flags plus the durable layers — with a
  dialog that says what persists.

### Fixed

- The phone is told when an approval stops waiting.
- "Jump to latest" moved out of the list's viewport.

Database schema head is v28.

---

## 1.3.0 — 2026-09-02 (build 13)

The version was moved because 1.2.0 was already installed on the build machine,
and a second setup carrying the same number makes the installed build
unidentifiable.

This range is large and was assembled from several parallel branches. The themes
below are read off the commits; see the note under 1.4.0 about where the
boundary between the two releases is uncertain.

### Added

- **macOS and Linux.** The desktop app runs on macOS at all, finds the CLI
  stores and the sessions in them there, and the same four gaps were closed on
  Linux before anyone hit them.
- **iOS Simulator support:** list them, pick and start one from the sidebar,
  drive it, and see its screen in the pane. WebDriverAgent replaced idb, and an
  app switcher, a lock that unlocks and simulator slimming came with it. One
  device picker now covers Android devices and booted simulators, and you can
  type into a mirrored device from the desktop keyboard.
- **Terminal:** the panes that were running at close come back; search every
  open pane, by regular expression, honest about the alternate screen; every
  region of a split gets a tab header of its own; Ctrl+Tab steps terminal tabs;
  a pane's working directory follows the shell via OSC 7, including PowerShell.
- **Media:** a Media surface on the side-panel rail, every picture a session has
  without touching the poll, and Ctrl+click on an `[Image #N]` reference to
  preview the picture it names.
- **Transcript:** show what a command answered, show the image an agent read
  rather than its path, and show a subagent's turns under the Task call that
  spawned it.
- An agent's file edits are drawn as a diff, read out of its own transcript.
- Bulk tab closes in the tab menu, in the shape VS Code uses.
- A design-system pass: the type ramp reaches menus and dialogs, one house menu
  row, the mono scale, and icon sizes from tokens rather than 102 literals.

### Fixed

- Agents inside WSL can reach the app, on a port the firewall can name, and a
  WSL agent pane no longer needs interop to start.
- Opening a session on the phone no longer times out, and a long conversation is
  sent as its tail rather than re-read whole.
- The phone chat opens on its newest message.
- A signed-in Codex or Claude account no longer reads as signed out, including
  on macOS.
- Rows you could not reach with Tab, and rows that overflowed.

### Performance

- Draining the PTY queue is linear rather than quadratic.
- A Codex store scan reads what changed rather than 2.4 GB.

---

## 1.2.0 — 2026-09-01 (build 12)

### Changed — the app is now called Karmashala

Chitragupta became **Karmashala** (कर्मशाला, the hall where the work is done).
The old name was chosen when this was session bookkeeping; it became an agent
development environment, so the metaphor moved from the ledger to the workshop.

**This is a clean break, not a rename in place**, and there are things to know
before upgrading:

- It installs as a **different application** — new installer identity, new
  Android id and namespace, new MCP server name. **Uninstall Chitragupta
  first.** Skipping that leaves two apps wanting the same port.
- **Your data is not migrated.** The app's database is an index over the
  agents' own stores rather than the original record, and session detection
  re-imports from those stores, so it rebuilds itself.
- **Existing phone pairings must be redone.** The rename moved the key-derivation
  domain separator, the LAN service name and the secure-storage keys.
- Hook entries written by the old build are still recognised and cleaned up —
  the old markers were deliberately kept, because an entry whose marker no
  longer matches can never be found or removed again.
- The installer removes the old `Chitragupta` and `Chitragupta-WSL` firewall
  rules, which would otherwise outlive both apps pointing at an executable that
  no longer exists.

### Added

- **Split panes.** A region of a split can itself be split, splitting leaves the
  new region empty, and tabs can be moved into a split by drag, keyboard or
  menu.
- Antigravity reports its status through its own hooks, its store is read during
  detection, a session learns which conversation it is on, and it is resumed by
  conversation name rather than `--continue`.
- A CLI's own title is synced into the session row.

### Fixed

- An empty split survives being squeezed to a sliver, and an empty region is not
  treated as a pane to show something beside.
- A hook install reports what is actually on disk, not what it meant to write.

---

## 1.1.5 — 2026-09-01 (build 11)

A large batch merged from several parallel branches. No release note was
written; the entries below are read off the commits.

### Added

- **The app serves MCP itself**, statelessly over streamable HTTP, so an agent
  can open, drive, read and close terminal tabs; talk to a session, read it,
  rename it and end it; read the inbox and notes and act on them; and see the
  checkouts. Each session gets its own config in a path its agent can open, and
  the endpoint is reachable from a WSL session.
- Antigravity is discovered, launched and resumed as the real `agy` CLI.
- **Verification:** one click asks another agent to check a candidate's work,
  and a session's work can be handed to a different installation to check. A
  review session's permission is capped at "ask" and never carried upwards.
- **A per-session, append-only decision record.** Four explicit acts write to
  it, and a handoff packet carries the decisions ahead of the recap.
- A session records the directory its agent runs in, and resume, fork and
  handoff all start where the session was running.
- The phone can ask its desktop what to start, and start it.
- Diagnostics says whether anything is silently unwatched.

### Fixed

- **A stale hook left behind by an earlier build could fire on every prompt** in
  the user's own live session, printing a connection error and a failed hook,
  with nothing in the app able to clear it. An unreachable environment now ends
  the sweep with none of our hooks in it. Only entries carrying our marker are
  touched.
- A hook is installed at an address its own environment can reach, and the hook
  route answers on the WSL door so a WSL hook arrives.
- A pane whose agent says the conversation is gone now says so too, and a resume
  of a conversation the agent never wrote is refused rather than attempted.
- Ending a session moves you to a live tab, not to its tombstone.
- An agent added by an app upgrade is found without a manual rescan.
- A session with no prompt open is never offered approve or deny.
- A desktop build opened on a phone says so instead of showing black.

### Performance

- The Explorer lists sessions rather than a row per recorded checkout, and the
  checkout picker offers parent repositories rather than sixty-nine rows.
- Resuming a session hands its buffer over instead of rebuilding it, and asking
  where a restored session is no longer parses its buffer.

---

## 1.1.4 — 2026-08-31 (build 10)

No release note was written; entries are read off the commits.

### Added

- The "Continue with…" dialog picks the permission mode for the agent it is
  handing to, and a handoff or fork launches under the mode chosen for it —
  still subject to the rule that a mode can only be carried downwards.

### Fixed

- The tab's close button sits at the tab's edge, and `+` opens a shell.
- A split keeps the session's controls, and a finished pane closes.
- Explorer rows are tiles, and the overflow menu occupies one slot on every row
  kind; the search field and the list share the rows' edges.
- Quick open reaches every terminal tab.
- A relative path in a WSL pane is clickable like an absolute one.
- A pane titled with the launcher's own path shows its directory instead.
- Ctrl+V reaches the program when there is nothing to paste.
- A project rescan can find the checkouts inside a WSL project.
- **Companion:** a phone that is still connecting says why and can be told to
  start over; the connect loop cannot lose its way out; a beacon it cannot use
  cannot cost it the link; and a dial that cannot work fails fast and says which
  end failed.

---

## 1.1.3 — 2026-08-31 (build 9)

No release note was written; entries are read off the commits.

### Added

- **Notes:** capture under a message, browse from the rail, and send back to the
  box. A note is quoted text with an origin.
- Ctrl+click any link — file, relative, UNC or URL.
- Right-click a row to reveal it in the file manager.
- Pick which checkout the scoped surfaces describe.
- Hooks became the primary status path, with polling as the fallback.

### Fixed

- The tab strip no longer blinks, and a focus storm costs one refresh.
- A tap on a session no longer opens the chat interface.
- A tab is named by what it is, not by what it was called once.

### Performance

- A detached pane costs its screen rather than its scrollback, a dormant pane
  keeps its scrollback unparsed, and only a bounded set of tabs is mounted.
- The status cycle reads a sample rather than the disk, and the transcript polls
  asynchronously.
- The attention inbox is bounded and its poll application indexed.

---

## 1.1.2 — 2026-08-31 (build 8)

No release note was written; entries are read off the commits.

### Added

- **In-app diagnostics:** a Logs surface on the side panel, a rotating log file
  that survives the process, and a Diagnostics section in Settings. Secrets and
  home paths are redacted on the way into the buffer.
- Agent sessions started by hand in our panes are adopted.
- Every verification and fan-out surface says who graded it.
- Launch commands are built for the shell context they will run in.

### Fixed

- One CLI session is one row in the Explorer.
- The surface follows the session, not the tap that selected it — which is what
  made one tap open two surfaces.

---

## 1.1.1 — 2026-08-31 (build 7)

No release note was written; entries are read off the commits.

### Performance

- **Visibility-aware ingestion: 62 ms per frame became 2.8 ms.**
- The 20-second autosave no longer freezes the UI, and its tick costs the same
  at 100 panes.
- Session badges select a cached status instead of polling for one.

### Fixed

- A selection is a range of the buffer, not of the screen.
- **Ctrl+V pastes**, because that is what Ctrl+V means; Shift+Enter and
  Ctrl+Enter are distinguishable from Enter.
- Closing an idle shell ends it instead of parking it forever.
- Focus follows the active tab, so a switched-to pane is typable.
- The notification watch set no longer truncates at 60 sessions.
- **Companion:** the session view can no longer load forever, "connected" means
  the host answered rather than that a socket opened, a restart never loses a
  pairing that is on disk, and one phone is one device row however many times it
  pairs.

### Added

- Ctrl+C copies a selection, and still interrupts when there is none.
- URLs in output are Ctrl-clickable, and say so on hover.
- Quick open finds an open terminal tab by name or directory, and a filterable
  picker covers every open tab; the tab strip stays usable when the tabs do not
  fit.
- The side panel follows the session you are working in.
- The host waits on every active relay and says where it is; a phone keeps a set
  of relays rather than one address.

---

## 1.1.0 — 2026-08-31 (build 6)

No release note was written; entries are read off the commits.

### Added

- **An embedded local relay, with a one-click switch between local network and
  hosted.** Both are served side by side, and the pairing dialog offers what the
  embedded relay offers.
- Pairing gained a typed code, a LAN/relay race, a progress screen and
  relay-endpoint tabs.
- The companion can pair with several desktops and switch between them, and
  presents projects then sessions in one design language.
- Master-detail Settings, with UI text scale and terminal font size.
- Tab chords that work outside a terminal pane, and Quit in the Workspace menu
  on the tray's own path.
- A new app mark, rendered rather than traced.

### Fixed

- A refused companion request re-dials instead of parking.
- The companion groups sessions by the project the Explorer groups them by.
- The pairing dialog's show/copy row wraps instead of overflowing.
