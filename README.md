# Karmashala

कर्मशाला — the hall where the work is done. A Flutter **desktop agent
development environment**: it runs local coding-agent CLIs in embedded
terminals, keeps one index of every session those CLIs write to disk, and hands
the agents a tool surface of its own back over MCP.

**Version 1.16.0 (build 29).** [`CHANGELOG.md`](CHANGELOG.md) records every
release from 1.1.0 onwards and is traceable to commits — read it for when
something landed and what it replaced.

## What it does

Judged from the code, not from folder names. Everything listed here is wired
into the shell and reachable; caveats are stated inline rather than implied.

- **Three agent CLIs.** Claude Code (`claude`, stream-json), Codex
  (`codex app-server`, JSON-RPC) and Antigravity (`agy`, plain PTY text). Each
  is discovered, launched, resumed, permission-moded and status-reported from
  its own vocabulary; nothing is assumed common. The set of hand-written
  protocol adapters is closed in code (`AgentKind`) — a fourth agent gets
  `GenericAgentAdapter` and no rich chat.
- **Sessions the CLIs started outside the app** are imported by scanning their
  own stores (`~/.claude`, `~/.codex`, `~/.gemini/antigravity-cli`), not by
  owning them. Titles sync both ways; a title typed here is never overwritten.
- **Embedded terminals** on a vendored, leak-fixed `flutter_pty`
  ([`packages/flutter_pty/VENDORED.md`](packages/flutter_pty/VENDORED.md)) —
  ConPTY on Windows, `forkpty` on POSIX — rendered by our `xterm2` fork, pinned
  to a commit in `pubspec.yaml`. Splits, tabs, search, OSC 7/8, panes restored
  across a restart.
- **Environments:** this host, a WSL distribution, or an SSH host. An SSH host
  is a real workspace — clone into it, run sessions on it, browse it over SFTP.
- **Status by hook, not by poll.** The agents' own hook scripts report into the
  app; polling is the fallback.
- **An MCP server of its own** — around 85 tools
  ([`mcp_tool_catalogue.dart`](packages/karmashala_mcp/lib/src/mcp_tool_catalogue.dart) is
  the list). Served over HTTP by the app, and over stdio by a separate
  `karmashala_mcp` binary
  ([`packages/mcp_bridge/`](packages/mcp_bridge/bin/karmashala_mcp.dart)). The bridge exists
  because a session inside WSL cannot reach the host across the WSL switch on
  every machine; it is spawned over WSL interop instead.
- **Device control.** Android over `adb` with a bundled `scrcpy-server` for real
  H.264 mirroring; iOS **Simulators only**, over WebDriverAgent with an MJPEG
  stream. Simulator support requires a macOS host.
- **Browser automation** over CDP against Chrome or Edge. No Firefox or WebKit.
- **A mobile companion** — the same codebase built with
  `--dart-define=KARMASHALA_MODE=companion`. Pairs over LAN or through the
  relay in [`packages/relay/`](packages/relay/README.md); every frame is sealed
  end to end (XChaCha20-Poly1305, HKDF-SHA256), so the relay sees a rendezvous
  id and a frame size. The phone can read a transcript, send a prompt, answer an
  approval and start a session — nothing else.
- **Checkpoints, fan-out and verification.** Per-turn snapshots of the working
  tree; the same prompt run across agents or checkouts and diffed; and a
  recorded pass/fail workflow where one agent checks another's work.
- **GitHub** through the `gh` CLI, so it works only where `gh` is installed and
  signed in. The **editor** integration opens VS Code or Zed externally; there
  is no in-app code editor.

## Documents

There is no architecture document, product document, roadmap or ADR directory.
They were deleted deliberately on 2026-09-01 (`1bf4b700`, `390e600d`) because
they described an app that had moved on; the code is the specification, and the
comments explain *why* a line is the way it is at the line itself. What is left:

- [`CHANGELOG.md`](CHANGELOG.md) — 1.1.0 → 1.16.0, per release.
- [`CLAUDE.md`](CLAUDE.md) — the working contract. Also the reference for the
  Windows-toolchain rule (§17), the opt-in live tests (§18) and system health
  (§19).
- [`docs/BACKLOG.md`](docs/BACKLOG.md) — the only planning document. One list
  of open items, ordered by what each is worth to somebody building mobile apps
  with several coding agents running at once. There are no sections by where an
  idea came from; items cite their own source at a pinned commit, and the
  comparison documents below are the evidence behind them.
- [`docs/SETTLED.md`](docs/SETTLED.md) — the closed half: diagnoses worth
  keeping, what shipped and why it is shaped that way, the cost measurements,
  the limits that are deliberate, and the refusals. Nothing here is wanted; it
  exists so an answered question is not asked twice.
- Design notes: [agent status](docs/agent-status-integration.md),
  [inter-agent communication](docs/inter-agent-communication.md),
  [spawn approval](docs/spawn-approval.md),
  [sandboxing](docs/sandboxing-evaluation.md),
  [wasmer](docs/wasmer-evaluation.md).
- Comparisons: [cmux](docs/compare-cmux.md), [orca](docs/compare-orca.md),
  [t3.codes](docs/compare-t3codes.md).
- Profiling: [`docs/PROFILE-2026-09-03.md`](docs/PROFILE-2026-09-03.md) and its
  [final report](docs/PROFILE-2026-09-03-final.md). Both are macOS/Impeller
  measurements; 1.14.0's Windows profile reached a different conclusion about
  where the time goes, so read them as a dated record rather than current
  guidance.

## Requirements

- **Flutter**, stable channel, with the desktop toolchain. `pubspec.yaml`
  requires Dart `^3.12.2` and CI pins nothing tighter than `stable`, so no
  exact version is recorded here to go stale.
- **Windows 10/11** — Visual Studio with "Desktop development with C++".
- **Linux** — `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
  libsqlite3-dev libayatana-appindicator3-dev libkeybinder-3.0-dev
  libsecret-1-dev libmpv-dev libnotify-dev` (the list
  [`release-build.yml`](.github/workflows/release-build.yml) installs).
- **macOS** — Xcode. For the iOS Simulator live view, run
  [`tool/vendor/fetch_wda.sh`](tool/vendor/fetch_wda.sh); without it the build
  still succeeds and only the live view is missing.

**No code generation.** Raw SQL through the `sqlite3` package and plain Riverpod
providers — no `build_runner`, no `*.g.dart`. `flutter pub get` is all you need.

## Platform support, honestly

Windows is the primary target and the best-verified one. Linux is built and
released by CI. **macOS has real, maintained source support but no CI release
job** — `release-build.yml` builds Windows and Linux only, so a Mac build is a
manual one via [`tool/build_release.sh`](tool/build_release.sh). WSL machinery
exists only on a Windows host, by construction.

## Running it

> **On a Windows checkout, drive the Windows toolchain from PowerShell or
> `cmd` — never `flutter` from a WSL shell.** A bare `flutter` on a WSL `PATH`
> resolves to the POSIX script inside the *Windows* install and makes it
> download a **Linux** Dart SDK over the top of the Windows one, breaking the
> toolchain for every other terminal and agent sharing it.
> [`CLAUDE.md`](CLAUDE.md) §17 gives the safe invocation.

```powershell
flutter pub get
flutter run -d windows
```

## Quality checks

```powershell
flutter analyze
flutter test --exclude-tags=live-ssh,live-wsl
```

[`dart_test.yaml`](dart_test.yaml) sets `concurrency: 8` — a measured value, and
the reason no command in this repository passes `--concurrency`. Leave it off so
a local run and automation cannot drift apart.

**Do not run `dart format .`.** Measured under the current SDK it rewrites 144
of 669 files — a repo-wide reformat here is a change, not a tidy-up.

The two live tags are excluded because they drive a real WSL distribution and
dial a real SSH server. They are meant to be run deliberately:

```powershell
powershell -ExecutionPolicy Bypass -File tool\live_tests.ps1
```

## Building a release

[`tool/build_release.bat`](tool/build_release.bat) is the Windows recipe, run
through the `KarmashalaBuild` scheduled task (never from WSL — interop cannot
traverse the plugin symlinks a Flutter Windows build needs). It builds the
desktop app, compiles `karmashala_mcp.exe` beside it, runs Inno Setup
([`windows/installer/karmashala.iss`](windows/installer/karmashala.iss)) and
builds the Android companion APK.
[`tool/build_release.sh`](tool/build_release.sh) is the macOS counterpart.

CI: [`release-build.yml`](.github/workflows/release-build.yml) attaches Windows
and Linux artifacts to a published GitHub release.
[`codemagic.yaml`](codemagic.yaml) holds four manual-only App Store / Play
workflows for the companion.

## Environment variables

**`KARMASHALA_DATA_DIR` is the only way to start against throwaway data, and
`%APPDATA%` is not a substitute.** Redirecting `%APPDATA%` looks like it should
work and does nothing: `path_provider` resolves the Windows folder through
`SHGetKnownFolderPath`, which ignores the environment variable, so an instance
launched that way silently opens the **real** database and imports into it.
`appSupportDirectory()`
([`lib/src/core/paths/app_support_directory.dart`](lib/src/core/paths/app_support_directory.dart))
is the one resolver, and all seven consumers go through it — the database, the
log directory, the env vault, the IPC socket, the session media store and the
verification artifacts. It moves as a set on purpose: a demo instance writing
its rows to a scratch directory and its socket to the real one would be worse
than no override at all. The MCP bridge reads the same variable, so it finds
the handshake the instance actually published instead of connecting to the
real install.

| Variable | Read by | Effect |
| --- | --- | --- |
| `KARMASHALA_DATA_DIR` | the app and the MCP bridge, at launch | Puts the whole per-user data directory somewhere else, created if absent. For screenshots, demos and running a release build against data nobody minds losing. **Not a user setting** — nothing in the app writes it. |
| `KARMASHALA_PROBE` | the app, once at launch | `1` makes the instance a **probe**: a second copy for testing a change beside the real app, with no global side effects (agent hooks, skills, launch at login, hotkey, remote access, toasts, the fixed control port) and a PROBE banner. Requires `KARMASHALA_DATA_DIR` pointing somewhere other than the real folder, or it refuses to start. See PROJECT.md §23. |
| `KARMASHALA_SESSION_ID` | stamped on agent panes; read by the MCP bridge | Which session a process belongs to. The bridge forwards it as `callerSessionId`, which is how agent-spawns-agent depth is capped from the real process tree. |
| `KARMASHALA_PORT_BASE` | stamped on agent panes | A deterministic per-session port base in `[20000, 32760)`. A namespace a repo's own scripts may read — not a lock or a reservation. |
| `KARMASHALA_BRIDGE_HANDSHAKE` | `karmashala_mcp` | Full path to `mcp_bridge.json`, for pointing a bridge at a second install without guessing. Wins over `KARMASHALA_DATA_DIR`, because it names a file rather than a directory. |
| `KARMASHALA_MODE` | build-time `--dart-define` | `companion` builds the mobile app from this codebase. An APK built **without** it used to install and sit on a black screen; `main()` now refuses on a phone and names the missing define. |
| `KARMASHALA_VERSION` | build-time `--dart-define` | Stamps the version into every log line. Absent in a plain `flutter run`, which logs "version not recorded" rather than a stale number. |
| `KARMASHALA_SSH_HOST` / `_USER` / `_KEY` / `_PORT` | the `live-ssh` tests and the SSH benchmark | Where to dial. Unset, they skip themselves with a reason. |

A user-defined environment secret may not start with `KARMASHALA_`; the vault
refuses the name so it cannot collide with the plumbing above.

## Project layout

```
lib/
  main.dart                 # Logging, database, discovery, control server, then runApp
  src/
    app/                    # Shell, workbench, side panel, theme, shortcuts, companion boot
    core/                   # Database, logging, lifecycle, process
    features/               # 32 feature folders: sessions, terminal, agents, devices, …
packages/mcp_bridge/        # The standalone stdio MCP bridge
packages/                   # Vendored flutter_pty and launch_at_startup, the relay, local IPC
test/                       # Mirrors lib/; 727 files
integration_test/           # Driver tests that need a real device or PTY
tool/                       # Build, profiling, benchmark and manual-verification programs
docs/                       # Backlog, design notes, comparisons, profiling reports
```

## tool/

None of these run in the default test gate; several are *invoked* through
`flutter test` but live under `tool/` so discovery cannot pick them up and
their presence never reads as coverage. Run them from the repository root.

| Path | What it is |
| --- | --- |
| [`build_release.bat`](tool/build_release.bat) / [`.sh`](tool/build_release.sh) | The release recipes (above). |
| [`live_tests.ps1`](tool/live_tests.ps1) | Runs the excluded `live-wsl` / `live-ssh` suites, after printing what it found. |
| [`reliability_soak.ps1`](tool/reliability_soak.ps1) | Repeats the flake-prone suites N times (default 20) to catch what one run cannot. |
| [`profile_run.bat`](tool/profile_run.bat) | Builds and launches a `--profile` build for a profiling session, via the `KarmashalaProfile` scheduled task. |
| [`vm_probe.dart`](tool/vm_probe.dart) | Samples a running app's VM service — frames, stalls, timeline — for when the Dart MCP server will not connect. `dart tool/vm_probe.dart <ws-uri> <seconds>`. |
| [`analysis/test_purity.dart`](tool/analysis/test_purity.dart) | Classifies each test as widget / Flutter-free / blocked, and prices the imports that block it. Produces the numbers in `docs/BACKLOG.md`. |
| [`analysis/migrate_unit_tests.dart`](tool/analysis/migrate_unit_tests.dart) | The one-shot mover for a purity-driven batch: relocates files, swaps `flutter_test` for `package:test`, repairs the imports. Dormant between migrations. |
| [`ui_screenshot.dart`](tool/ui_screenshot.dart) | Renders the real shell against a fixture and writes PNGs of several states. `flutter test tool/ui_screenshot.dart`. |
| [`benchmark/`](tool/benchmark) | Nine on-demand benchmarks — paint, input latency, ingest, scale, autosave, SSH. They print; they do not assert. |
| [`verification/`](tool/verification/README.md) | Manual programs that drive real browsers, devices and CLIs. Kept out of `test/` so their presence never reads as coverage. |
| [`icon/`](tool/icon) | Renders the app icon, the Android adaptive layers and the Windows `.ico` from one drawn description. |
| [`vendor/fetch_wda.sh`](tool/vendor/fetch_wda.sh) | Fetches the pinned WebDriverAgent for the macOS build. |

## Keyboard shortcuts

The full list, with what each one costs a focused shell, is
[`shell_shortcuts.dart`](lib/src/app/shell/shell_shortcuts.dart); Settings →
Terminal offers the contested ones back. `Ctrl` below is `Cmd` on macOS.

| Shortcut | Action |
| --- | --- |
| `Ctrl+1` / `Ctrl+2` | Focus the Explorer / the workbench |
| `Ctrl+3` | Show or hide the side panel |
| `Ctrl+B` | Show or hide the Explorer |
| `` Ctrl+` `` | Switch between the terminal and the chat view |
| `Ctrl+K` / `Ctrl+P` | Quick open (`Ctrl+Shift+P` for commands) |
| `Ctrl+Shift+A` | Attention inbox |
| `Ctrl+\` | Focus mode |
