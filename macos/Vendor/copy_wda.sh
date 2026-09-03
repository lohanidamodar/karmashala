#!/bin/sh
# Copies the vendored WebDriverAgent runner into the built app bundle.
#
# The runner is an app bundle installed *into* a simulator, not a command, so
# it has to travel inside ours. Without this phase it existed only in the
# checkout, and `WdaLocator` found it only by its working-tree fallback — which
# resolves against the current directory. Running the binary from a terminal
# opened in the checkout therefore worked, and launching the very same build
# from Finder did not: cwd is `/`, the fallback missed, and the app reported no
# live view at all with nothing to say why.
#
# Deliberately not a Flutter asset: assets are copied into every platform's
# bundle, and a 60 MB XCTest runner has no business in the Windows build.
set -eu

source="${SRCROOT}/Vendor/wda"
destination="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/wda"

if [ ! -d "${source}" ]; then
  # Not an error: a checkout that has not run `tool/vendor/fetch_wda.sh` builds
  # fine, it just has no live view. Failing the build would make the vendored
  # blob mandatory for everyone touching the app.
  echo "warning: no vendored WebDriverAgent at ${source}; live view will be unavailable. Run tool/vendor/fetch_wda.sh"
  exit 0
fi

mkdir -p "${destination}"
# --delete so a stale runner from a previous pin cannot linger in the bundle.
rsync -a --delete "${source}/" "${destination}/"
