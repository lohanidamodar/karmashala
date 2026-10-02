#!/bin/bash
# Karmashala's macOS release recipe, versioned with the app it builds.
#
# The Windows half of this (`build_release.bat`) carries the reason both exist
# in the repository rather than on one machine: a recipe nobody can review is
# how `karmashala_mcp.exe` went unbuilt without anyone noticing. This is the
# same recipe for macOS, and it makes the same three things:
#
#   1. the app,
#   2. the MCP stdio bridge *inside the bundle*, and
#   3. a DMG to install from.
#
# Usage: tool/build_release.sh [--skip-build]
set -euo pipefail
cd "$(dirname "$0")/.."

# Read the version out of the app's pubspec.yaml so it cannot drift from what was built.
# The app logs "version not recorded" without the dart-define, which is the
# honest outcome rather than a stale number.
APPVER="$(grep '^version:' app/pubspec.yaml | awk '{print $2}')"
APPSHORT="${APPVER%%+*}"
APP="app/build/macos/Build/Products/Release/karmashala.app"
OUT="app/build/macos/karmashala-$APPSHORT.dmg"

if [ "${1:-}" != "--skip-build" ]; then
  echo "=== BUILDING $APPVER ==="
  (cd app && flutter build macos --release --dart-define=KARMASHALA_VERSION="$APPVER" --dart-define=KARMASHALA_RELAY_URL=wss://relay.popupbits.com)
fi
[ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }

# The MCP stdio bridge, compiled *into the bundle* next to the app binary,
# because `LauncherMcp.bridgeExecutable()` looks for it beside
# `Platform.resolvedExecutable`. Without it the Tools page cannot offer the
# stdio form to a user who wants to point an agent at Karmashala by hand.
echo "=== MCP BRIDGE ==="
flutter pub get --directory packages/mcp_bridge
dart compile exe packages/mcp_bridge/bin/karmashala_mcp.dart \
  -o "$APP/Contents/MacOS/karmashala_mcp"

# The session host for *this* machine, which is the local stage: the app starts
# it when a pane needs one and finds none running. `build_release.bat` has built
# it since 2026-09-15 and this recipe did not, so every macOS release shipped an
# app whose `LocalHostExecutable.locate()` could only ever return null.
#
# `dart build cli`, not `compile exe`: the host carries the app's store, so it
# depends on `sqlite3`, and `compile exe` refuses any target with a build hook.
# No `pub get` — `server` is a workspace member and the root resolution covers
# it.
#
# The output is a bundle and keeps its shape: the executable finds its SQLite at
# `../lib` and cannot be flattened beside the app binary. `Contents/MacOS/host`
# is the first place `LocalHostExecutable` looks.
#
# Only this machine's host is built here. The ones deployed to other machines
# are Linux bundles, built on Linux by the `build-host-linux` job — a bundle
# cross-compiled from the wrong OS writes the bundled library's relative path
# with the building machine's separator and cannot open a store on the far end.
echo "=== SESSION HOST (this machine) ==="
rm -rf build/host-macos "$APP/Contents/MacOS/host"
dart build cli -t server/bin/karmashala_host.dart -o build/host-macos
cp -R build/host-macos/bundle "$APP/Contents/MacOS/host"
# Ask the thing itself rather than trusting that a file appeared: a bundle whose
# dylib it cannot reach still has a binary in the right place.
"$APP/Contents/MacOS/host/bin/karmashala_host" probe-store
# And the pty layer, which `probe-store` never touches. Until 2026-09-16 the
# host loaded `libc.so.6` on every POSIX machine, so every macOS release shipped
# a host that could not start a single pane — and the store probe, the only one
# run here, passed throughout.
"$APP/Contents/MacOS/host/bin/karmashala_host" probe-pty

# The hosts this app deploys to SSH boxes, beside the app binary, where
# `DirectoryHostBinaries` looks first. Without them every deploy from a Mac
# answered `noBinary` — found 2026-09-17, when "use an SSH host as a relay"
# could put nothing on the box.
#
# Cross-built here, which `build_release.bat` cannot do: from Windows the
# bundled library's relative path is baked with `\` and the host cannot open a
# store on Linux. From macOS the separator is already `/`; the arm64 bundle was
# run in a Linux container that day and passed probe-store and probe-pty.
echo "=== SESSION HOSTS (linux, to deploy) ==="
rm -f "$APP"/Contents/MacOS/karmashala_host-*-linux-*.tar.gz
for arch in x64 arm64; do
  rm -rf "build/host-linux-$arch"
  dart build cli -t server/bin/karmashala_host.dart \
    --target-os=linux --target-arch="$arch" -o "build/host-linux-$arch"
  # No AppleDouble files or xattr headers: a Linux tar warns on every one.
  COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf \
    "$APP/Contents/MacOS/karmashala_host-$APPSHORT-linux-$arch.tar.gz" \
    -C "build/host-linux-$arch/bundle" .
done

# And this machine's own host again, packed for SSH boxes that are Macs. Only
# this architecture: the SDK cross-builds for Linux alone ("Unsupported target
# platform macos_x64" from an arm64 Mac, 2026-09-24), so an Intel Mac is served
# only by a release built on one.
echo "=== SESSION HOST (macos, to deploy) ==="
rm -f "$APP"/Contents/MacOS/karmashala_host-*-macos-*.tar.gz
case "$(uname -m)" in arm64) MACARCH=arm64 ;; *) MACARCH=x64 ;; esac
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf \
  "$APP/Contents/MacOS/karmashala_host-$APPSHORT-macos-$MACARCH.tar.gz" \
  -C build/host-macos/bundle .

# Re-sign after writing into the bundle: adding a file invalidates the seal
# Flutter's own build applied, and an app with a broken signature is refused by
# Gatekeeper with a message that names nothing useful. Ad-hoc (`-`) is what an
# unnotarised local build gets anyway.
echo "=== SIGN ==="
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "signature ok"

echo "=== DMG ==="
rm -f "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
# The Applications symlink is what makes the DMG a drag-to-install rather than
# a folder somebody runs the app out of — an app launched from a mounted image
# cannot write beside itself and its updates go nowhere.
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Karmashala $APPSHORT" -srcfolder "$STAGE" \
  -ov -format UDZO "$OUT" >/dev/null

echo "=== DONE ==="
ls -lh "$OUT"
