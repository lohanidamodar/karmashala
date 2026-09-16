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

# Read the version out of pubspec.yaml so it cannot drift from what was built.
# The app logs "version not recorded" without the dart-define, which is the
# honest outcome rather than a stale number.
APPVER="$(grep '^version:' pubspec.yaml | awk '{print $2}')"
APPSHORT="${APPVER%%+*}"
APP="build/macos/Build/Products/Release/karmashala.app"
OUT="build/macos/karmashala-$APPSHORT.dmg"

if [ "${1:-}" != "--skip-build" ]; then
  echo "=== BUILDING $APPVER ==="
  flutter build macos --release --dart-define=KARMASHALA_VERSION="$APPVER"
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
# No `pub get` — `packages/host` is a workspace member and the root resolution
# covers it.
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
dart build cli -t packages/host/bin/karmashala_host.dart -o build/host-macos
cp -R build/host-macos/bundle "$APP/Contents/MacOS/host"
# Ask the thing itself rather than trusting that a file appeared: a bundle whose
# dylib it cannot reach still has a binary in the right place.
"$APP/Contents/MacOS/host/bin/karmashala_host" probe-store

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
