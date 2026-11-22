# Package-manager manifests

What Homebrew, Scoop and winget need to install Karmashala. Every file here is
the output of [`tool/package_manifests.dart`](../tool/package_manifests.dart)
for the newest release (now **1.34.27**, hashes from that release). Edit the
script, never these files, and regenerate:

```sh
gh api repos/lohanidamodar/karmashala/releases/tags/v1.34.27 > release.json
dart tool/release_sums.dart --release release.json --out build/sums
dart tool/package_manifests.dart --version 1.34.27 --sums build/sums/SHA256SUMS.txt
```

| Folder | Goes to | Holds |
| --- | --- | --- |
| `homebrew/` | the root of `lohanidamodar/homebrew-tap` | `Casks/karmashala.rb` (the app, from the DMG) and `Formula/karmashala-host.rb` (the server, macOS and Linux, arm64 and x64) |
| `scoop/` | the root of `lohanidamodar/scoop-bucket` | `karmashala.json` (the portable zip) and `karmashala-host.json` (the server) |
| `winget/` | a pull request to `microsoft/winget-pkgs` | `PopupBits.Karmashala`, for the Inno installer |

Every manifest follows GitHub releases. The cask and the formula have
`livecheck` with `strategy :github_latest`. The Scoop manifests have
`checkver` and an `autoupdate` that reads hashes from the release's
`SHA256SUMS.txt`. On every release, `release-build.yml` regenerates the
Homebrew and Scoop files and commits them to the tap and the bucket
(`bump-package-managers`). Once enabled, `bump-winget` opens the winget pull
request with `wingetcreate`.

Validated on 2026-11-22: `winget validate` passed the manifest set, both Scoop
files parse as JSON, and `ruby -c` passed the cask and the formula. Not run:
`brew audit`/`brew install` (no Homebrew here) and a Scoop install.

## Turning it on

Nothing here is published yet. In order:

1. **Create `lohanidamodar/homebrew-tap`** (public). Copy `homebrew/Casks` and
   `homebrew/Formula` to its root.
2. **Create `lohanidamodar/scoop-bucket`** (public). Copy `scoop/*.json` to
   its root.
3. **Add the secret `PACKAGING_REPOS_TOKEN`** to `lohanidamodar/karmashala`: a
   fine-grained token with *Contents: read and write* on those two
   repositories only. Without it, `bump-package-managers` warns and does
   nothing. If the repositories get other names, set the repository variables
   `HOMEBREW_TAP_REPO` and `SCOOP_BUCKET_REPO`.
4. **winget, first version by hand.** Fork `microsoft/winget-pkgs`, copy
   `winget/manifests/p/PopupBits/Karmashala/<version>/` to the same path, and
   open the pull request (`wingetcreate submit <folder>` does this). Its
   validation pipeline also runs the installer in a sandbox.
5. **winget, after that one is merged.** Add the secret `WINGET_TOKEN` (a
   classic token with `public_repo`, which `wingetcreate` uses to fork and
   open the pull request), and set the repository variable
   `WINGET_SUBMIT=true`. `bump-winget` then opens a pull request on every
   release.

The winget identifier `PopupBits.Karmashala` and the publisher `PopupBits`
are a choice, not something the installer dictates. The Inno script calls its
publisher `Karmashala`. Change `_wingetId` in the script before the first pull
request if you want something else; after that it is fixed.

Until the Developer ID signing in `release-build.yml` is turned on, the cask
installs an app that is not notarised (it says so in its caveats). Homebrew
has been deprecating unsigned casks in its main repository, but a cask in
your own tap is unaffected.

## One-line installs

For the README and the PopupBits `/developers` page, once steps 1–4 are done:

```sh
# macOS — the app
brew install --cask lohanidamodar/tap/karmashala

# macOS or Linux — the server on its own
brew install lohanidamodar/tap/karmashala-host
```

```powershell
# Windows — the installer, through winget
winget install PopupBits.Karmashala

# Windows — the portable build, through Scoop
scoop bucket add karmashala https://github.com/lohanidamodar/scoop-bucket
scoop install karmashala/karmashala
```

Linux has the AppImage and the tarball on every
[release](https://github.com/lohanidamodar/karmashala/releases/latest). The
AppImage carries its update information for AppImageUpdate and Gear Lever.
