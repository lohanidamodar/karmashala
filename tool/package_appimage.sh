#!/usr/bin/env bash
# Packages the Linux release bundle as one AppImage file.
#
#   tool/package_appimage.sh <Karmashala-linux.tar.gz> <version>
#
# Writes Karmashala-<version>-x86_64.AppImage in the current directory. Needs
# curl, ImageMagick's `convert`, and the libraries the bundle links installed,
# so linuxdeploy can find and copy them. Set APPIMAGE_EXTRACT_AND_RUN=1 where
# there is no FUSE (CI runners, containers).
#
# The bundle goes in whole — Flutter finds lib/ and data/ beside the binary —
# and linuxdeploy adds the libraries it and its plugins link (mpv, libsecret,
# keybinder, appindicator, notify). GTK, X11, the graphics stack and D-Bus stay
# the host's, as AppImages expect: bundled copies break themes and drivers.
# What the bundle already carries in its lib/ dirs is never copied again.
set -euo pipefail

tarball=$1
version=$2
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

app="$work/AppDir/usr/lib/karmashala"
mkdir -p "$app"
tar -xzf "$tarball" -C "$app"

# linuxdeploy rewrites the binary's rpath to usr/lib, so the bundle's own lib/
# (the engine and the plugins, which are not copied) is named here too.
cat > "$work/AppDir/AppRun" <<'APPRUN'
#!/bin/sh
here="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$here/usr/lib/karmashala/lib:$here/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$here/usr/lib/karmashala/karmashala" "$@"
APPRUN
chmod +x "$work/AppDir/AppRun"

cat > "$work/karmashala.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Karmashala
Comment=Agent development environment
Exec=karmashala
Icon=karmashala
Categories=Development;
Terminal=false
StartupWMClass=karmashala
DESKTOP

# linuxdeploy takes standard icon sizes only; the app icon is 1024.
convert "$repo/app/assets/icon/app_icon.png" -resize 512x512 "$work/karmashala.png"

curl -fsSLo "$work/linuxdeploy" \
  https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
curl -fsSLo "$work/linuxdeploy-plugin-appimage" \
  https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-x86_64.AppImage
chmod +x "$work/linuxdeploy" "$work/linuxdeploy-plugin-appimage"

excluded=()
for lib in 'libgtk-3*' 'libgdk-3*' 'libgdk_pixbuf*' 'libglib-2.0*' \
           'libgobject-2.0*' 'libgio-2.0*' 'libgmodule-2.0*' 'libpango*' \
           'libcairo*' 'libatk*' 'libatspi*' 'libharfbuzz*' 'libfontconfig*' \
           'libfreetype*' 'libX*' 'libxcb*' 'libwayland*' 'libEGL*' 'libGL*' \
           'libepoxy*' 'libdrm*' 'libgbm*' 'libdbus-1*'; do
  excluded+=(--exclude-library "$lib")
done
# What the bundle already carries (the engine, the plugins, the app) stays
# where Flutter looks for it, beside the binary, and is not copied again.
for lib in "$app"/lib/*.so "$app"/host/lib/*.so; do
  [ -e "$lib" ] && excluded+=(--exclude-library "$(basename "$lib")")
done

out="$PWD/Karmashala-$version-x86_64.AppImage"
# The plugin is found beside linuxdeploy, on PATH. The bundle's own lib/ dirs
# are on the search path because its plugins link libflutter_linux_gtk.so
# beside them, which they otherwise reach only through the binary's rpath.
PATH="$work:$PATH" OUTPUT="$out" \
LD_LIBRARY_PATH="$app/lib:$app/host/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "$work/linuxdeploy" \
  --appdir "$work/AppDir" \
  --deploy-deps-only "$app/karmashala" \
  --deploy-deps-only "$app/lib" \
  --desktop-file "$work/karmashala.desktop" \
  --icon-file "$work/karmashala.png" \
  "${excluded[@]}" \
  --output appimage
ls -l "$out"
