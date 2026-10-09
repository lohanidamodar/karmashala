# Karmashala

कर्मशाला — the hall where the work is done. An **agent development
environment**: one Flutter app that runs coding-agent CLIs on your desktop,
on a server, or both, and follows them from your phone.

**Version 1.34.6.** [`CHANGELOG.md`](CHANGELOG.md) records what changed in
each release.

## What it does

- **Claude Code, Codex and Antigravity**, each driven through its own protocol
  — started, resumed, given a permission mode and reported on in its own
  words. Sessions the CLIs started outside the app are imported from their own
  stores, and titles sync both ways.
- **Any agent that speaks ACP.** Agents on the Agent Client Protocol are added
  from the ACP registry or by command (Grok, for one) and run as chat
  sessions: their modes, models, slash commands, plans, diffs and permission
  options in the chat, and usage-limit resumes like the rest.
- **Terminals and chat.** Each session is an embedded terminal (ConPTY on
  Windows, `forkpty` elsewhere) or a chat view of the same conversation, in
  split, tabbed workbench groups that survive a restart. Each agent can run in
  either form.
- **Sessions that start sessions.** An agent can start sub-sessions on any
  agent and model, which report back to it when they finish (or every turn),
  hand work back and forth, or switch a session's agent in place. Sub-sessions
  fold beneath their parent, the Subagents panel follows them live, and
  finished ones are archived out of sight. A session with no project runs in a
  scratch folder of its own and attaches the checkouts it needs.
- **An editor and a file explorer.** Open, edit and save files in tabs, browse
  any environment's tree, view images, video and audio, and hand a file to a
  session.
- **Anywhere the work is.** This machine, a WSL distribution, or an SSH host.
  An SSH host gets the Karmashala server deployed to it and runs its sessions
  there.
- **A server you can run headless.** `karmashala_host` keeps the sessions,
  automations and pairings, and the desktop app is one of its clients. Settings
  → Server, quick open and the tray show its state and stop, restart or start
  it; its log is `<data>/logs/server.log`, read in the Logs tab beside the
  app's. See [`server/README.md`](server/README.md).
- **Your phone.** The same app built for Android and iOS pairs with a desktop
  or a server — on the LAN, through a relay, or at an address. It lists
  sessions, reads and answers them, approves tool calls, starts new ones, opens
  their terminals and files, and keeps notes. Every frame is sealed end to end;
  a relay sees nothing inside. A pairing moves to a new relay without a
  re-pair, the route a link takes (this network or a relay) is switched from
  the connection chip, and each machine can be given a name of your own.
- **Tools for the agents.** An MCP server of its own (about 130 tools:
  sessions and sub-sessions, terminals, devices, browser, checkpoints, notes,
  todos, store data), with a stdio bridge for sessions inside WSL.
- **Status by hook, not by poll.** The agents' own hooks report what they are
  doing, and an attention inbox collects what needs you.
- **Checkpoints, fan-out and verification.** Per-turn snapshots of the working
  tree, one prompt run across agents or checkouts and compared, and a recorded
  pass/fail check where one agent reviews another's work.
- **Devices, browser and stores.** Android over `adb` with live mirroring, iOS
  Simulators (macOS only), Chrome or Edge over CDP, and a read-only view of
  your App Store Connect and Google Play apps, reviews and installs.
- **Git and GitHub** — worktrees per task, diffs, and GitHub through the `gh`
  CLI where it is installed.

## Platforms

Windows is the primary target and the best tested. Windows, macOS, Linux and
Android builds are attached to every GitHub release; the macOS build is ad-hoc
signed and not notarised. Linux comes as a tarball and as an AppImage, which
carries its own libraries but uses the system's GTK 3 and OpenGL. The phone app
targets Android first, then iOS.

## Requirements

- **Flutter**, stable channel, with the desktop toolchain for your platform.
- **Windows** — Visual Studio with "Desktop development with C++".
- **Linux** — `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
  libsqlite3-dev libayatana-appindicator3-dev libkeybinder-3.0-dev
  libsecret-1-dev libmpv-dev libnotify-dev`.
- **macOS** — Xcode. For the iOS Simulator live view, run
  [`app/tool/vendor/fetch_wda.sh`](app/tool/vendor/fetch_wda.sh).

There is no code generation: `flutter pub get` is all the setup there is.

## Running it

```sh
flutter pub get          # at the repository root: one pub workspace
cd app
flutter run -d windows   # or macos, linux
```

On Windows with WSL beside it, run Flutter from PowerShell or `cmd`, never from
a WSL shell: a bare `flutter` there resolves to the Windows install's POSIX
script and replaces its Dart SDK with a Linux one.

**Running a second copy beside an installed one?** Set `KARMASHALA_PROBE=1`
and point `KARMASHALA_DATA_DIR` somewhere else, or the second copy takes over
the first one's agent hooks.

### Remote access and the relay

A source build has **no hosted relay**. Phones still pair over the local
network, by address, or through a relay you name in Settings → Remote and
pairing. Run your own (below), or build with
`--dart-define=KARMASHALA_RELAY_URL=wss://…` to give the build a default.

## Self-hosting a server or a relay

No desktop app needed: the server runs your agent sessions on its own machine,
and any Karmashala client — the phone app, or the desktop app as a client —
pairs with it. Each installer downloads the latest release for your platform,
sets it up as a per-user service and ends by showing a pairing code.

**Linux and macOS**

```sh
# The server, for clients on the same network
curl -fsSL https://github.com/lohanidamodar/karmashala/releases/latest/download/install.sh | bash -s -- --lan

# The server and a relay, on a machine clients can reach (a VPS)
curl -fsSL https://github.com/lohanidamodar/karmashala/releases/latest/download/install.sh | bash -s -- --with-relay --host <public address>

# Only a relay, for a server behind NAT to meet its clients at
curl -fsSL https://github.com/lohanidamodar/karmashala/releases/latest/download/install.sh | bash -s -- --relay --host <public address>
```

**Windows** (PowerShell, no administrator rights; it starts when you sign in)

```powershell
& ([scriptblock]::Create((irm https://github.com/lohanidamodar/karmashala/releases/latest/download/install.ps1))) -Lan
```

`-WithRelay`, `-Relay` and `-HostAddress` match the flags above.

| Where the server is | How a client reaches it | Use |
| --- | --- | --- |
| Same network as the client | Directly | `--lan` |
| A VPS or other public address | Directly, or through a relay beside it | `--with-relay --host …` |
| Home or office, behind NAT | Through a relay on something public | `--relay` on the public machine, then `--relay-url <its URL>` on the server |
| Both on a tailnet | Directly | `--bind <tailnet address>` |

A relay installed this way prints its URL, `ws://<host>:8787/k/<token>`. The
frames it carries are sealed end to end, but the token travels in that URL,
so put it behind a TLS terminator for `wss://` — two lines of Caddy:

```
relay.example.com {
	reverse_proxy 127.0.0.1:8787
}
```

and give clients `wss://relay.example.com/k/<token>`. The relay is also an
image, `ghcr.io/lohanidamodar/karmashala-relay`, for Docker and Fly.io
([`relay/`](relay/README.md)). Everything else about the server — pairing,
grants, the firewall, its config — is in [`server/README.md`](server/README.md).

## Quality checks

```sh
dart analyze app server packages     # at the repository root
cd app
flutter test --exclude-tags=live-ssh,live-wsl \
  --dart-define=KARMASHALA_RELAY_URL=wss://relay.example.com
```

The relay define is a placeholder that the hosted-relay tests need. The
`live-ssh` and `live-wsl` suites drive a real SSH server and a real WSL
distribution; [`tool/live_tests.ps1`](tool/live_tests.ps1) runs them.

## CI and releases

- [`ci.yml`](.github/workflows/ci.yml) analyzes every pull request and push to
  `main`; a pull request tests only the members its change can reach
  ([`tool/ci_affected.dart`](tool/ci_affected.dart)), and `main` tests all of
  them.
- Publishing a GitHub release runs
  [`release-build.yml`](.github/workflows/release-build.yml), which attaches the
  Windows installer and portable zip, the macOS DMG, the Linux tarball and
  AppImage ([`tool/package_appimage.sh`](tool/package_appimage.sh)), the server
  bundles and the Android APK.
- [`android-release.yml`](.github/workflows/android-release.yml) uploads to
  Google Play, and only when run by hand.

[`tool/build_release.bat`](tool/build_release.bat) and
[`tool/build_release.sh`](tool/build_release.sh) build the same desktop
artifacts locally on Windows and macOS.

A version bump is `app/pubspec.yaml` alone. Every build recipe and release
job writes its release into the server's version first
([`tool/sync_host_version.dart`](tool/sync_host_version.dart)), so app and
server always report the same one; `host_version_test` guards it on commits.

## Environment variables

| Variable | Read by | Effect |
| --- | --- | --- |
| `KARMASHALA_DATA_DIR` | the app and the MCP bridge, at launch | Moves the whole data directory (the server's `~/.karmashala` and the app's own) somewhere else. Redirecting `%APPDATA%` does not work: Windows resolves that folder without reading the variable. |
| `KARMASHALA_PROBE` | the app, at launch | `1` makes the instance a probe: a second copy with no global side effects (agent hooks, skills, launch at login, hotkey, remote access, toasts). Requires its own `KARMASHALA_DATA_DIR`. |
| `KARMASHALA_SESSION_ID` | set on agent panes; read by the MCP bridge | Which session a process belongs to. |
| `KARMASHALA_PORT_BASE` | set on agent panes | A per-session port base in `[20000, 32760)` a repository's scripts may use. |
| `KARMASHALA_BRIDGE_HANDSHAKE` | `karmashala_mcp` | Full path to `mcp_bridge.json`, to point a bridge at a particular install. |
| `KARMASHALA_RELAY_URL` | build-time `--dart-define` | The hosted relay phones meet the desktop at when neither side names its own. Unset in a source build, which then offers no hosted relay. The official build recipes pass it. |
| `KARMASHALA_VERSION` | build-time `--dart-define` | Stamps the version into every log line. |
| `KARMASHALA_SSH_HOST` / `_USER` / `_KEY` / `_PORT` | the `live-ssh` tests | Where to dial. Unset, those tests skip themselves. |

## Project layout

```
pubspec.yaml     # the pub workspace: app, server, packages/*
app/             # the Flutter app — desktop and phone
server/          # the Karmashala server (karmashala_host); deploy/ installs it
relay/           # the self-hostable relay, and protocol/, its contract
packages/        # shared packages, the MCP bridge, vendored forks
tool/            # release recipes, the test gate, live tests, run scripts
```

## Keyboard shortcuts

`Ctrl` is `Cmd` on macOS. The full list is in
[`shell_shortcuts.dart`](app/lib/src/app/shell/shell_shortcuts.dart).

| Shortcut | Action |
| --- | --- |
| `Ctrl+1` / `Ctrl+2` | Focus the Explorer / the workbench |
| `Ctrl+B` | Show or hide the Explorer |
| `Ctrl+3` | Show or hide the side panel |
| `` Ctrl+` `` | Switch between the terminal and the chat view |
| `Ctrl+K` / `Ctrl+P` | Quick open (`Ctrl+Shift+P` for commands) |
| `Ctrl+Shift+A` | Attention inbox |
| `Ctrl+\` | Focus mode |

## License

[Apache License 2.0](LICENSE), copyright 2026 Damodar Lohani. A few parts
carry their own licences, listed in [NOTICE](NOTICE).
