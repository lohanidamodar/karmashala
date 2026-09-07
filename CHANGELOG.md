# Changelog

This file records **1.1.0 (2026-08-31) through 1.18.1 (2026-09-07)**. Anything
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
