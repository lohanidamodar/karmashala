# Desktop updates and distribution: which approach, and why

2026-11-23. The app side shipped on `main` as `GitHubUpdateController`
(PROJECT.md › In-app updates). This note records why it is a checker of our
own rather than Sparkle, and what the release pipeline and the package
managers add around it.

## The decision

**A small checker of our own, reading GitHub releases.** No Sparkle and no
WinSparkle (`auto_updater`).

- The app reads `api.github.com/repos/lohanidamodar/karmashala/releases/latest`
  with `If-None-Match`, 30 s after launch and every 6 h while *Check for
  updates automatically* is on, and when **Check for updates** is pressed in
  Settings › About.
- Every asset in that record carries GitHub's own SHA-256 `digest`. GitHub has
  added one since 2025; all 14 assets of v1.34.27 have one. A download is kept
  only if it matches. No separate feed file is needed.
- `detectInstallKind` decides what an update does. The Windows installer runs
  silently and relaunches the app. The AppImage is swapped in place. The DMG
  is opened. The portable zip and the tarball get the release page, and a Play
  install keeps Play's flow.

## Why not Sparkle / WinSparkle (`auto_updater`)

- **macOS needs a properly signed app first.** Sparkle swaps the bundle in
  place, and it requires EdDSA-signed updates (a key we do not have) plus a
  Developer ID-signed, notarised app. That is how Gatekeeper and TCC keep
  their grants across the swap. Today's DMG is **ad-hoc signed and not
  notarised** (`tool/build_release.sh`). Sparkle-updating an ad-hoc app either
  fails Gatekeeper on relaunch, or loses the app's permissions on every update
  (Accessibility, Automation, files). Opening the DMG is honest about where the
  build stands. Revisit once the Developer ID signing below is turned on.
- **WinSparkle would only run our Inno installer anyway.** It adds a native
  DLL, an appcast and a signing key, for a step that takes a few dozen lines.
- **No Linux.** `auto_updater` has no Linux support, so a custom path was
  needed regardless.
- **The portable zip and the tarball** must never be replaced (the person
  unpacked them where they chose). Sparkle knows nothing of that.
- **One verification rule, testable.** Version comparison, release parsing,
  install detection, asset choice and the digest check are pure Dart with unit
  tests.

## What it does not protect against

The release record and the files come from GitHub over HTTPS, and the SHA-256
is GitHub's own digest. That stops corrupted and truncated downloads. It does
**not** stop someone who can publish a release on the repository, because
they could publish a matching hash too. An asset with no digest falls back to
a size check. That fallback can be removed now that every upload has a
digest.

A signed release would close the gap: an Ed25519 key in CI, the public key
compiled into the app, and a signature file checked before anything runs. It
needs a key the owner generates and keeps, so it is left as the next step
rather than half done.

## Signing and the warnings people see

| | Today | With the CI steps' secrets |
| --- | --- | --- |
| macOS | Ad-hoc signature. Gatekeeper blocks the first open (right-click › Open). | Developer ID + hardened runtime, notarised and stapled. Opens without a prompt. |
| Windows | Unsigned. SmartScreen's "Windows protected your PC" on each new download. The silent update also shows a UAC prompt, because the installer is per-machine. | Authenticode-signed app and installer. SmartScreen fades as the certificate earns reputation (at once with an EV certificate). UAC still asks; that comes from the per-machine install, not the signature. |
| Linux | No signing expected. | — |

The CI steps run only once their secrets exist. Until then each logs a warning,
and the build is what it is today:

- `build-macos` imports `MACOS_DEVELOPER_ID_P12_BASE64` and
  `MACOS_DEVELOPER_ID_P12_PASSWORD` into a throwaway keychain. It signs the
  inner code first and the app last, with the hardened runtime and
  `Release.entitlements` (sandbox off, network on). Notarisation reuses the
  App Store Connect API key the iOS pipeline already has
  (`APP_STORE_CONNECT_KEY_ID`, `…_ISSUER_ID`, `…_KEY_CONTENT`;
  docs/releases.md), then staples.
- `build-windows` signs every exe and dll in the bundle, then the installer.
  It uses `WINDOWS_SIGNING_PFX_BASE64` and `WINDOWS_SIGNING_PFX_PASSWORD`, with
  a DigiCert timestamp.

**Never run: the secrets do not exist yet.** Expect the first signed macOS run
to need adjusting. The likeliest problem is the notary rejecting unsigned code
inside the bundle, such as the macOS host tarball that `build_release.sh`
packs into `Contents/MacOS` for SSH boxes.

## What CI adds on every release

- **`SHA256SUMS.txt`**: every file on the release, in `sha256sum` format,
  written by `tool/release_sums.dart` from the digests GitHub computed on
  upload, so nothing is downloaded again. Scoop's `autoupdate` reads it. The
  `publish-checksums` job runs even when one platform failed, and warns which
  desktop file is missing.
- **`Karmashala-<v>-x86_64.AppImage.zsync`**, with update information embedded
  in the AppImage (`gh-releases-zsync|lohanidamodar|karmashala|latest|…`), for
  AppImageUpdate and Gear Lever. The app's own updater swaps the whole file
  and does not use it. Untested until the next release run: the AppImage job
  uploads the `.zsync` only if the tools write one.
- **Homebrew and Scoop.** `bump-package-managers` regenerates the cask, the
  formula and the Scoop manifests (`tool/package_manifests.dart`). It commits
  them to the tap and the bucket once `PACKAGING_REPOS_TOKEN` exists.
- **winget.** `bump-winget` opens the `microsoft/winget-pkgs` pull request
  with `wingetcreate`, once `WINGET_SUBMIT` is `true` and `WINGET_TOKEN`
  exists.

packaging/README.md has the owner's steps and the one-line installs.

A copy installed by Scoop or Homebrew is seen as portable or as a DMG copy.
The app offers the release page, or opens the DMG, rather than the package
manager's own `scoop update` / `brew upgrade`. Teaching `detectInstallKind`
those two installs is a small follow-up.
