#!/usr/bin/env bash
# Installs the Karmashala server, a relay, or both on this machine (Linux or
# macOS), each as a per-user service: a systemd user unit on Linux, a launchd
# agent on macOS. Self-contained, so it runs straight from a release:
#
#   curl -fsSL https://github.com/lohanidamodar/karmashala/releases/latest/download/install.sh | bash
#   curl -fsSL …/install.sh | bash -s -- --with-relay --host my.box.example
#
#   install.sh [<bundle>] [options]
#
# With no <bundle>, the server bundle for this OS and CPU is downloaded from
# the latest release (or --version). <bundle> may instead be what
# `dart build cli -t server/bin/karmashala_host.dart` produced: the `bundle/`
# directory, a .tar.gz of its contents, or an http(s) URL of one.
#
# What it installs:
#   (default)            the server, which runs agent sessions and serves the
#                        phone and desktop clients paired with it
#   --relay              only a relay: a meeting point for a server and its
#                        clients when neither can dial the other
#   --with-relay         both, the server using this relay
#
# Options:
#   --version <v>        the release to download (default: the latest)
#   --host <addr>        the address clients reach this machine at (default:
#                        its first non-loopback address)
#   --lan                serve clients on this network directly: listen on
#                        every interface and announce on the LAN beacon
#   --bind <ip>          where the phone listener binds (default 127.0.0.1;
#                        0.0.0.0 for direct pairing, or a tailnet address)
#   --port <n>           the phone listener's port (default 47820)
#   --relay-url <url>    a relay elsewhere for the server to use
#   --relay-token <t>    that relay's access token (32+ url-safe characters)
#   --relay-port <n>     the port a relay installed here listens on (default 8787)
#   --name <name>        what clients call this server (default: the hostname)
#   --beacon             announce this server on the LAN beacon
#   --no-companion       write the config with clients not served
#   --prefix <dir>       where the bundle goes (default
#                        ~/.local/share/karmashala-server; --system: /opt/karmashala-server)
#   --system             install under /opt with sudo; the services stay this user's
#   --data-dir <dir>     the store and server.json (default ~/.karmashala)
#   --force-config       replace an existing server.json with these options
#   --restart            restart a running server even if it holds sessions
#                        (ends them)
#   --no-service         install the bundle and config only
#   --no-pair            do not open a pairing window at the end
#   -h, --help           this text
#
# The bundle is never flattened: bin/ and lib/ stay side by side, because the
# binary finds its bundled SQLite at ../lib.
set -euo pipefail

usage() { sed -n '2,50p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true; }
say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

REPO="${KARMASHALA_REPO:-lohanidamodar/karmashala}"
SOURCE=""
VERSION_WANTED=""
PREFIX=""
SYSTEM=0
DATA_DIR="${HOME}/.karmashala"
# A server installed for clients serves them; `serve` alone would not until
# its config said so.
INIT_FLAGS=("--companion")
FORCE_CONFIG=0
RESTART=0
SERVICE=1
PAIR=1
WANT_SERVER=1
WANT_RELAY=0
HOST=""
BIND=""
PORT=47820
RELAY_URL=""
RELAY_TOKEN=""
RELAY_PORT=8787

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION_WANTED="${2:?--version needs a version}"; shift 2 ;;
    --relay) WANT_SERVER=0; WANT_RELAY=1; shift ;;
    --with-relay) WANT_RELAY=1; shift ;;
    --host) HOST="${2:?--host needs an address}"; shift 2 ;;
    --lan) BIND=0.0.0.0; INIT_FLAGS+=("--beacon"); shift ;;
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --system) SYSTEM=1; shift ;;
    --data-dir) DATA_DIR="${2:?--data-dir needs a directory}"; shift 2 ;;
    --name) INIT_FLAGS+=("--name=${2:?--name needs a value}"); shift 2 ;;
    --bind) BIND="${2:?--bind needs an address}"; shift 2 ;;
    --port) PORT="${2:?--port needs a number}"; shift 2 ;;
    --relay-url) RELAY_URL="${2:?--relay-url needs a URL}"; shift 2 ;;
    --relay-token) RELAY_TOKEN="${2:?--relay-token needs a token}"; shift 2 ;;
    --relay-port) RELAY_PORT="${2:?--relay-port needs a number}"; shift 2 ;;
    --beacon) INIT_FLAGS+=("--beacon"); shift ;;
    --no-companion) INIT_FLAGS+=("--no-companion"); shift ;;
    --force-config) FORCE_CONFIG=1; shift ;;
    --restart) RESTART=1; shift ;;
    --no-service) SERVICE=0; shift ;;
    --no-pair) PAIR=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *)
      [ -z "$SOURCE" ] || die "one bundle at a time (got '$SOURCE' and '$1')"
      SOURCE="$1"; shift ;;
  esac
done
[ "$WANT_RELAY" = 1 ] && [ -n "$RELAY_URL" ] \
  && die "--relay-url names a relay elsewhere; --relay and --with-relay install one here"

OS="$(uname -s)"
case "$OS" in
  Linux) PLATFORM=linux ;;
  Darwin) PLATFORM=macos ;;
  *) die "this installer is for Linux and macOS; on Windows use install.ps1" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=x64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "no server bundle is built for $(uname -m)" ;;
esac

# The address clients reach this machine at: given, or the first non-loopback
# one, which is right on a LAN and on most VPSs and wrong behind NAT.
if [ -z "$HOST" ]; then
  if [ "$PLATFORM" = linux ]; then
    HOST="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    # The routing table's own answer, where `hostname -I` is missing; a lookup,
    # not traffic.
    [ -n "$HOST" ] || HOST="$(ip -4 route get 192.0.2.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' || true)"
  else
    HOST="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  fi
  HOST="${HOST:-127.0.0.1}"
  HOST_GUESSED=1
else
  HOST_GUESSED=0
fi

if [ -z "$PREFIX" ]; then
  if [ "$SYSTEM" = 1 ]; then PREFIX=/opt/karmashala-server
  else PREFIX="${HOME}/.local/share/karmashala-server"; fi
fi
SUDO=""
if [ "$SYSTEM" = 1 ] && [ "$(id -u)" != 0 ]; then
  command -v sudo >/dev/null || die "--system needs sudo"
  SUDO=sudo
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. The bundle, into a directory of our own.
if [ -z "$SOURCE" ]; then
  command -v curl >/dev/null || die "curl is needed to download the server"
  TAG="v${VERSION_WANTED#v}"
  if [ -z "$VERSION_WANTED" ]; then
    # The latest release's tag, from where /releases/latest redirects to.
    TAG="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")"
    TAG="${TAG##*/}"
    case "$TAG" in v*) ;; *) die "could not find the latest release of $REPO" ;; esac
  fi
  SOURCE="https://github.com/$REPO/releases/download/$TAG/karmashala_host-${TAG#v}-$PLATFORM-$ARCH.tar.gz"
fi
STAGE="$WORK/bundle"
mkdir -p "$STAGE"
case "$SOURCE" in
  http://*|https://*)
    say "Downloading $SOURCE"
    curl -fL --proto '=https,http' -o "$WORK/bundle.tar.gz" "$SOURCE" \
      || die "could not download $SOURCE"
    tar -xzf "$WORK/bundle.tar.gz" -C "$STAGE" ;;
  *.tar.gz|*.tgz)
    [ -f "$SOURCE" ] || die "$SOURCE is not a file"
    tar -xzf "$SOURCE" -C "$STAGE" ;;
  *)
    [ -d "$SOURCE" ] || die "$SOURCE is neither a directory, a .tar.gz nor a URL"
    cp -R "$SOURCE"/. "$STAGE"/ ;;
esac
# A tarball of the `bundle/` folder itself rather than its contents.
if [ ! -f "$STAGE/bin/karmashala_host" ] && [ -f "$STAGE/bundle/bin/karmashala_host" ]; then
  STAGE="$STAGE/bundle"
fi
[ -f "$STAGE/bin/karmashala_host" ] || die "no bin/karmashala_host in $SOURCE — is it a \`dart build cli\` bundle?"
chmod +x "$STAGE/bin/karmashala_host"

# 2. Proven on this machine before anything is replaced: a bundle built for
# another OS or CPU, or one whose SQLite will not load, stops here. A relay
# alone needs neither a terminal nor a store.
"$STAGE/bin/karmashala_host" version >/dev/null 2>&1 \
  || die "the bundle does not run on this machine ($(uname -sm)) — is it the right OS and architecture?"
if [ "$WANT_SERVER" = 1 ]; then
  "$STAGE/bin/karmashala_host" probe-pty >"$WORK/probe-pty.txt" 2>&1 \
    || { cat "$WORK/probe-pty.txt" >&2; die "the bundle cannot open a terminal here (probe-pty failed)"; }
  "$STAGE/bin/karmashala_host" probe-store >"$WORK/probe-store.txt" 2>&1 \
    || { cat "$WORK/probe-store.txt" >&2; die "the bundle cannot hold a store here (probe-store failed)"; }
fi
say "Bundle: $("$STAGE/bin/karmashala_host" version)"

# 3. Installed side by side with any earlier one; `current` names the live one.
RELEASE="$PREFIX/releases/$(date +%Y%m%d%H%M%S)"
$SUDO mkdir -p "$RELEASE"
$SUDO cp -R "$STAGE"/. "$RELEASE"/
$SUDO ln -sfn "$RELEASE" "$PREFIX/current.new"
$SUDO mv -f "$PREFIX/current.new" "$PREFIX/current" 2>/dev/null \
  || { $SUDO rm -rf "$PREFIX/current"; $SUDO mv "$PREFIX/current.new" "$PREFIX/current"; }
BIN="$PREFIX/current/bin/karmashala_host"
say "Installed to $RELEASE"

# A command on PATH. A wrapper, not a symlink: the binary finds its lib/ next
# to where it really is.
mkdir -p "${HOME}/.local/bin"
cat >"${HOME}/.local/bin/karmashala_host" <<EOF
#!/bin/sh
exec "$BIN" "\$@"
EOF
chmod +x "${HOME}/.local/bin/karmashala_host"
case ":$PATH:" in
  *":${HOME}/.local/bin:"*) ;;
  *) say "Note: add ~/.local/bin to your PATH to run \`karmashala_host\` by name." ;;
esac

# 4. A relay installed here: its token is minted now, owner-only, so the URL
# clients use is known before anything starts.
RELAY_TOKEN_FILE="$DATA_DIR/relay-token"
RELAY_PID_FILE="$DATA_DIR/relay.pid"
if [ "$WANT_RELAY" = 1 ]; then
  mkdir -p "$DATA_DIR" && chmod 700 "$DATA_DIR"
  if [ ! -s "$RELAY_TOKEN_FILE" ]; then
    (umask 077; head -c 30 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' >"$RELAY_TOKEN_FILE")
  fi
  RELAY_TOKEN="$(cat "$RELAY_TOKEN_FILE")"
  RELAY_URL="ws://$HOST:$RELAY_PORT"
fi

# 5. The server's config: written by the bundle itself, owner-only from its
# first byte, and never replaced unless asked.
if [ "$WANT_SERVER" = 1 ]; then
  [ -n "$BIND" ] && INIT_FLAGS+=("--bind=$BIND")
  INIT_FLAGS+=("--companion-port=$PORT")
  if [ -n "$RELAY_URL" ]; then
    INIT_FLAGS+=("--relay=$RELAY_URL")
    [ -n "$RELAY_TOKEN" ] && INIT_FLAGS+=("--relay-token=$RELAY_TOKEN")
  fi
  if [ -f "$DATA_DIR/server.json" ] && [ "$FORCE_CONFIG" = 0 ]; then
    say "Keeping $DATA_DIR/server.json (--force-config replaces it with these options)."
  else
    FORCE=()
    [ "$FORCE_CONFIG" = 1 ] && FORCE=(--force)
    "$BIN" init "--data-dir=$DATA_DIR" "${INIT_FLAGS[@]}" ${FORCE[@]+"${FORCE[@]}"}
  fi
fi

if [ "$SERVICE" = 0 ]; then
  say "Not installing a service (--no-service). Run it yourself:"
  [ "$WANT_SERVER" = 1 ] && say "  $BIN serve --data-dir=$DATA_DIR"
  [ "$WANT_RELAY" = 1 ] && say "  $BIN relay --port=$RELAY_PORT --token-file=$RELAY_TOKEN_FILE --pid-file=$RELAY_PID_FILE"
  exit 0
fi

# The services find the agent CLIs on this PATH — the one you installed them
# on — plus the usual places they land.
SERVICE_PATH="${HOME}/.local/bin:${PATH}"

# 6. A running server holding sessions is not restarted unless asked: that
# would end every one of them.
running_sessions() {
  "$BIN" list 2>/dev/null | awk 'NR > 1 && $4 == "running"' | wc -l | tr -d ' '
}
restart_allowed() {
  local held
  held="$(running_sessions)"
  if [ "${held:-0}" -gt 0 ] && [ "$RESTART" = 0 ]; then
    say "The server is running $held session(s); it was not restarted, so they keep running."
    say "Restart it when you are ready (this ends them): $1"
    return 1
  fi
  return 0
}

# --- Linux: systemd user units ---------------------------------------------
systemd_unit() {
  # $1 name, $2 description, $3 the command after the binary.
  cat <<EOF
# $2 — a systemd *user* unit, installed by Karmashala's install.sh. A user
# unit on purpose: the agents it runs are signed in as this user.
[Unit]
Description=$2
Documentation=https://github.com/$REPO/blob/main/server/README.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN $3
Environment=PATH=$SERVICE_PATH
UMask=0077
# Restarted after a crash; never after a stop somebody asked for.
Restart=on-failure
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=default.target
EOF
}

linux_service() {
  # $1 unit name, $2 description, $3 the command after the binary, $4 1 to
  # guard a restart that would end sessions.
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$dir"
  systemd_unit "$1" "$2" "$3" >"$dir/$1.service"
  systemctl --user daemon-reload
  if systemctl --user is-active --quiet "$1"; then
    if [ "$4" = 0 ] || restart_allowed "systemctl --user restart $1"; then
      systemctl --user restart "$1"
    fi
  else
    systemctl --user enable --now "$1"
  fi
  systemctl --user enable "$1" >/dev/null 2>&1 || true
  say "Service: systemctl --user status $1   (logs: journalctl --user -u $1)"
}

# --- macOS: launchd agents -------------------------------------------------
launchd_plist() {
  # $1 label, $2 log, then the program's arguments.
  local label=$1 log=$2
  shift 2
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
EOF
  for arg in "$@"; do printf '    <string>%s</string>\n' "$arg"; done
  cat <<EOF
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$SERVICE_PATH</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>Umask</key>
  <integer>63</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$log</string>
  <key>StandardErrorPath</key>
  <string>$log</string>
</dict>
</plist>
EOF
}

macos_service() {
  # $1 label, $2 1 to guard a restart that would end sessions, then the
  # program's arguments after the binary.
  local label=$1 guard=$2
  shift 2
  local plist="$HOME/Library/LaunchAgents/$label.plist"
  local log="$HOME/Library/Logs/$label.log"
  local domain="gui/$(id -u)"
  mkdir -p "$(dirname "$plist")" "$(dirname "$log")"
  launchd_plist "$label" "$log" "$BIN" "$@" >"$plist"
  if launchctl print "$domain/$label" >/dev/null 2>&1; then
    if [ "$guard" = 0 ] || restart_allowed "launchctl kickstart -k $domain/$label"; then
      launchctl bootout "$domain/$label" 2>/dev/null || true
      launchctl bootstrap "$domain" "$plist"
    fi
  else
    launchctl bootstrap "$domain" "$plist"
  fi
  say "Service: launchctl print $domain/$label   (log: $log)"
}

if [ "$PLATFORM" = linux ]; then
  command -v systemctl >/dev/null \
    || die "no systemctl here; run the server under your own supervisor (--no-service prints the commands)"
fi

# 7. The relay first, so a server pointed at it finds it up.
if [ "$WANT_RELAY" = 1 ]; then
  RELAY_ARGS="relay --port=$RELAY_PORT --token-file=$RELAY_TOKEN_FILE --pid-file=$RELAY_PID_FILE"
  if [ "$PLATFORM" = linux ]; then
    linux_service karmashala-relay "Karmashala relay" "$RELAY_ARGS" 0
  else
    macos_service com.karmashala.relay 0 relay "--port=$RELAY_PORT" "--token-file=$RELAY_TOKEN_FILE" "--pid-file=$RELAY_PID_FILE"
  fi
fi

if [ "$WANT_SERVER" = 1 ]; then
  # One host per user: a host this service does not own (the desktop app's,
  # an SSH-deployed one) holds the socket and the lock, and the service would
  # only crash-loop behind it.
  ours_active() {
    if [ "$PLATFORM" = linux ]; then systemctl --user is-active --quiet karmashala-server 2>/dev/null
    else launchctl print "gui/$(id -u)/com.karmashala.server" >/dev/null 2>&1; fi
  }
  if ! ours_active && "$BIN" list >/dev/null 2>&1; then
    die "a karmashala_host is already running for $USER (the desktop app's, or one deployed over SSH). On a machine where you use the desktop app, that host already is the server; otherwise stop it (karmashala_host stop) and run this again."
  fi
  if [ "$PLATFORM" = linux ]; then
    linux_service karmashala-server "Karmashala server" "serve --data-dir=$DATA_DIR" 1
  else
    macos_service com.karmashala.server 1 serve "--data-dir=$DATA_DIR"
  fi
fi

# Without lingering, a user service stops when the last SSH session ends.
if [ "$PLATFORM" = linux ] && command -v loginctl >/dev/null \
  && [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo no)" != yes ]; then
  if loginctl enable-linger "$USER" 2>/dev/null || sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
    say "Enabled lingering for $USER, so the services run with nobody logged in."
  else
    say "Run \`sudo loginctl enable-linger $USER\` so the services keep running after you log out."
  fi
fi

say ""
if [ "$WANT_RELAY" = 1 ]; then
  say "Relay: $RELAY_URL/k/$RELAY_TOKEN"
  say "  Clients and servers elsewhere use that URL; open TCP $RELAY_PORT in the firewall."
  [ "$HOST_GUESSED" = 1 ] && say "  $HOST was guessed; pass --host with the address clients really reach."
fi
[ "$WANT_SERVER" = 1 ] || exit 0

# 8. Pair the first client now: the window names whichever route is set up.
if [ "$PAIR" = 0 ]; then
  say "Pair a client later with: karmashala_host pair"
  exit 0
fi
for _ in $(seq 1 30); do "$BIN" list >/dev/null 2>&1 && break; sleep 1; done
"$BIN" list >/dev/null 2>&1 || die "the server did not come up; see its service log above"
if [ -n "$RELAY_URL" ]; then
  say "Opening a pairing window through the relay. Scan the QR with the Karmashala app,"
  say "or add a machine by code. Ctrl+C stops waiting; the server keeps running."
  "$BIN" pair || true
elif [ -n "$BIND" ] && [ "$BIND" != 127.0.0.1 ]; then
  say "Opening a pairing window at $HOST:$PORT. Scan the QR with the Karmashala app,"
  say "or add a machine by address. Ctrl+C stops waiting; the server keeps running."
  "$BIN" pair "--address=$HOST:$PORT" || true
else
  say "The server listens on this machine only, so no client can reach it yet. Run this"
  say "again with --lan (same network), --with-relay (a relay here), or"
  say "--relay-url <url> (a relay elsewhere), then pair with: karmashala_host pair"
fi
