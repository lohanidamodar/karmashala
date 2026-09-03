# Changelog

This file records **1.1.0 (2026-08-31) through 1.10.2 (2026-09-03)**. Anything
before 1.1.0 is not recorded — no release notes were written for those versions
and this file does not invent them.

Entries are derived from the repository's own history: the `chore: release`
commit bodies where they exist, and the commits in each version's range where
they do not. Every entry here is traceable to a commit. Where the history is
genuinely ambiguous about which release something shipped in, the entry says so
rather than guessing.

Versions are listed newest first. The number in brackets is the build number
from `pubspec.yaml`, which is what a shipped binary reports — useful when two
installs claim the same version name.

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
