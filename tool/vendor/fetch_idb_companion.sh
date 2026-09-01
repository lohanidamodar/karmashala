#!/bin/bash
#
# Fetches the vendored idb_companion, the way scrcpy-server is vendored — except
# that this one is not committed.
#
#   assets/scrcpy/scrcpy-server   734 KB, committed
#   idb_companion (pruned)         45 MB on disk, 11 MB compressed
#
# Sixty times larger, and a new blob on every idb bump, so committing it would
# grow the history by that much per release. It is fetched instead, pinned to a
# version AND a checksum: an unpinned download is an unreviewed binary running
# with the user's Xcode.
#
# Usage:  tool/vendor/fetch_idb_companion.sh [destination]
# Default destination: macos/Vendor/idb-companion (git-ignored)

set -euo pipefail

readonly IDB_VERSION="v1.5.2"
readonly IDB_SHA256="f17b718a513931705542a7fbfa9cfc11895ee191562c9ffd2343cf7f8254bc08"
readonly IDB_ASSET="idb-companion.macos-arm64.tar.gz"
readonly IDB_URL="https://github.com/facebook/idb/releases/download/${IDB_VERSION}/${IDB_ASSET}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dest="${1:-$repo_root/macos/Vendor/idb-companion}"
stamp="$dest/.idb-version"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "idb_companion is macOS-only; nothing to fetch on $(uname -s)." >&2
  exit 0
fi

# The release ships arm64 only — there is no x86_64 slice, so Rosetta cannot
# help either. An Intel Mac gets no live view rather than a broken one.
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "idb_companion ships arm64 only; skipping on $(uname -m)." >&2
  echo "The simulator pane will list, boot and screenshot, but not mirror." >&2
  exit 0
fi

if [[ -f "$stamp" ]] && [[ "$(cat "$stamp")" == "$IDB_VERSION" ]]; then
  echo "idb_companion $IDB_VERSION already present."
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Fetching idb_companion ${IDB_VERSION}..."
curl --fail --location --progress-bar --output "$work/$IDB_ASSET" "$IDB_URL"

echo "Verifying checksum..."
actual="$(shasum -a 256 "$work/$IDB_ASSET" | awk '{print $1}')"
if [[ "$actual" != "$IDB_SHA256" ]]; then
  # Refused rather than warned: the whole point of pinning is that a surprise
  # here means the artifact is not the one that was reviewed.
  echo "CHECKSUM MISMATCH — refusing to install." >&2
  echo "  expected $IDB_SHA256" >&2
  echo "  actual   $actual" >&2
  exit 1
fi

mkdir -p "$work/extract"
tar -xzf "$work/$IDB_ASSET" -C "$work/extract"

# The tarball has a single top-level directory whose name varies by release.
payload="$(find "$work/extract" -maxdepth 2 -name idb_companion -type f | head -1)"
if [[ -z "$payload" ]]; then
  echo "No idb_companion binary in the archive." >&2
  exit 1
fi
payload_dir="$(dirname "$payload")"

# `idb-repl` is a second 33 MB executable for idb's own REPL, which nothing
# here calls. The companion's `repl` RPC uses Resources/libRepl-*.dylib and
# ReplHost.app, not this binary.
rm -f "$payload_dir/idb-repl"

# `Resources/` must stay beside the executable. The companion resolves it as
# dirname(realpath(argv[0])) + "/Resources", and without it the accessibility
# path fails outright with "The SimulatorFrameworkBridge guest binary was not
# found in the companion Resources directory" — i.e. no element tree.
if [[ ! -d "$payload_dir/Resources" ]]; then
  echo "The archive has no sibling Resources/ directory; refusing." >&2
  exit 1
fi

rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
mv "$payload_dir" "$dest"
echo "$IDB_VERSION" > "$stamp"

echo "idb_companion $IDB_VERSION installed at $dest"
du -sh "$dest"
