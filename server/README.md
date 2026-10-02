# Karmashala server

A Karmashala server is the session host (`karmashala_host`, `server/`)
running on its own: on a DigitalOcean droplet, a home server, any Linux or
macOS machine with no desktop app on it. It keeps its own store, reads its own
config, finds the agent CLIs installed on its machine, runs their sessions and
automations, and serves paired phones — directly, through a relay, or over a
tailnet.

There is one server and one way to run it. On a machine where you use the
Karmashala desktop app you do not install anything: the app starts the same
`karmashala_host serve` (or uses the one already running) and is a client of
it — its notes, todos and settings go through the server's data API (the
rest, for now, through the server's database in the server's data folder),
and its Remote access settings are the server's `server.json`.

## What it is made of

| Where | What |
| --- | --- |
| `<prefix>/current/bin/karmashala_host` | the bundle (`bin/` and `lib/` side by side — never flatten it) |
| `~/.karmashala/karmashala.sqlite` | the store: sessions, automations, phone pairings. Created and migrated by the server itself, with the app's own schema ladder (`packages/karmashala_store`); a store migrated by a newer build is refused, never written. The desktop app opens this same file (WAL) |
| `~/.karmashala/server.json` | the server's config, owner-only |
| `$XDG_RUNTIME_DIR/karmashala/` or `~/.karmashala/` (`KARMASHALA_HOST_DIR` overrides) | the user's host directory: its socket, lock, hook endpoint, MCP credentials and session records |

`~/.karmashala` is the server's default data directory — `serve` with no
`--data-dir` uses it — and the one the desktop app opens and the SSH deployer
starts a box's server in, so a machine set up by hand, by the desktop or by
the deployer is one server with one set of pairings. `--data-dir` stays for
tests, probes and explicit setups (the installers pass theirs).

Every `karmashala_host` subcommand answers `--help` (or `-h`) with its usage
and touches nothing; a flag it does not know is refused (exit 2) before it
reads, writes or binds anything.

### Where the store lives

Two directories, with different owners:

- **The data directory** (`~/.karmashala` unless `--data-dir`) is **the
  server's**: `karmashala.sqlite` (sessions, automations, pairings — which
  the desktop app opens beside it), `server.json`, `mcp_bridge.json` (the
  agents' MCP handshake), `mcp/` (the session MCP configs), `verification/`
  (the gates' artifacts) and `attachments/` (the files phones send). The
  server creates and migrates the store and is the only writer of lifecycle
  status. Notes, todos, the app's preferences and the workspace (contexts,
  projects, checkouts, saved sections) are read and written only through
  the server's data API (protocol 12: `dataRequest`, `dataAnswer`,
  `dataChanges` on the socket); the domains not moved yet the app still
  writes in the file directly. Two servers with two data directories share
  none of it. What only the desktop
  app keeps — its logs, keymap, recordings, window state — stays in its own
  app-support folder.
- **The host directory** is **the user's**, one per user per machine, whatever
  data directory a server has: the control socket, `host.lock` (the pid of
  the host holding it — a bare pid, which the installers and the SSH deployer
  read), `host.data-dir` (the data directory of that host), the hook endpoint
  (agents' hooks are installed per user), the MCP credentials and last tool
  catalogue, and `sessions/`, each session's output and `meta.json`.
- **Session records name their server.** Every `sessions/<id>/meta.json`
  carries `store`, the canonical data directory of the server that ran it. A
  server restores, reports, marks lost and prunes only its own records; one
  that names another data directory — the desktop app's host, a probe, an
  older build that wrote none — is left exactly as it is. (Found live: a
  server with a scratch `--data-dir` restored the desktop host's
  fourteen ended sessions, and a phone listed them as a "No project" group.)
- **One host per user on a machine.** A second `serve` as the same user is
  refused (exit 3) while another holds the lock, naming its pid and its data
  directory: `another host is already running for this user (pid 4242, data
  in /home/dev/.karmashala)`. Stop that one (`karmashala_host stop`), or run
  the second server as another user — the server the desktop app started
  already is this machine's server.

### App stores

The server holds the App Store Connect key and the Play service account, runs
the store clients and keeps what they said; the desktop app, the phone and
agents read it all through the server (`stores.*` data requests, the store
tools).

- **Credentials** are in `<data dir>/secrets/stores.json`, in the same
  owner-only folder as the environment vault, written atomically. A key file
  travels client → server in a set request only; no answer, change, log line
  or snapshot carries one back — clients see the key id, issuer, vendor
  number, and the account's email, bucket and package names. A file that will
  not read is left alone, and every later change is refused rather than
  written over it.
- **What was read** is kept in `<data dir>/stores/snapshot.json` (version 1,
  no credential), so a restart shows the last reading at once. A file that
  will not read is nothing kept.
- **Apps combined by hand** — an App Store app and a Play app whose bundle id
  and package name differ — are kept in `<data dir>/stores/links.json`
  (version 1), apart from the snapshot so a dropped snapshot or a replaced
  key keeps them. `stores.link` pairs two apps (an app is in one pair at
  most; linking again replaces its old pair) and `stores.unlink` separates
  them; every view carries the pairs, and `combineStoreApps` in
  `store_console` applies them for the Stores tab and the store tools alike.
- **A phone reads and may refresh**, and may combine or separate apps;
  setting or removing a credential is refused from a phone — import it on a
  desktop paired with the server.
- **No timer.** The server asks the stores only when a client or an agent
  asks for a refresh (one under way is joined; `maxAgeSeconds` answers a young
  enough reading as it is), and once when a new key file is set.

## Install on a server (a DigitalOcean droplet, for example)

1. **Create the droplet.** Ubuntu 24.04, any size that runs your agents. Add
   your SSH key. In *Networking → Firewalls*, allow inbound SSH (22) only for
   now; see [Firewall](#firewall) for what to open later.

2. **A user to run it as.** Agents run as this user and use its sign-ins:

   ```sh
   adduser --disabled-password --gecos '' dev
   usermod -aG sudo dev          # optional
   rsync -a ~/.ssh /home/dev/ && chown -R dev:dev /home/dev/.ssh
   su - dev
   ```

3. **Git and the agent CLIs, signed in.** The server finds whatever is on this
   user's `PATH`; it cannot sign in for you.

   ```sh
   sudo apt-get update && sudo apt-get install -y git curl
   curl -fsSL https://claude.ai/install.sh | bash     # Claude Code
   claude                                              # sign in once
   # Codex: npm i -g @openai/codex && codex login  (needs Node.js)
   ```

4. **Install.** The installer downloads the server for the droplet's CPU from
   the latest release (`--version <v>` for another; a bundle path or URL as
   the first argument for your own build). Pick the route clients reach it by:

   ```sh
   # Directly, at the droplet's address (open 47820/tcp, see Firewall)
   curl -fsSL https://github.com/lohanidamodar/karmashala/releases/latest/download/install.sh \
     | bash -s -- --name droplet --bind 0.0.0.0 --host <droplet address>

   # Through a relay on the droplet itself (open 8787/tcp instead)
   curl -fsSL https://github.com/lohanidamodar/karmashala/releases/latest/download/install.sh \
     | bash -s -- --name droplet --with-relay --host <droplet address>
   ```

   The installer proves the bundle runs here (`probe-pty`, `probe-store`),
   puts it in `~/.local/share/karmashala-server/releases/<time>` with
   `current` pointing at it (`--system` puts it in `/opt/karmashala-server`
   with sudo), writes `~/.karmashala/server.json` through `karmashala_host
   init` with phones served (owner-only; `--no-companion` leaves them off;
   an existing one is kept unless `--force-config`),
   installs a `karmashala_host` command in `~/.local/bin`, and installs and
   starts the **systemd user unit** `karmashala-server` (on macOS the
   **launchd agent** `com.karmashala.server`). On Linux it enables lingering
   so the server keeps running after you log out; if it cannot, it tells you
   to run `sudo loginctl enable-linger $USER`.

   Check it: `systemctl --user status karmashala-server`,
   `journalctl --user -u karmashala-server`. The log's first lines say where
   it serves, its store, and which agent CLIs it found.

5. **Pair a client.** The installer ends by opening a pairing window on the
   route it set up: scan the QR with the Karmashala app, or type the code.
   `--no-pair` skips it; `karmashala_host pair` opens another later (next
   section).

Upgrading is the same command again. A server holding live sessions is
**not** restarted by the installer (that would end them): it says so and
prints the restart command, or pass `--restart` to end them now.
`uninstall.sh` (a release asset too) removes the services and the bundle and
keeps the store and pairings unless `--purge`.

### On a Mac or another Linux machine

The same command works on any Linux with systemd and on macOS, where the
services are launchd agents (`com.karmashala.server`, `com.karmashala.relay`).
On a machine where you use the desktop app, the app's server already is that
machine's server; the installer refuses rather than run a second one.

### On Windows

```powershell
& ([scriptblock]::Create((irm https://github.com/lohanidamodar/karmashala/releases/latest/download/install.ps1))) -Lan
```

No administrator rights: the server goes under
`%LOCALAPPDATA%\Karmashala\server`, `karmashala_host` onto your PATH, and a
scheduled task (*Karmashala Server*, and *Karmashala Relay* with `-WithRelay`)
starts it, hidden, when you sign in. It runs as you, so agents use your
sign-ins, and it runs while you are signed in. `-Relay`, `-WithRelay`,
`-HostAddress`, `-Bind`, `-RelayUrl`, `-Version` and `-NoPair` match the
shell flags; `-Uninstall` removes it again (`-Purge` with it deletes the data).

### Only a relay

`--relay` (`-Relay` on Windows) installs just a relay: for a server behind NAT
whose clients are elsewhere. Run it on a machine both can reach, then give the
server the URL it prints with `--relay-url <url>` (`-RelayUrl`). The relay's
token is in `~/.karmashala/relay-token`; the README's *Self-hosting* section
says how to put the relay behind TLS.

## Pair a phone

On the server:

```sh
karmashala_host pair --address=<address the phone dials> [--name="My phone"] \
  [--capabilities=all|view_sessions,read_transcript,…] [--relay=<url>]
```

It opens a pairing window (the same one the desktop's *Pair a phone* dialog
opens), prints the short code, when it expires, the grants, a QR code drawn in
the terminal and the full payload, then waits and says which device paired, or
that the window expired (exit 1). On the phone, scan the QR, or choose **Add
a machine by address** and type the address and the code (without `--address`,
**Paste the code instead**).

`all` includes `phone_client`: the Karmashala app on a phone attaches to this
server's host protocol (sessions, terminals, files), never as its admin and
never answering its SSH questions. A phone paired before that grant existed
does not have it until you grant it:

```sh
karmashala_host grant <id> --add=phone      # a unique prefix of the id is enough
karmashala_host grant <id> --remove=phone   # take the app away again
```

`phone` is the phone preset, the same set the desktop's **Phone** preset
grants: `phone_client` plus every other non-privileged grant (read
transcripts, send prompts, approve, start sessions, attachments, add
projects, usage), never `server_admin` or `ssh_prompts`. So `pair --grants
phone` is `pair` with its default `all`, and `grant --add=phone` also gives an
old companion pairing the grants the app enforces on a phone. In `--remove`,
`phone` takes away `phone_client` alone.

`grant` takes any capability names or aliases (`phone`, `desktop`, `admin`,
`ssh`) in `--add` and `--remove`. A device with a link open reattaches at once
with the new grant. On a desktop, the device's row in Settings → Remote and pairing says
when a phone lacks the app and offers **Grant**; the pairing and permissions
dialogs start from a **Phone** or **Desktop** preset.

`--address` makes the QR a host invite naming where to dial — what a phone on
another network needs. Without it the QR is the bare pairing payload, which
works through a relay or on the same LAN with the beacon on.

### Direct

The phone dials the server's own address. Needs the listener on a reachable
interface and the port open:

```sh
karmashala_host init --force --companion --bind=0.0.0.0   # or install.sh … --bind 0.0.0.0 --force-config
systemctl --user restart karmashala-server
karmashala_host pair --address=203.0.113.9       # the droplet's public IP
```

Open **47820/tcp** in the firewall (see below). Everything on the port is the
sealed companion protocol: nothing answers without a pairing, and pairing
needs the code this command printed.

### Relay

Nothing inbound at all: the server and the phone both dial out to a relay and
meet there. Put the relay in `server.json` (or pass `--relay` to `pair` for one
window):

```sh
karmashala_host init --force --companion --relay=wss://relay.example.com --relay-token=<32+ url-safe chars>
systemctl --user restart karmashala-server
karmashala_host pair            # the QR names the relay
```

A relay you run yourself is `karmashala_host relay` on any machine with a
public address (`karmashala_host relay --help`); the token is the one in its
`--token-file`, spelled into the URL as `/k/<token>`. The server never prints
the token back (`…`).

### Tailnet

Install Tailscale (or any WireGuard mesh) on the server and the phone, and bind
the listener to the server's tailnet address only:

```sh
karmashala_host init --force --companion --bind=100.101.102.103
systemctl --user restart karmashala-server
karmashala_host pair --address=100.101.102.103    # or its MagicDNS name
```

No public port is opened; only devices on your tailnet can reach it.

### A desktop app as the client (slice 5e)

The desktop app can use this server instead of its own, over the same routes
a phone takes:

```sh
karmashala_host pair --grants desktop --address=<address the desktop dials>
# add ,admin to let it administer this server, ,ssh to answer its SSH questions
```

In the app: Settings → Machines → *Add a machine*, paste the code (or the
payload) and, when the code names no address, `host:port`; then *Use* it (the
app starts again as its client). Its panes, notes and sessions are this
server's; the desktop's own devices stay its own.

### Moving a phone from the companion to the app

The Karmashala app on a phone has the companion's app id, so it installs over
the companion in place. **Only when both are signed with the same key**: over
a companion signed differently (a sideloaded, debug-signed APK under a Play
build) the install is refused, and the only way on is to uninstall, which
erases the pairing, and pair again.

With the same key, the companion's pairings, device keys and device id carry
over. On its first start the app opens the machine the companion had active,
as the same device: `karmashala_host devices` shows the same row.

A pairing made before `phone_client` existed is **not** given the app
automatically. Until you grant it, the app shows *This phone needs to be
granted the app on <server>* with both ways to do it:

- on the server's desktop, Settings → Remote and pairing, the phone's row →
  **Grant**;
- on a headless server, `karmashala_host grant <id prefix> --add=phone` (the
  page fills in the prefix).

Either one adds the whole phone preset to what the pairing held, so bits the
companion was paired without (attachments, usage) come with it.

The app picks the grant up within a few seconds, or at once with *Try again*.
Installing the companion again over the app (the way back, same key) keeps
the pairing: both read the same records.

### Devices

```sh
karmashala_host devices          # every pairing: id, name, state, when, grants
karmashala_host revoke <id>      # a unique prefix of the id is enough
karmashala_host grant <id> --add=phone   # change what it may do
```

Revoking drops the device's live links at once; its row stays, marked revoked.

## Firewall

| Port | Bound to | Open it? |
| --- | --- | --- |
| 47820/tcp — phones (`companion.port`) | `companion.bind`: `127.0.0.1` unless configured | only for direct pairing, and only if bound to a public interface; never needed for relay or tailnet |
| 47821/tcp — agents' MCP tools (`mcp.port`) | always `127.0.0.1` | never |
| agent hooks | always `127.0.0.1`, a port of its own | never |
| the control socket | a unix socket in an owner-only directory | not a port |

On a droplet: `sudo ufw allow OpenSSH && sudo ufw allow 47820/tcp && sudo ufw
enable` for direct pairing, or only `OpenSSH` for relay and tailnet (plus
DigitalOcean's cloud firewall, which applies before `ufw`).

## Config

`<data dir>/server.json`, written by `karmashala_host init`, by the desktop
app's Remote access settings (through the server: `server.config.set`), or by
hand (`serve` makes it owner-only if it is not, and refuses one it cannot
parse — it never binds somewhere a typo did not mean). It is the one source
of how phones are served: nothing else keeps a copy.

```json
{
  "name": "droplet",
  "companion": {
    "enabled": true,
    "bind": "0.0.0.0",
    "port": 47820,
    "beacon": false,
    "relay": "wss://relay.example.com",
    "relayToken": "…32+ url-safe characters…",
    "relayEnabled": true,
    "extraRelays": ["ws://box.example.com:8787/k/<token>"],
    "notes": true
  },
  "mcp": { "port": 47821 }
}
```

| Field | Flag | Default |
| --- | --- | --- |
| `name` | `--name` | the hostname |
| `companion.enabled` | `--companion` / `--no-companion` | `false` — a fresh server serves no phones until something turns it on (`install.sh` does; the desktop's Remote access switch does) |
| `companion.bind` | `--bind` | `127.0.0.1` — the desktop's Remote access switch sets `0.0.0.0` |
| `companion.port` | `--companion-port` | 47820 |
| `companion.beacon` | `--beacon` / `--no-beacon` | `false` |
| `companion.relay`, `companion.relayToken` | `--relay`, `--relay-token` | none (direct pairings only) |
| `companion.relayEnabled` | `--relay-enabled` / `--no-relay-enabled` | `true`; off keeps the relay and parks its phones (the desktop's "Hosted relay" switch) |
| `companion.extraRelays` | `--extra-relay` (repeatable) | none |
| `companion.localRelay` | `--local-relay` / `--no-local-relay` | `false` — the server's own LAN relay, bound at `companion.bind` (the desktop's "Local relay (this computer)" switch) |
| `companion.localRelayPort` | `--local-relay-port` | 8787 |
| `companion.notes` | `--notes` / `--no-notes` | `true` |
| `mcp.port` | `--mcp-port` | 47821 (the MCP endpoint is always loopback) |

**Precedence.** Each field: a `serve` flag, else `server.json`, else the
default. Flags are written `--flag=value` (`karmashala_host init` takes the
same ones and writes them to the file; `init --force` replaces a file that is
there, so pass every field you want kept). A flag holds its field for the
life of the process: a change to the file is kept but not served until the
flag is gone.

**Changing it while it runs.** `server.config.get` and `server.config.set`
over the owner-only socket (the desktop app's Remote access settings use
them): a set lays a patch shaped like the file over it — a `null` clears a
field back to its default — checks it as the file is checked, writes it
owner-only, and applies it at once: whether phones are served, the relays,
the beacon, Notes, and where the listener binds and on which port (the
listener restarts only when the bind or port moved), and the server's own
LAN relay (`companion.localRelay`, rebound when its port or the bind moved).
The name and the MCP port take effect at the next start. The desktop app adds
nothing on its link: the LAN relay is the server's, served with or without it,
and `server.config.get` reports what it is doing (`localRelay`: state, URL,
the other addresses, a bind error, the Windows firewall hint).

## Agent CLIs

The server finds the agent CLIs on its machine at every start — every agent
the registry knows (`packages/agent_cli`), located on the login shell's
`PATH` and asked its version — and records them in the store, where every
session and automation it starts looks them up. `karmashala_host agents`
lists what it recorded; `karmashala_host agents --refresh` looks again (after
installing or updating one); the desktop app asks the same (`agents.refresh`)
each time it connects. A CLI that disappears is not deleted: sessions point
at it. A path a person pinned in the desktop's settings is never overruled,
and a CLI that moved keeps its row (settings pin it by id).

## Docker

```sh
docker build -f server/deploy/Dockerfile -t karmashala-server .
docker compose -f server/deploy/docker-compose.yml up -d
docker compose -f server/deploy/docker-compose.yml exec server karmashala_host pair --address=<host address>
```

The image holds the server and git, and no agent CLI. **Install the agents in
an image of your own built from it, and sign in inside the container** — the
server can only run what is installed and signed in where it runs:

```dockerfile
FROM karmashala-server
USER root
RUN apt-get update && apt-get install -y --no-install-recommends nodejs npm \
 && npm i -g @openai/codex && rm -rf /var/lib/apt/lists/*
USER karmashala
RUN curl -fsSL https://claude.ai/install.sh | bash
```

then `docker compose exec server claude` (and `codex login`) once to sign in,
and `docker compose exec server karmashala_host agents --refresh`. The compose
file keeps `/data` (store, config, pairings) and `/home/karmashala` (the
agents' sign-in and your clones) in volumes. Inside the container the listener
binds `0.0.0.0` — it has to, to be reachable through a published port — so
choose what reaches it by how the port is published, or publish nothing and
pair through a relay.

## Safety

- The control socket is a unix socket in an owner-only directory; there is no
  network control surface. `pair`, `devices`, `revoke` and `agents` work only
  as the user the server runs as, on its machine.
- The MCP endpoint and the hook listener are loopback-only, always.
- The phone listener speaks only the sealed companion protocol; a pairing needs
  the short-lived code, and every paired device holds its own capabilities.
  It binds loopback unless the config says otherwise.
- `server.json` (which can hold a relay token), the store and the data
  directory are owner-only.
- Stopping the server ends the sessions it holds, so nothing here stops it for
  you: the installer and uninstaller refuse while sessions run unless told.
