#!/usr/bin/env bash
# Removes what server/deploy/install.sh installed: the service, the bundle and
# the `karmashala_host` wrapper. The store and server.json — every phone's
# pairing — are kept unless --purge says otherwise.
#
#   server/deploy/uninstall.sh [--prefix <dir>] [--system] [--data-dir <dir>]
#                            [--purge] [--force] [--yes]
#
#   --prefix, --system   where the bundle was installed (as for install.sh)
#   --data-dir <dir>     the data directory (default ~/.karmashala)
#   --purge              also delete the data directory: the store, every
#                        pairing, server.json
#   --force              stop the server even while it runs sessions (ends them)
#   --yes                do not ask before --purge deletes
set -euo pipefail

say() { printf '%s\n' "$*"; }
die() { printf 'uninstall.sh: %s\n' "$*" >&2; exit 1; }

PREFIX=""
SYSTEM=0
DATA_DIR="${HOME}/.karmashala"
PURGE=0
FORCE=0
YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --system) SYSTEM=1; shift ;;
    --data-dir) DATA_DIR="${2:?--data-dir needs a directory}"; shift 2 ;;
    --purge) PURGE=1; shift ;;
    --force) FORCE=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done
if [ -z "$PREFIX" ]; then
  if [ "$SYSTEM" = 1 ]; then PREFIX=/opt/karmashala-server
  else PREFIX="${HOME}/.local/share/karmashala-server"; fi
fi
SUDO=""
if [ "$SYSTEM" = 1 ] && [ "$(id -u)" != 0 ]; then SUDO=sudo; fi
BIN="$PREFIX/current/bin/karmashala_host"
OS="$(uname -s)"

# Stopping the server ends every session it holds: said, and refused, first.
if [ -x "$BIN" ]; then
  HELD="$("$BIN" list 2>/dev/null | awk 'NR > 1 && $4 == "running"' | wc -l | tr -d ' ')"
  if [ "${HELD:-0}" -gt 0 ] && [ "$FORCE" = 0 ]; then
    die "the server is running $HELD session(s); end them first (karmashala_host list / end <id>), or pass --force to end them with it"
  fi
fi

if [ "$OS" = Linux ] && command -v systemctl >/dev/null; then
  UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/karmashala-server.service"
  systemctl --user disable --now karmashala-server 2>/dev/null || true
  rm -f "$UNIT"
  systemctl --user daemon-reload 2>/dev/null || true
  say "Removed the systemd user unit."
elif [ "$OS" = Darwin ]; then
  PLIST="$HOME/Library/LaunchAgents/com.karmashala.server.plist"
  launchctl bootout "gui/$(id -u)/com.karmashala.server" 2>/dev/null || true
  rm -f "$PLIST"
  say "Removed the launchd agent."
fi

# The wrapper, only if it is ours.
WRAPPER="${HOME}/.local/bin/karmashala_host"
if [ -f "$WRAPPER" ] && grep -q "$PREFIX/current/bin/karmashala_host" "$WRAPPER" 2>/dev/null; then
  rm -f "$WRAPPER"
fi

if [ -d "$PREFIX" ]; then
  $SUDO rm -rf "$PREFIX"
  say "Removed $PREFIX."
fi

if [ "$PURGE" = 1 ] && [ -d "$DATA_DIR" ]; then
  if [ "$YES" = 0 ]; then
    printf 'Delete %s — the store, every pairing and server.json? [y/N] ' "$DATA_DIR"
    read -r answer
    case "$answer" in y|Y|yes) ;; *) say "Kept $DATA_DIR."; exit 0 ;; esac
  fi
  rm -rf "$DATA_DIR"
  say "Deleted $DATA_DIR."
else
  say "Kept $DATA_DIR (the store and pairings; --purge deletes it)."
fi
