#!/bin/bash
#
# Fetches the WebDriverAgent runner, which is what gives an iOS Simulator a
# live view at all.
#
# `idb_companion`'s video_stream RPC crashes the companion process
# (facebook/idb#955), so the picture comes from WDA's MJPEG server instead. WDA
# runs *inside* the simulator as an XCTest bundle, which is why it needs no
# Simulator.app window and works against a headless `simctl boot`.
#
# Unlike idb_companion this ships for **both** architectures, so an Intel Mac
# gets a live view where it would get none from idb.
#
# Usage:  tool/vendor/fetch_wda.sh [destination]
# Default destination: macos/Vendor/wda (git-ignored)

set -euo pipefail

readonly WDA_VERSION="v16.12.0"
readonly WDA_SHA256_ARM64="5ef702d92d01c5cada5ed9a4d4e6175a4e7a89ab74acad7e8e2f7f91f7b215da"
readonly WDA_SHA256_X86_64="0f336b4674bf06627661ee7b5fdddcc1e860c16b511b17b6050e4a880e45cea0"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dest="${1:-$repo_root/macos/Vendor/wda}"
stamp="$dest/.wda-version"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "WebDriverAgent is macOS-only; nothing to fetch on $(uname -s)." >&2
  exit 0
fi

arch="$(uname -m)"
case "$arch" in
  arm64) asset="WebDriverAgentRunner-Build-Sim-arm64.zip"; want="$WDA_SHA256_ARM64" ;;
  x86_64) asset="WebDriverAgentRunner-Build-Sim-x86_64.zip"; want="$WDA_SHA256_X86_64" ;;
  *) echo "No WebDriverAgent build for $arch." >&2; exit 0 ;;
esac

# The runner is built against a specific Xcode, so the asset is per-arch and
# per-release. Both are pinned; a surprise here means the artifact is not the
# one that was reviewed.
readonly URL="https://github.com/appium/WebDriverAgent/releases/download/${WDA_VERSION}/${asset}"

if [[ -f "$stamp" ]] && [[ "$(cat "$stamp")" == "$WDA_VERSION $arch" ]]; then
  echo "WebDriverAgent $WDA_VERSION ($arch) already present."
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Fetching WebDriverAgent ${WDA_VERSION} ($arch)..."
curl --fail --location --progress-bar --output "$work/$asset" "$URL"

echo "Verifying checksum..."
actual="$(shasum -a 256 "$work/$asset" | awk '{print $1}')"
if [[ "$actual" != "$want" ]]; then
  echo "CHECKSUM MISMATCH - refusing to install." >&2
  echo "  expected $want" >&2
  echo "  actual   $actual" >&2
  exit 1
fi

mkdir -p "$work/extract"
unzip -q "$work/$asset" -d "$work/extract"

app="$(find "$work/extract" -maxdepth 2 -name 'WebDriverAgentRunner-Runner.app' -type d | head -1)"
if [[ -z "$app" ]]; then
  echo "No WebDriverAgentRunner-Runner.app in the archive." >&2
  exit 1
fi

rm -rf "$dest"
mkdir -p "$dest"
mv "$app" "$dest/"
echo "$WDA_VERSION $arch" > "$stamp"

echo "WebDriverAgent $WDA_VERSION installed at $dest"
du -sh "$dest"
