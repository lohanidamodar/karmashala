#!/usr/bin/env bash
# Installs a Karmashala server bundle on this machine (Linux or macOS) and runs
# it as a per-user service: a systemd user unit on Linux, a launchd agent on
# macOS. See server/README.md.
#
#   server/deploy/install.sh <bundle> [options]
#
# <bundle> is what `dart build cli -t server/bin/karmashala_host.dart`
# produced, in any of three shapes:
#   - a directory holding bin/karmashala_host and lib/ (the `bundle/` folder),
#   - a .tar.gz of that directory's contents (the release asset
#     karmashala_host-<version>-linux-<arch>.tar.gz),
#   - an http(s) URL of such a .tar.gz.
#
# Options:
#   --prefix <dir>       where the bundle goes (default
#                        ~/.local/share/karmashala-server; --system: /opt/karmashala-server)
#   --system             install under /opt with sudo; the service stays this user's
#   --data-dir <dir>     the store and server.json (default ~/.karmashala)
#   --name <name>        what phones call this server (default: the hostname)
#   --bind <ip>          where the phone listener binds (default 127.0.0.1;
#                        0.0.0.0 for direct pairing, or a tailnet address)
#   --port <n>           the phone listener's port (default 47820)
#   --relay <url>        the relay phones meet this server at
#   --relay-token <t>    that relay's access token (32+ url-safe characters)
#   --beacon             announce this server on the LAN beacon
#   --no-companion       write the config with phones not served (the
#                        installer turns them on by default)
#   --force-config       replace an existing server.json with these options
#   --restart            restart a running server even if it holds sessions
#                        (ends them)
#   --no-service         install the bundle and config only
#   -h, --help           this text
#
# The bundle is never flattened: bin/ and lib/ stay side by side, because the
# binary finds its bundled SQLite at ../lib.
set -euo pipefail

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; }
say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

SOURCE=""
PREFIX=""
SYSTEM=0
DATA_DIR="${HOME}/.karmashala"
# A server installed for phones serves them; `serve` alone would not until
# its config said so.
INIT_FLAGS=("--companion")
FORCE_CONFIG=0
RESTART=0
SERVICE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --system) SYSTEM=1; shift ;;
    --data-dir) DATA_DIR="${2:?--data-dir needs a directory}"; shift 2 ;;
    --name) INIT_FLAGS+=("--name=${2:?--name needs a value}"); shift 2 ;;
    --bind) INIT_FLAGS+=("--bind=${2:?--bind needs an address}"); shift 2 ;;
    --port) INIT_FLAGS+=("--companion-port=${2:?--port needs a number}"); shift 2 ;;
    --relay) INIT_FLAGS+=("--relay=${2:?--relay needs a URL}"); shift 2 ;;
    --relay-token) INIT_FLAGS+=("--relay-token=${2:?--relay-token needs a token}"); shift 2 ;;
    --beacon) INIT_FLAGS+=("--beacon"); shift ;;
    --no-companion) INIT_FLAGS+=("--no-companion"); shift ;;
    --force-config) FORCE_CONFIG=1; shift ;;
    --restart) RESTART=1; shift ;;
    --no-service) SERVICE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *)
      [ -z "$SOURCE" ] || die "one bundle at a time (got '$SOURCE' and '$1')"
      SOURCE="$1"; shift ;;
  esac
done
[ -n "$SOURCE" ] || { usage; die "name the bundle to install"; }

OS="$(uname -s)"
case "$OS" in
  Linux|Darwin) ;;
  *) die "this installer is for Linux and macOS; on $OS run \`karmashala_host serve\` yourself" ;;
esac

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
STAGE="$WORK/bundle"
mkdir -p "$STAGE"
case "$SOURCE" in
  http://*|https://*)
    say "Downloading $SOURCE"
    curl -fL --proto '=https,http' -o "$WORK/bundle.tar.gz" "$SOURCE"
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
# another OS or CPU, or one whose SQLite will not load, stops here.
"$STAGE/bin/karmashala_host" version >/dev/null 2>&1 \
  || die "the bundle does not run on this machine ($(uname -sm)) — is it the right OS and architecture?"
"$STAGE/bin/karmashala_host" probe-pty >"$WORK/probe-pty.txt" 2>&1 \
  || { cat "$WORK/probe-pty.txt" >&2; die "the bundle cannot open a terminal here (probe-pty failed)"; }
"$STAGE/bin/karmashala_host" probe-store >"$WORK/probe-store.txt" 2>&1 \
  || { cat "$WORK/probe-store.txt" >&2; die "the bundle cannot hold a store here (probe-store failed)"; }
VERSION="$("$STAGE/bin/karmashala_host" version)"
say "Bundle: $VERSION"

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

# 4. The config: written by the bundle itself, owner-only from its first byte,
# and never replaced unless asked.
if [ -f "$DATA_DIR/server.json" ] && [ "$FORCE_CONFIG" = 0 ]; then
  say "Keeping $DATA_DIR/server.json (--force-config replaces it)."
  [ "${#INIT_FLAGS[@]}" = 1 ] || say "  The config options given were not applied."
else
  FORCE=()
  [ "$FORCE_CONFIG" = 1 ] && FORCE=(--force)
  "$BIN" init "--data-dir=$DATA_DIR" ${INIT_FLAGS[@]+"${INIT_FLAGS[@]}"} ${FORCE[@]+"${FORCE[@]}"}
fi

[ "$SERVICE" = 1 ] || { say "Not installing a service (--no-service). Run: $BIN serve --data-dir=$DATA_DIR"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
render() {
  # $1 template, $2 destination. Paths are escaped for sed's replacement side.
  local esc_bin esc_data esc_path esc_log
  esc_bin=$(printf '%s' "$BIN" | sed 's/[&|\\]/\\&/g')
  esc_data=$(printf '%s' "$DATA_DIR" | sed 's/[&|\\]/\\&/g')
  esc_path=$(printf '%s' "$SERVICE_PATH" | sed 's/[&|\\]/\\&/g')
  esc_log=$(printf '%s' "${LOG:-}" | sed 's/[&|\\]/\\&/g')
  sed -e "s|@BIN@|$esc_bin|g" -e "s|@DATA_DIR@|$esc_data|g" \
      -e "s|@PATH@|$esc_path|g" -e "s|@LOG@|$esc_log|g" "$1" >"$2"
}
# The service finds the agent CLIs on this PATH — the one you installed them
# on — plus the usual places they land.
SERVICE_PATH="${HOME}/.local/bin:${PATH}"

# 5. A running server holding sessions is not restarted unless asked: that
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

# One host per user: a host this service does not own (the desktop app's, an
# SSH-deployed one) holds the socket and the lock, and the service would only
# crash-loop behind it.
ours_active() {
  if [ "$OS" = Linux ]; then systemctl --user is-active --quiet karmashala-server 2>/dev/null
  else launchctl print "gui/$(id -u)/com.karmashala.server" >/dev/null 2>&1; fi
}
if ! ours_active && "$BIN" list >/dev/null 2>&1; then
  die "a karmashala_host is already running for $USER (the desktop app's, or one deployed over SSH). On a machine where you use the desktop app, that host already is the server; otherwise stop it (karmashala_host stop) and run this again."
fi

if [ "$OS" = Linux ]; then
  command -v systemctl >/dev/null || die "no systemctl here; run \`$BIN serve --data-dir=$DATA_DIR\` under your own supervisor"
  UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$UNIT_DIR"
  render "$HERE/templates/karmashala-server.service" "$UNIT_DIR/karmashala-server.service"
  systemctl --user daemon-reload
  if systemctl --user is-active --quiet karmashala-server; then
    if restart_allowed "systemctl --user restart karmashala-server"; then
      systemctl --user restart karmashala-server
    fi
  else
    systemctl --user enable --now karmashala-server
  fi
  systemctl --user enable karmashala-server >/dev/null 2>&1 || true
  # Without lingering, a user service stops when the last SSH session ends.
  if command -v loginctl >/dev/null && [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo no)" != yes ]; then
    if loginctl enable-linger "$USER" 2>/dev/null || sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
      say "Enabled lingering for $USER, so the server runs with nobody logged in."
    else
      say "Run \`sudo loginctl enable-linger $USER\` so the server keeps running after you log out."
    fi
  fi
  say "Service: systemctl --user status karmashala-server   (logs: journalctl --user -u karmashala-server)"
else
  AGENT_DIR="$HOME/Library/LaunchAgents"
  PLIST="$AGENT_DIR/com.karmashala.server.plist"
  LOG="$HOME/Library/Logs/karmashala-server.log"
  mkdir -p "$AGENT_DIR" "$(dirname "$LOG")"
  render "$HERE/templates/com.karmashala.server.plist" "$PLIST"
  DOMAIN="gui/$(id -u)"
  if launchctl print "$DOMAIN/com.karmashala.server" >/dev/null 2>&1; then
    if restart_allowed "launchctl kickstart -k $DOMAIN/com.karmashala.server"; then
      launchctl bootout "$DOMAIN/com.karmashala.server" 2>/dev/null || true
      launchctl bootstrap "$DOMAIN" "$PLIST"
    fi
  else
    launchctl bootstrap "$DOMAIN" "$PLIST"
  fi
  say "Service: launchctl print $DOMAIN/com.karmashala.server   (log: $LOG)"
fi

say ""
say "Next: pair a phone with \`karmashala_host pair --address=<this machine's address>\`"
say "(server/README.md: direct, relay and tailnet pairing, and the firewall)."
