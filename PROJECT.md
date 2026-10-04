# Karmashala - Agent development environment

## 1. Project Context

This is a Flutter project.

Project summary:

```txt
Agent development environment that works with multiple agent cli, claude code, codex, antigravity. Easily manage sessions across projects, integrate with existing codebases, and provide a unified interface for agent interactions.
```

Primary targets:
- Windows / macOS / Linux
- mobile app will be a remote companion

Primary goals:

- Keep the app clean, maintainable, and production-ready.
- Prefer practical solutions over over-engineering.
- Keep changes small, reviewable, and aligned with the existing structure.
- Make responsive behavior part of each UI change, not a final polish step.
- keep comments concise and relevant and only when necessary
- keep comments focused on why something is done, not what is done

Out of scope unless explicitly requested:

- Large unrelated refactors
- New architecture rewrites
- New packages that duplicate existing project capabilities
- Publishing, deploying, signing, or uploading builds
- Modifying secrets, signing files, API keys, credentials, or production configs
- writing long verbose comments that are not necessary
- Avoid adding comments that state the obvious or repeat the code.

---

## 2. Agent Workflow

Before making changes:

- Understand the request and inspect the relevant files.
- Follow the existing project structure and style.
- Explain a short plan for larger or risky changes.
- Ask for clarification only when the task is ambiguous and a reasonable
  assumption would be risky.
- Prefer small, focused edits over broad rewrites.
- Do not rewrite unrelated code.
- Do not add packages unless they are clearly useful and consistent with the
  project direction.

While making changes:

- Preserve user changes already present in the working tree.
- Commit each finished, verified task (see "Karmashala overrides" in
  AGENTS.md), committing only the paths you changed. Keep pushing, publishing,
  deployments, and release builds manual unless the user explicitly asks.
- Use package and framework APIs instead of ad hoc implementations when the
  project already has a standard way to solve the problem.
- Keep generated or mechanical changes separate from logic changes when possible.
- DO not write too long and too verbose comments

After making changes:

- Explain what changed.
- Mention important files modified.
- Mention assumptions, incomplete work, or verification that could not be run.
- Suggest the next useful step when it naturally follows from the work.

---

## 3. Tech Stack

Update this table for the current project.

| Concern | Choice |
| --- | --- |
| Flutter SDK | `<stable version or project constraint>` |
| Dart SDK | `<version or project constraint>` |
| State management | `<provider / riverpod / bloc / cubit / inherited widgets / other>` |
| Routing | `<go_router>` |
| Persistence | `<shared_preferences / hive / drift / sqlite / secure storage / other>` |
| Networking | `<http>` |
| Localization | `<flutter gen-l10n / intl />` |
| Testing | `flutter_test`, plus project-specific tools |
| Lints | `flutter_lints` or project-specific analyzer rules |
| Code generation | `<none>` |

Dependency rules:

- Prefer the packages already used by the project.
- Add dependencies with `flutter pub add <package>` when possible instead of
  editing dependency constraints by hand.
- Do not add a dependency for trivial helper logic.
- If the project avoids code generation, do not introduce `build_runner`,
  `freezed`, `json_serializable`, generated Riverpod providers, or generated
  adapters without explicit approval.
- If the project uses code generation already, update generated files using the
  established command and include them in verification.

---

## 4. Architecture Principles

Prefer a simple feature-first structure unless the existing project uses a
different pattern.

Recommended structure for medium and large apps:

```txt
lib/
├── app/
│   ├── app.dart
│   ├── router.dart
│   └── theme.dart
├── core/
│   ├── constants/
│   ├── layout/
│   ├── utils/
│   └── widgets/
├── features/
│   └── feature_name/
│       ├── data/
│       ├── domain/
│       ├── presentation/
│       └── widgets/
└── main.dart
```

For small apps, keep the structure simpler if that improves maintainability.

General architecture rules:

- Separate UI, state, domain logic, and data access.
- Keep business logic out of `build()` methods.
- Use repository or service classes for API, database, storage, and platform
  integration logic.
- Keep models typed and explicit.
- Prefer immutable state objects where practical.
- Use `setState` only for ephemeral widget-local UI state such as expansion,
  focus, animation, or temporary input state.
- Put shared widgets in a common location only when they are genuinely reused.
- Keep files focused. Large widget files should be split when it improves
  readability.
- Prefer package imports for files under `lib/` when that is the project norm.
- Avoid `dynamic` and untyped public APIs.
- Use `const` constructors wherever they compile cleanly.

---

## 5. UI Guidelines

Build UI that is:

- Clean
- Responsive
- Accessible
- Consistent with the existing design system
- Easy to scan and use
- Appropriate for the product domain

Use the project theme:

- Prefer `ThemeData`, `ColorScheme`, `TextTheme`, and shared design tokens.
- Do not scatter hardcoded colors, text styles, spacing, or custom theme logic
  through feature widgets.
- Use reusable design constants or theme extensions when repeated values are
  meaningful.

For forms and user flows:

- Validate user input.
- Show loading states for async work.
- Show empty states when there is no data.
- Show error states when work fails.
- Avoid hidden behavior and confusing navigation.
- Keep destructive actions explicit and reversible where practical.

Accessibility:

- Use semantic labels for icon-only controls.
- Keep tap targets large enough for touch.
- Preserve keyboard navigation where relevant.
- Do not rely on color alone to communicate state.
- Make text scalable and avoid layouts that break at larger font sizes.

---

## 6. Responsive Layout Contract

One codebase should adapt across supported screen sizes.

Recommended form factors:

```dart
enum FormFactor { compact, medium, expanded }

// Suggested Material-style width classes:
// compact  < 600
// medium   600-839
// expanded >= 840
```

Rules:

- Branch on available width for layout, not on operating system.
- Use platform checks only for platform capabilities, not for ordinary layout.
- Keep layout state outside layout-specific widgets so resizing or rotation does
  not reset important user data.
- For medium widths, default to the compact layout unless the screen clearly
  benefits from an expanded presentation.
- Centralize form-factor logic in one helper, extension, or layout utility.
- Avoid raw width checks scattered through feature widgets.

Navigation:

- Compact screens usually use bottom navigation or simple app bars.
- Expanded screens may use a navigation rail, sidebar, split view, or wider
  content layout.
- A screen should not render its own global navigation if the app shell already
  owns navigation.

Modals:

- Prefer bottom sheets on compact screens.
- Prefer dialogs or side panels on expanded screens.
- Centralize adaptive modal behavior in a shared helper when the pattern repeats.

Large screens:

- Do not stretch narrow list content edge-to-edge across desktop widths.
- Constrain readable content with a max width.
- Use additional space for useful context, preview panes, filters, or navigation
  when that genuinely improves the workflow.

Proof obligation:

- Any new or changed important screen should be checked at a phone-like size and
  a desktop/tablet-like size.
- Widget tests should cover both sizes when the layout has meaningful adaptive
  behavior.

---

## 7. State Management

Use the state management approach already established by the project.

If no approach exists yet:

- Prefer the simplest option that fits the app.
- For shared app state, Riverpod without code generation is a good default.
- For very small local state, `setState` is acceptable.

State rules:

- Keep shared state out of widgets.
- Keep async loading, error, and empty states explicit.
- Keep provider, bloc, cubit, notifier, or controller APIs small and named by
  user intent.
- Avoid exposing mutable collections directly.
- Test important business logic outside the widget tree when possible.

---

## 8. Data, Services, And Persistence

Keep data access separate from UI.

Prefer:

- Repository or service classes for data logic.
- Models for structured data.
- Explicit error handling.
- Clear boundaries between local cache, remote API, and UI state.
- Easy-to-test pure functions for business rules.

Avoid:

- Calling APIs, databases, storage, or platform channels directly from widgets
  unless the app is intentionally tiny.
- Silent error handling.
- Hardcoded endpoints or credentials.
- Mixing serialization, validation, networking, and presentation in one class.

Persistence rules:

- Keep schema changes deliberate.
- Add migrations when persistent models change.
- Do not delete or rename stored fields without considering existing users.
- Keep secure values in secure storage, never in plain preferences or source
  files.

---

## 9. Assets

When adding assets:

- Put files in the correct asset folder.
- Update `pubspec.yaml`.
- Use clear, consistent file names.
- Avoid large unnecessary files.
- Keep icons, images, fonts, audio, and animation files organized.
- Prefer a central asset path file or generated asset access if the project has
  one.
- Do not hardcode the same asset path in many widgets.

Recommended folders:

```txt
assets/
├── audio/
├── fonts/
├── icons/
├── images/
└── animations/
```

---

## 10. Localization

If localization is already enabled:

- Use the existing localization system.
- Do not hardcode new user-facing strings outside the localization flow.

If localization is not enabled:

- Keep user-facing strings easy to find.
- Avoid scattering repeated strings across many files.
- For production apps, structure text so localization can be added later without
  a major rewrite.

---

## 11. Testing Strategy

**Where things are.** The repository root is a pub workspace with no code of
its own: `app/` is the Flutter client, `server/` the Karmashala server (package
`karmashala_host`), `relay/` the relay with its contract in `relay/protocol/`,
and `packages/` everything shared. Run `flutter pub get` at the root; run the
app's `flutter` commands (`run`, `test`, `build`) from `app/`. A path in this
guide that starts `lib/`, `test/`, `integration_test/`, `assets/`
or a platform folder is the app's, under `app/`.

Add tests in proportion to risk and user impact.

**One `flutter test` at a time in a checkout.** Concurrent runs fight over
`build/native_assets/windows/sqlite3.dll` and die in ways that read as test
failures — a load error, or a suite that fails for no reason the diff explains.
Several sessions share this checkout, so when more than one may be running,
take an advisory lock rather than trusting timing:

```sh
LOCK="<a path both sessions can see>/flutter-test.lock"
while ! (set -o noclobber; echo $$ > "$LOCK") 2>/dev/null; do sleep 10; done
trap 'rm -f "$LOCK"' EXIT
```

Release it as soon as the run finishes, and only if it is yours. A pure-Dart
package (`dart test` in `packages/agent_cli`) does not need the lock.

**A gate run on a shared checkout is a gate over everybody's work.** When
another session has uncommitted changes, a failure may not be yours and a pass
does not prove your change is green in isolation. Say which it was. Do not
stash or revert somebody else's work to find out.

Prefer:

- Unit tests for business logic, formatters, validators, services, and pure
  functions.
- Widget tests for important UI behavior, navigation decisions, forms, empty
  states, error states, and adaptive layout.
- Repository or service tests for data handling.
- Golden tests only when the project is set up for them and the UI is stable.

Recommended responsive test sizes:

| Name | Logical size | Simulates |
| --- | --- | --- |
| `phone` | `390 x 844` | compact mobile layout |
| `desktop` | `1440 x 900` | expanded desktop/tablet layout |

Before considering a task complete, try to run, from `app/`:

```bash
flutter analyze
flutter test --exclude-tags=live-ssh,live-wsl --dart-define-from-file=dart_defines.json
```

**Name every directory when you analyze by path**, or one of them rots
unwatched. From the repository root:

```bash
dart.exe analyze --no-fatal-warnings app server packages
```

`app` covers its `lib`, `test`, `integration_test` and `tool`. `relay/` and
`relay/protocol/` resolve on their own lock files: `dart pub get && dart
analyze && dart test` inside each.

`integration_test/` is in no gate — `flutter test` does not run it — so nothing
but the analyzer ever compiles it. Three of its files carried 72 errors for a
day in September 2026 because every analyze command in flight listed
`lib test packages host` and left it out.

`packages/` covers the standalone `mcp_bridge` too — it is not a workspace
member (it resolves on its own lock file so `dart compile exe` can reach it),
but it lives under `packages/` like everything else, so naming the one
directory analyzes it. `relay` sits beside `server` at the root and is named on
its own. **`host` (now `server/`) joined
the workspace on 2026-09-15**: it carries the app's store, `sqlite3` has a build
hook, and `dart compile exe` refuses any target with one — so the exemption
bought it nothing and it is built with `dart build cli` instead (§22). `mcp_bridge`
sat outside it until 2026-09-15 and was therefore in no analyze command at all:
the bridge every WSL session gets its tools through was compiled by the release
recipe and analyzed by nothing. Membership is declared in a package's own
pubspec, never by where it sits.

For UI changes, also run the app where practical:

```bash
flutter run -d chrome
```

Use another target when it is more relevant:

```bash
flutter run -d windows
flutter run -d macos
flutter run -d linux
flutter run -d <device_id>
```

If verification cannot be run, explain why.

---

## 12. Commands Cheatsheet

Common commands, `pub get` at the repository root and the rest from `app/`:

```bash
flutter pub get
flutter pub add <package>
flutter analyze
flutter test --exclude-tags=live-ssh,live-wsl --dart-define-from-file=dart_defines.json
flutter run -d chrome
flutter devices
flutter clean
```

Code generation, only if the project uses it:

```bash
dart run build_runner build --delete-conflicting-outputs
```

Driving the running app — the widget tree, taps, typing and screenshots of a
debug build over the VM service. **A probe instance (§23)**, never the one you
are working in:

```powershell
$env:KARMASHALA_PROBE = "1"
$env:KARMASHALA_DATA_DIR = "$env:TEMP\ks-marionette-data"
flutter run -d windows --debug          # prints the VM service URI
& "$env:LOCALAPPDATA\Pub\Cache\bin\marionette.bat" --uri <ws://…/ws> get-interactive-elements
```

Release commands should be run only when explicitly requested:

```bash
flutter build apk --release
flutter build appbundle --release
flutter build ios --release
flutter build web --release
```

---

## 13. Android Release Readiness

When preparing an Android release, check:

- App name
- Package name / application ID
- Version name and version code
- App icon
- Required permissions
- Signing configuration
- Release build command
- Privacy policy requirements
- Play Store listing text
- Screenshots
- Internal testing readiness

Never expose, print, rewrite, or commit private signing credentials unless the
user explicitly requests a credential-related change and understands the risk.

**How Karmashala ships to Play.** `.github/workflows/android-release.yml`, run
by hand (`workflow_dispatch`, track `internal` / `beta` / `production`). It
writes `app/android/key.properties` and the upload keystore, builds the AAB with
`--dart-define=KARMASHALA_VERSION=<pubspec version>`, and runs the fastlane lane
in `app/android` with `SKIP_FLUTTER_BUILD=1` so fastlane only uploads.

Signing: `app/android/app/build.gradle.kts` signs release with
`key.properties` when it exists and falls back to the debug key when it does
not, so local release builds keep working. A debug-signed AAB is refused by
the play_publisher plugin before upload.

Repository secrets, set per repository (org secrets do not reach private
repositories on the free plan): `PLAY_STORE_JSON_KEY_DATA` (shared across
PopupBits apps), `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. The package name,
`com.popupbits.karmashala`, is set in the workflow, not a secret.

---

## 14. Code Review Checklist

Before finishing, check:

- [ ] The change is scoped to the task.
- [ ] The code follows the existing project style.
- [ ] The app compiles, or any compile blocker is explained.
- [ ] `flutter analyze` passes, or failures are explained.
- [ ] Relevant tests pass, or unrun tests are explained.
- [ ] Important new logic has tests.
- [ ] Important changed UI works at compact and expanded sizes.
- [ ] Errors, loading states, and empty states are handled.
- [ ] Names are clear and types are explicit.
- [ ] Unused imports and dead code are removed.
- [ ] No secrets, credentials, signing files, or production configs were changed
      accidentally.
- [ ] No unrelated refactors were included.
- [ ] Dependencies were not added unnecessarily.

---

## 15. Multi-Agent Workflow


Recommended roles:

| Role | Responsibility |
| --- | --- |
| Orchestrator | Owns the task, keeps scope clear, decides the next step, and integrates results. |
| Explorer | Reads the codebase and reports what exists. Does not edit files. |
| Planner | Designs the implementation approach. Does not edit files. |
| Implementer | Makes the planned changes and runs verification. |
| Reviewer | Reviews the diff for bugs, regressions, conventions, and missing tests. |
| Tester | Adds or improves focused tests and runs them. |
| Doc Keeper | Updates project docs when behavior, setup, or architecture changes. |

Standard lifecycle for large changes:

```txt
Explorer -> Planner -> Implementer -> Reviewer -> Tester -> Doc Keeper
```

Parallelism rules:

- Parallelize independent read-only exploration.
- Parallelize implementation only when file sets are disjoint and there are no
  dependency ordering issues.
- Do not run reviewer and implementer in parallel.
- Do not run two implementers on the same file.
- When in doubt, serialize the work.

Agent prompt rules:

- Make each subagent prompt self-contained.
- Include relevant files, constraints, acceptance criteria, and verification
  commands.
- Tell read-only agents not to edit files.
- Tell implementers exactly which files or areas they may touch when the scope
  must stay tight.
- Require `flutter analyze` and relevant tests before implementation is reported
  complete.

---

## 16. Autonomous and loops

Work autonomously and in loops to implement, review, test, fix, and verify until the task is complete.

---

## 17. Project specific note

### Windows tooling is mandatory — and bare `flutter` in WSL is a trap

Never invoke `flutter` or `dart` from a WSL/Linux shell, even though the repo
lives under `/mnt/c` and the command appears to work.

`which flutter` inside WSL resolves to `/mnt/c/Users/<you>/flutter/bin/flutter`
— the **POSIX shell script** that ships inside the *Windows* Flutter install,
reachable because `/mnt/c` is on `PATH`. Running it makes Flutter decide it
needs a **Linux** Dart SDK: it downloads `dart-sdk-linux-x64.zip` into
`flutter/bin/cache/` and swaps out the Windows `dart-sdk`, corrupting the one
installation every terminal, agent and build shares. The symptom everybody
else then sees is:

```
Flutter users should use `flutter pub` instead of `dart pub`.
Failed to update packages.
```

Always go through `cmd.exe`, and always name `flutter.bat` rather than
`flutter`:

```bash
cmd.exe /c "cd /d C:\path\to\repo && C:\Users\<you>\flutter\bin\flutter.bat pub get"

cmd.exe /c "cd /d C:\path\to\repo && \
  C:\Users\<you>\flutter\bin\cache\dart-sdk\bin\dart.exe --disable-dart-dev \
  --packages=C:\Users\<you>\flutter\packages\flutter_tools\.dart_tool\package_config.json \
  C:\Users\<you>\flutter\bin\cache\flutter_tools.snapshot <analyze|test ...>"
```

Subagent briefs must spell this out. "Use Windows tooling" is not enough: bare
`flutter` resolves and fails silently for the agent that runs it, while
breaking the toolchain for everyone else.

- run and test on windows as primary target
- https://github.com/Norbert515/vide_cli this project implemented in dart might already have some reference for us regarding how to work with agents and cli, orchestrate multiple agents, manage subagents and handle agent sessions. We can use it as a reference for our project.

---

## 18. Live tests — opt-in, and meant to be run

The default gate excludes two tags:

```bash
flutter test --exclude-tags=live-ssh,live-wsl --dart-define-from-file=dart_defines.json
```

The define is not optional: the remote-access, relay and pairing suites read
`KARMASHALA_RELAY_URL` from `app/dart_defines.json`, and without it fifteen of
them fail on a default relay that is empty. CI passes the same define.

`dart_test.yaml` supplies the measured eight-worker default. Keep the command
free of a `--concurrency` override so local runs and automation use the same
setting.

That exclusion is correct and must stay. The tests behind those tags bind real
sockets, drive a real WSL distribution and dial a real SSH server; making the
ordinary suite depend on any of that would be a worse bug than the ones they
catch.

But an excluded test is only a comment until somebody runs it, and these exist
for the failures **no stand-in can see** — above all whether the files this app
writes across `\\wsl.localhost` are the files a distribution's own `sh` reads
back, and whether an endpoint a Windows process binds is reachable *for data*
from inside a WSL network namespace. Those links are what silently degrade
agent status and agent tooling when they break, and nothing but a real
distribution can measure them.

### Running them

```powershell
powershell -ExecutionPolicy Bypass -File tool\live_tests.ps1
powershell -ExecutionPolicy Bypass -File tool\live_tests.ps1 -Family wsl
powershell -ExecutionPolicy Bypass -File tool\live_tests.ps1 -Family ssh
```

**Both halves of that line are load-bearing on the owner's machine**, and each
was learned by the documented command failing on 2026-09-04:

* **`powershell`, not `pwsh`.** `pwsh` is PowerShell 7 and is not installed
  here — the instruction answered `CommandNotFoundException` for the one person
  it was written for. The script declares no `#requires` and uses no 7-only
  syntax, so Windows PowerShell 5.1 runs it as it stands.
* **`-ExecutionPolicy Bypass -File`.** The machine's policy is `Restricted`, so
  `.\tool\live_tests.ps1` answers `PSSecurityException: running scripts is
  disabled on this system`. The flag applies to that child process only and
  changes no system state, which is why it is the documented form rather than
  advice to run `Set-ExecutionPolicy`.

From Windows, never from a WSL shell — §17 applies to this script like anything
else. It prints what it found **before** running anything, so a green run whose
prerequisites were absent cannot be mistaken for a run that proved something,
and it uses the expanded reporter so a self-skip prints its reason rather than a
bare `~1`.

Worth doing after any change to the hook endpoint, the WSL launch path, the
terminal's process shutdown, or the SSH transport — and worth a scheduled task
on a machine where WSL status matters, because the switch address is reset by
things outside this app.

| Tag | Files | Needs | Skips itself when |
| --- | --- | --- | --- |
| `live-wsl` | `test/features/agents/live_wsl_hook_test.dart`, `test/features/projects/live_wsl_path_existence_test.dart`; the pane suites moved to the server in slice 5a — `server/test/live/wsl_terminals_live_test.dart`, `wsl_hook_spool_live_test.dart` (run from `server/` with `dart test --tags=live-wsl <file>`, one file at a time) | Windows + a WSL distro (`archlinux` for the server's); `curl` in it for the `/mcp` measurement | there is no WSL |
| `live-ssh` | Since slice 5d the app dials no SSH: the box suite is `server/test/live/ssh_box_live_test.dart` (tag `live`: deploy, a terminal on the box, the relay), the server's pool `server/test/live/ssh_live_test.dart` (tag `live`), and the transport half `packages/karmashala_ssh/test/live_ssh_test.dart` | `KARMASHALA_SSH_HOST`, `KARMASHALA_SSH_USER`, `KARMASHALA_SSH_KEY` (and `KARMASHALA_SSH_PORT` if not 22); the session-host deploy case, the install-panel cases (they read, install, and Stop/Start only a host that holds no sessions — nothing uninstalls) and the relay-on-a-box case also need `KARMASHALA_HOST_BINARIES`, the directory holding `karmashala_host-<version>-linux-*` (the relay case wants a bundle new enough to carry `relay`, and says so when it is not; it uses port 18787 and removes what it made) | those variables are unset |

A WSL distribution running `sshd` on a spare port is a good SSH target. The
recipe, run 2026-09-16 and green on all 21 cases:

```bash
# In WSL. sshd runs as the ordinary user, so it can only ever let that user in.
mkdir -p ~/live-ssh-test && cd ~/live-ssh-test
ssh-keygen -t ed25519 -f hostkey -N '' -q
ssh-keygen -t ed25519 -f /mnt/c/kw/live-ssh/id_ed25519 -N '' -q   # the client key
cp /mnt/c/kw/live-ssh/id_ed25519.pub authorized_keys
chmod 700 ~/live-ssh-test && chmod 600 hostkey authorized_keys
/usr/sbin/sshd -f ~/live-ssh-test/sshd_config -D -e &   # Port 2222, ListenAddress 127.0.0.1
```

**The server's key material must live on the WSL filesystem, not `/mnt/c`.**
DrvFs reports 0777 whatever `chmod` says, and `StrictModes` refuses it. The
*client* key is the exception: it belongs on a Windows path because the test
process is Windows, and `dartssh2` reads the file itself rather than judging its
mode — the OpenSSH client would refuse the same file.

**`WSLENV` is what makes the variables cross, and forgetting it reads as a
pass.** A Windows process launched from WSL does **not** inherit the Linux
environment, so without it the suite self-skipped and `dart test` still exited
**0** — the precise failure this section's "a green run whose prerequisites were
absent" warning is about. Name every variable:

```bash
WSLENV=KARMASHALA_SSH_HOST:KARMASHALA_SSH_PORT:KARMASHALA_SSH_USER:KARMASHALA_SSH_KEY:KARMASHALA_HOST_BINARIES \
KARMASHALA_SSH_HOST=127.0.0.1 KARMASHALA_SSH_PORT=2222 KARMASHALA_SSH_USER=<you> \
KARMASHALA_SSH_KEY='C:\kw\live-ssh\id_ed25519' \
KARMASHALA_HOST_BINARIES='C:\kw\live-ssh\binaries' \
  <dart.exe> … test test/live/ssh_box_live_test.dart   # from server/
```

No path-translation flags: the two path values are already spelled for Windows.
**Read the reporter's last line, never the exit code** — `All tests skipped` and
`All tests passed` both exit 0.

`KARMASHALA_HOST_BINARIES` wants a directory holding
`karmashala_host-<version>-linux-<arch>.tar.gz` (§22). One built on Windows
deploys and serves panes but answers `probe-store` with `STORE MISLINKED`, so it
is fine for exercising the deploy and useless for a store.

`live_wsl_detach_test.dart` answers a question no *unit* test can: whether
closing an **empty** WSL shell ends it. `shouldDetachOnClose` has to guess
whether a shell holds history worth keeping, and it guesses by counting
non-blank lines — so the answer turns on how many rows a real prompt paints per
command, which is a property of the user's shell and of nothing in this
repository. WSL is where it matters most, because shell integration is off by
default, so for most WSL panes the line count is the only rule they ever get.

**Measured 2026-09-03 against `archlinux`,** whose zsh runs starship at three
rows per command — a blank separator, a directory line and a prompt line:

```txt
idle, untouched          nonBlank=2     released
after 1 silent command   nonBlank=5     released
after 2 silent commands  nonBlank=8     PARKED   <- the reported bug
after `pwd`              nonBlank=12    parked
after `ls`               nonBlank=106   parked
```

That was the owner's *"empty wsl terminal stays in the background instead of
just ending"*: two commands that printed nothing crossed a threshold derived
from single-line prompts. A pane now records the greeting its shell painted
before anything was run, and the threshold is counted on top of it. The test
asserts **relationships** rather than those numbers, so a one-line prompt on
another machine proves the same rule. Worth running after any change to the
detach policy, the WSL launch path, or what a pane does with user input.

`live_wsl_prompt_test.dart` answers what happens to a **prompt** on the way into
a WSL agent pane, and it exists because of a launch that died on 2026-09-03 as

```txt
zsh:1: unmatched "
```

`wsl.exe … -- <command>` is not an argv hand-off: WSL takes the command line
*tail* and runs it through the distribution's login shell (`-- echo '$0'` answers
`/usr/sbin/zsh`), so the line is parsed **twice** and Windows quoting satisfies
only the first parser. Measured against `archlinux` before the fix: a multi-line
prompt was truncated by `cmd` at its first newline and left the opening quote
dangling — the reported failure, and the fate of *every* multi-line prompt;
`` `id -u` `` and `$(id -u)` in a prompt were **executed**, and `$(touch …)`
really created the file; `$HOME` was expanded and `\\server` became `\server`.

A prompt is written by agents and pasted by users. It is not trusted text, and
the fix is the POSIX counterpart of what the Windows-native path already does
with `-EncodedCommand`: `encodedPosixShellCommand` base64s the whole
`quotePosixShellArgument`-quoted command, so nothing user-supplied is on the
command line for either parser to act on. The test asserts the bytes the process
received — written to a file inside the distro, not read off the pane, because a
ConPTY re-flows what it paints and a newline is exactly what has to survive.
`pty_command_line_test.dart` pins the same list on every gate.

`live_pane_resize_test.dart` answers one question nothing above the PTY can:
**does the process in a pane learn the size the app resized it to?** Everything
higher up is pinned by `test/features/terminal/window_resize_test.dart`, which
proves the grid a pane is *told* is the grid it is *drawn* in at every window
size; what it cannot see is whether a resize written into a Windows ConPTY
becomes a `TIOCSWINSZ` on the far end — and for a WSL pane the far end is two
relays away, through `cmd.exe /c wsl.exe -d <distro>`. So it asks the process:
`[Console]::WindowWidth` in PowerShell, `stty size` in the distro.

**Measured 2026-09-03, all three cases pass.** A native pane and a WSL pane both
follow every resize, and so does a burst of 60 at a drag's cadence — the last
one is the one the process ends up on, so nothing here debounces badly or lands
a size behind. That is the evidence that ruled the PTY out of the "resizing
doesn't work as expected" report.

Since 2026-09-17 a pane's **columns** settle (`PaneTerminal`,
`pane_terminal.dart`): a change after a quiet spell lands at once, and the ones
that follow within `kColumnResizeSettle` wait for the width to hold still. The
buffer and the process are still told together and the last size still wins,
but a drag is two reflows and two SIGWINCHes rather than one per column. So the
burst of 60 now reaches the process as two sizes, the last up to 100 ms late —
and this test has not been re-run on Windows since.

`live_wsl_osc133_test.dart` answers whether a **WSL pane reports its own
command boundaries**, which is what `terminal_run` needs to name an exit code.
It is the test Loop 32 could not write: the bash rcfile was verified against
real bash then parked, partly because through a *pipe* the marker order came
out wrong — a spurious `D;0`, a doubled `C` — and telling a relay artifact from
a real ordering bug needs a ConPTY, not a pipe.

**Measured 2026-09-09 against `archlinux`** (bash 5.3.15, zsh 5.9.2, starship),
through the launch this app builds and with the login shell forced for the half
the machine does not have:

```txt
bash  true / false / sh -c 'exit 7'   ->  A B C D;0  A B C D;1  A B C D;7
zsh   the same three                  ->  the same stream
empty Enter                           ->  A B D with no C; the block is dropped
terminal_run echo karmashala-ok       ->  finished, exit 0, its own output
terminal_run sh -c 'exit 5'           ->  finished, exit 5, exitCodeKnown true
```

The delivery is what makes it safe, and it is the whole reason the item could be
unparked. `bash --rcfile` pointed at a file it cannot read starts a shell with
**no user configuration at all** — worse than no feature — so Loop 32 wanted a
probe on the launch path confirming both the login shell and the file. Instead
the payload the launch already carries (`cmd.exe /c wsl.exe -d <distro> -- eval
$(…|base64 -d)`, unchanged in shape) *writes* the rc file inside the
distribution and then reads it, into a fresh `mktemp -d` each script deletes as
its last statement; every path that does not end in a working rc file ends in
`exec "$shell" -l`, the pane this app always opened. **`cmd.exe` is still
excluded, and that is measured too:** `prompt $E]133;A$E\` really does put the
sequence on the wire, but `cmd` has no hook between reading a command and
running it, and `%ERRORLEVEL%` in `PROMPT` is substituted once when the prompt
is *set* and then frozen — so `C` and a live `D;<code>` are both out of reach
and a `cmd` pane's exit code is genuinely unknown.

`live_wsl_input_boundary_test.dart` answers the input-side counterpart: **does
an escape sequence this app writes reach the process in the pane in one piece?**
Every navigation key is `ESC` plus a tail, and the byte parser Codex and every
other crossterm program uses on Linux resolves an `ESC` the moment a `read()`
ends on it — it emits a lone `Esc` and reads the tail as *text*. So one badly
placed read boundary turns End into a literal `[F` in the composer, which is
what the owner reported on 2026-09-08, and nothing above the PTY can see it.

**Measured 2026-09-09 against `archlinux`, and the launch form is the whole
story.** Through the launch this app builds — `cmd.exe /c wsl.exe -d <distro>`
— every sequence arrives whole: 40/40 for a single End, 0 fatal boundaries in
200 back-to-back presses, and 40/40 into a pane repainting at 125 Hz. Through
the launch it *used* to build — `wsl.exe` spawned directly, whose duplicated
leading token makes the distro's login shell exec a Windows `wsl.exe` back out
through interop — the same 40 presses arrive whole only 12 times, split
`ESC[`+`F` 20 times (harmless, the parser waits) and `ESC`+`[F` 8 times, which
is the reported bug. Confirmed against real Codex in both shapes the same day:
this app's launch put the caret where Home belongs; the nested one typed
`hello[HX`. The nested case is measured here too and **reports rather than
asserts** — WSL's own relay is not this app's to fail on.

**It is the wrapper, not the `--`.** Crossed both ways over the same 40
presses: `cmd.exe /c wsl.exe … -e python3 …`, an argv hand-off with no `--` at
all, is whole 40/40, and `wsl.exe` spawned directly *with* the app's `--`
payload splits 22 times of 40, five of them after the bare `ESC`. So the
`cmd.exe /c` of `throughCommandPrompt` is doing the work — it is what keeps the
distro's login shell from exec'ing a second `wsl.exe` back out through interop
— and the `--` hand-off `encodedPosixShellCommand` needs costs nothing here.

**There was nothing to tune on the writing side, and that was measured too.**
`flutter_pty` creates the pseudoconsole with `dwFlags` 0 and sets no console
mode at all (`packages/flutter_pty/src/flutter_pty_win.c`), and one `pty.write`
is one `WriteFile` followed by `FlushFileBuffers` — so the app already hands
each key to ConPTY as a single indivisible write, and
`ENABLE_VIRTUAL_TERMINAL_INPUT` is the *client's* flag to set, which `wsl.exe`
does for itself. The only variable that moved the boundaries was the launch
form. The exploratory harness is not
kept: the one property worth pinning is the one the test above asserts.

### A failure is not automatically a bug

`live_wsl_hook_test.dart` deliberately does **not** skip itself when a hook
fails to arrive — that is the failure it exists to catch. Its messages classify
themselves, and the two need opposite responses:

- **`THIS MACHINE, not the app`** — the installer could not write and read back
  its three files across `\\wsl.localhost`. The share is unreachable, or the
  distro home is not writable. Nothing in this repository will fix it.
- **`THE APP`** — the distro's shell could not run the command the installer
  wrote, or the payload crossed the share and the drain read none of it. That is
  a bug here, and the verdict names which of the two it is.

**As of 2026-09-03 all four cases pass on the owner's machine.** They did not
before. The hook used to post to the host side of the WSL virtual switch, and
that address here completes the TCP handshake and then resets the first data
segment. So the hook transport left the network: a WSL agent writes its payload
into a spool directory in its own store home and the app drains it over the
share.

**The switch is still shut, and the fourth case still says so.** It *reports*
rather than asserts, because a shut switch is the machine's and failing on it
would blame the app. Since Loop 72 that report is about `/mcp` only, and even
there it is no longer fatal: a WSL session is pointed at the stdio bridge over
WSL interop instead, and falls back to the switch URL only when
`karmashala_mcp.exe` is not beside the app.

The discriminator, which takes half a minute and needs no Karmashala at all:

```powershell
$l = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse('172.18.240.1'), 47999)
$l.Start(); $c = $l.AcceptTcpClient()
$c.GetStream().Write([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`n`r`nhi"), 0, 22)
```

```bash
curl -sS -m 5 http://172.18.240.1:47999/    # from inside the distro
```

Measured on 2026-09-03: the bare listener is reset the same way — curl reports
`(56) Recv failure: Connection reset by peer` and PowerShell reports *"An
existing connection was forcibly closed by the remote host"*. No Dart is
involved.

### What actually crosses, measured

Re-measured 2026-09-03 from inside the owner's `archlinux` distribution against
the running app, and worth knowing before designing anything else that has to
cross. **The breakage is directional**: Windows → WSL is fine, WSL → Windows
over the switch is not, and WSL interop is not a network path at all.

| direction | mechanism | result |
| --- | --- | --- |
| WSL → Windows | `curl` at the switch address | **reset** (curl 52 / 56) |
| WSL → Windows | a *Windows* program over WSL interop, at Windows' own loopback | works, ~72 ms per process spawn |
| WSL → Windows | the compiled `karmashala_mcp.exe` over interop, on the owner-only socket | works — 75 tools, ~42 ms per call |
| WSL → Windows | write a file the app reads over `\\wsl.localhost` | works, **<1 ms** |
| Windows → WSL | a listener inside the distro on `127.0.0.1`, via `localhostForwarding` | works, 30/30 across three fresh ports |
| Windows → WSL | `\\wsl.localhost` listing | works, 0.79 ms warm |
| either | `Directory.watch` on `\\wsl.localhost` | subscribes, **never fires** |

That table is why the two consumers use two transports. Hooks fire twice per
tool call, so interop's ~72 ms would be ~144 ms of the user's turn per tool and
the spool's <1 ms wins outright. MCP is one long-lived process per session, so
interop's spawn cost is paid once and every call after it is a socket round
trip — and a poll would put latency on every tool call instead.

**None of it applies off Windows.** `EnvironmentKind.wsl` rows are only created
when the host is Windows (`EnvironmentDiscoveryService`), and both transports
are selected by `EnvironmentKind` rather than by a platform check, so a macOS or
Linux build never reaches a spool, a share or an interop spawn. The absence case
is pinned by tests rather than assumed — see "a machine with no WSL is untouched
by any of this" in `agent_hook_installation_service_test.dart`.
---

## 19. System health — measured, on demand, with its age

**Quick open → "Check system health"**, and the same reading appears in
Settings → Tools. It replaces a panel that read

```dart
available ? 'Tools available — the MCP bridge is installed.' : ...
```

where `available` was `File.existsSync`. On 2026-09-03 that sentence was on
screen for over an hour while every agent session on this machine had lost
every Karmashala tool — WSL's interop handler had disappeared, so nothing could
*spawn* the perfectly good file the panel had found. A confident false statement
costs more than an admission of ignorance; `build_identity.dart`,
`DeviceCapability` and `AgentStatusReport.evidence` were already written that
way, and this panel now is too.

### The rules it is built to

| Rule | How it is enforced |
| --- | --- |
| Never claim health that was not observed | `HealthLevel.unknown`, ordered above `healthy`, with its own icon and the neutral colour. Before a check runs the panel says nothing has been checked. |
| Show the age of a reading | `SystemHealthReport.checkedAt`, rendered with `describeAge` — the helper `AgentStatusReport.evidenceAt` exists for. |
| Probes cost processes; never on a timer | `SystemHealthController.refresh()` runs when the panel opens and when the user asks. Nothing polls. |
| Say what to do about it | `SystemCheck.remedy` and `remedyCommand`, offered to copy. |
| One reading, not two | Panel and Settings read one `systemHealthProvider`. `environmentHealthProvider` was deleted for this reason. |

### The MCP bridge is probed, not stat-ed

`McpBridgeProbe` spawns `karmashala_mcp` and completes a real `initialize`
handshake. Four verdicts, because they need four different responses:

| Verdict | Means | Level |
| --- | --- | --- |
| answering | spawned and finished the handshake | healthy |
| present but unspawnable | the file is there and the OS refused it — 2026-09-03, three times | failed |
| not found | nothing beside the app to spawn; WSL sessions then fall back to the switch address | warning |
| spawned but not answering | started, then no reply / not MCP / exited first | failed |

**Measured 2026-09-03 on the owner's machine: 121 ms median** (111-125 ms
warm, 875 ms for the first spawn of a freshly compiled executable), almost all
of it process start. The timeout is 5 s, and the panel shows each row's real
cost beside it so re-running is an informed choice.

`initialize` rather than `tools/list` on purpose. The bridge answers
`initialize` out of its own code, so the verdict is about the bridge alone;
whether the **app** will answer it is already reported, without spawning
anything, by `ControlServerStatus`, which knows *which* hardening step failed.
The two rows are the whole path and cannot contradict each other.

**The bridge row speaks for this host only.** The app spawns the bridge
natively; a session inside WSL spawns the same file over WSL interop, which is
a different mechanism and can be broken while this one is fine. That is what
the interop row is for, and the bridge row's remedy points at it rather than
absorbing its explanation.

### WSL interop is one row that explains a class of failures

Interop is a `binfmt_misc` registration inside the distribution handing every
`MZ` file to `/init`. When it goes, `posix_spawn` of any `.exe` fails with
`ENOEXEC` — the MCP bridge, `cmd.exe`, any Windows build tool, all at once.
Checked in plain `sh`; both `WSLInterop` and the newer `WSLInterop-late` count;
output with no completion marker reads as **unknown**, never as *missing*,
because a distribution that did not answer is our blind spot and not its fault.

The repair, which is what WSL itself does at start-up and does not survive a
`wsl --shutdown`:

```bash
sudo sh -c 'echo ":WSLInterop:M::MZ::/init:PF" > /proc/sys/fs/binfmt_misc/register'
```

This is the *machine*, not the app — the same distinction §18 draws for
`live_wsl_hook_test.dart`, and the panel words it that way. §18's measured
table of what crosses between Windows and WSL is still the reference for the
transports themselves; nothing here re-derives it.

### What is deliberately not checked, and why

- **A client's MCP connection.** Claude Code binds its servers when it starts
  and owns those processes. This app can speak for its own bridge and its own
  endpoint and nothing else. A row claiming otherwise would be the same lie in
  a new place.
- **Network reachability.** Nothing here needs the internet, and a probe of
  someone else's host reports their weather.
- **A second git/SSH opinion.** Already measured per environment by
  `EnvironmentHealthService`, in the same panel.
- **CPU and memory.** No incident has turned on either, and a number with no
  threshold trains the eye to skip the panel.

### And it does not notify

Health is looked *for*, not pushed. Notifying would need polling, which the
third rule above forbids for good reason. Worse, the event a user actually
cares about is their **session** losing its tools, and this app cannot see
that: the CLI owns its MCP servers. "Your session lost its tools" would be the
confident false statement this whole change deletes, moved somewhere louder.
The inbox is per-session by construction as well — `PendingNotification` and
`InboxItem` both require a `WatchedSession` — so a machine fault has no session
to file under. Revisit only with something the app *observes* while doing real
work, never with a poll.

---

## 20. A stored path is state; whether it resolves is a measurement

**Settings → Agents → Executables**, and a check on every launch.

`agent_installations.executable_path` was written once by the workspace's
first scan and spawned forever after. On 2026-09-07 Codex self-updated to
0.153.4, moved to a versioned standalone layout, and turned the stable path
its own installer advertises into a chain of junctions:

```txt
…\OpenAI\Codex\bin  ->  …\.codex\packages\standalone\current\bin
                    ->  …\releases\0.153.4-x86_64-pc-windows-msvc\bin
```

Windows refuses to traverse it — *"the path cannot be traversed because it
contains an untrusted mount point"*, errno 448 — so Codex could not be
started or resumed on Windows at all, launch after launch, while Settings
showed a healthy-looking Codex row. WSL and SSH were unaffected: DrvFs
resolves junctions itself.

### What the fix is, and which half is the durable one

| Piece | Where |
| --- | --- |
| The check, every launch, behind the first frame | `AppLifecycle.repairAgentPaths` |
| The reading — usable / missing / unreachable / unchecked | `packages/karmashala_core/lib/src/paths/path_probe.dart` |
| The repair, as the *same* sweep Settings runs | `AgentInstallationsController.repairBrokenPaths` |
| The manual lever and the honest report | `settings/presentation/agent_path_section.dart` |

**The check is the durable half; the resolution is not.** What the resolver
finds is `releases\<version>\…`, which the next Codex update moves. Nothing
stored can be permanent here, so the answer is not a cleverer path — it is
looking again, every time, cheaply enough that it can afford to.

Cheap is the load-bearing word: a workspace with nothing wrong costs one
`existsSync` per **local** installation and spawns no process at all. Only the
rows that actually failed are re-probed, and only in their own environment.

### Measured 2026-09-07, and it corrected the diagnosis

`File.existsSync` on a path behind an untrusted mount point answers a flat
**`false`**. It does not throw — `Directory.existsSync` and `Link.existsSync`
raise errno 448, and `lengthSync` names the reason. So **an exception cannot
tell an unreachable file from an absent one**, and any check built on catching
one silently reports a working CLI as uninstalled.

What does work, from plain Dart, with no PowerShell and no subprocess:

```txt
Link(r'…\OpenAI\Codex\bin').targetSync()      -> …\standalone\current\bin
FileSystemEntity.typeSync(p, followLinks: false) -> link
```

Both are about the junction *itself* rather than anything behind it, so the
traversal the OS refuses never happens. `resolveReparsePoints` walks a path
**one component at a time** on that basis and resolved the real chain in two
hops; the result runs (`codex-cli 0.153.4`). `resolveSymbolicLinksSync`
throws and is no use.

So the **reparse walk is the discriminator**, not an errno:

* a route that completes and finds nothing → `missing`;
* a route that cannot be completed → `unreachable`.

That is §19's rule applied to the filesystem, and it is chosen over
candidate-path globbing (`~/.codex/packages/standalone/releases/*/bin`)
deliberately: nothing in `path_probe.dart` knows the word "codex", so the next
tool to install itself behind a versioned junction is already covered, and no
vendor's directory layout is baked into discovery.

### Three rules the reconciler now follows

1. **An unreachable row is never deleted.** A junction chain answers `where`,
   `existsSync` and `Process.run` exactly like an uninstalled CLI, so deleting
   on that evidence turns *"installed somewhere I cannot reach"* into *"not
   installed"* — the worse of the two, because it takes the agent out of
   Settings and leaves nothing to correct. It is reported on its own line and
   counted among neither `found` nor `missing`.
2. **A move keeps the row and its id.** `AgentInstallationDao.updatePath`,
   not delete-and-insert. The id is what settings pin as the default agent and
   what every session references; the old path repointed the sessions and
   silently unpicked the default.
3. **A working hand-set path is never overruled by a sweep.** Recorded in v39
   as `executable_by_user`, the way `sessions.title_by_user` is — *never*
   inferred from "the path differs from what discovery would find", which
   cannot be recovered after a restart. A hand-set path that stops working is
   still repaired, and reverts to detected, because a stale path helps nobody
   whoever set it.

### What it deliberately does not do

- **Judge a WSL or SSH path.** Those are spelled for *their* disk, so a stat
  of ours is not evidence either way; they read as `unchecked` and are never
  repaired from here. This is why the failure was Windows-only in the first
  place.
- **Re-resolve a healthy path.** Trading a stable spelling for whatever it
  points at today rots on the next update for no benefit.
- **Cover anything but agent executables.** Deliberately scoped, and the audit
  behind that decision is below rather than lost.

### What else can rot, audited 2026-09-07

**Only a *persisted* location can go stale unobserved**, so that is the line.
Most of this app is on the safe side of it by construction: toolchain lookups
(`git`, `gh`, Chrome, editors, terminals) are resolved by bare name on
every spawn; `adb` by one rule every user of it on a machine shares, on
every probe (the `androidSdkPath` setting, `ANDROID_HOME`, `ANDROID_SDK_ROOT`,
the default SDK, the PATH); `karmashala_mcp` and WebDriverAgent are found relative to
`Platform.resolvedExecutable` per call; `scrcpy-server` is a bundle asset
staged into `systemTemp` under a per-start name; `CliStoreLocator` rebuilds
every store home from `$HOME` each time; `execution_environments
.wsl_distribution` is re-discovered and upserted every launch; and
`paired_devices.relay_url` stores the *sentinel* `'local'`, resolved at serve
time — which is the pattern the rest of these should copy.

Persisted and never re-validated, in rough order of how much it matters:

| Location | Where | Why it is not covered here |
| --- | --- | --- |
| `customTerminalPath`, `customEditorPath` | `settings/domain/settings.dart` | Persisted **and spawned**, with no `exists` check at save or at use. The closest analogue to the agent case. Left alone because each already sits beside a browse-or-paste field the user owns, so the failure is one step from its own fix — but a check would belong here. |
| `ssh_hosts.private_key_path` | `karmashala_ssh/src/ssh_connection.dart` | Probed only at connect, with a bare `File.exists()` — so a key that is present but unreachable is reported *"Private key not found"*, which is the wrong reason. The same two-value collapse this section exists to correct. |
| `imported_sessions.file_path`, `store_home` | `cli_detection/data/imported_session_dao.dart` | Written under `ON CONFLICT DO NOTHING` and never refreshed. The presence machinery beside it re-locates the *store* and validates a conversation id, never this path. |
| `terminal_panes.working_directory`, `launch_command` | `terminal/application/terminal_sessions_controller.dart` | Restored verbatim; a bad one fails at the ConPTY spawn. |
| `session_checkpoints.repository_path`, `verification_runs.artifact_directory`, `fanout_candidates.worktree_path` | various | Historical records of where work happened. Repairing them would rewrite history rather than fix anything. |

**One known-shape gap, recorded rather than fixed.**
`sessionDirectoryPresentProvider` (`sessions/application/session_working_directory.dart`)
ends `on Object { return true; }`, and its docstring says so on purpose: a path
it merely *failed* to check must not be declared missing, because that would
break every SSH session to close a smaller hole. That reasoning is sound for
the case it was written for — an environment with no translation to a
Windows-reachable form. It does **not** cover a junction chain, where
`existsSync` raises and the answer becomes "present" for a directory the OS
will refuse, so the session spawns into it anyway. `readExecutable`'s
three-way reachability is the shape that closes it; doing so is a change to
session launch rather than to agent discovery, which is why it is written down
here instead of folded into this change.

### The version beside the path, and the cadence question it raised

The path was re-measured every launch while the **version** on the same row
was never re-read at all. `discoverUnprobed` skips any `(agent, environment)`
pair that already has an installation row, so only a manual "Detect agents"
reached `updateVersion`: the app reported Claude Code **2.1.252** for a binary
answering **2.1.263**, launch after launch. Version-sensitive behaviour makes
that more than cosmetic — the hook subtype map is sourced from a specific
release — and one row, `claudeCode | windows | 2.1.245`, named a version for a
binary `where claude` no longer finds at all.

The owner's open question was *"once per the whole app's lifecycle? or what,
doing it on every session start is not that cheap either?"* Both halves are
right, and neither is the answer:

| | cost | what it misses |
| --- | --- | --- |
| once per app lifecycle | a spawn per row per launch | Codex self-updated **mid-session**, and sessions here are long |
| every session start | a spawn per session | a number nobody is looking at |

So the occasion is the launch that already checks the paths, and **the gate is
the row's own recorded age** (`version_read_at`, v40; `kVersionReadingFreshFor`,
12 h). A workspace whose readings are fresh spawns nothing — not even a stat.
One that has aged out pays one process per **local and WSL** installation,
once, and not again until it ages out. A machine relaunched five times in an
hour re-reads once.

**And the durable half is the age, not the cadence.** A bare number is a
confident false statement whatever rate writes it, because the reader cannot
tell which reading they are looking at; "2.1.252 · last read 2d ago, may be out
of date" is honest even when wrong. That is why `version_read_at` is stored and
rendered rather than a refresh interval being tuned — and why it is nullable
and **never backfilled from `created_at`**: an unknown reading time is not a
reading time (§19).

§20's rules carry over unchanged. A **WSL** row is asked through the WSL
runner, so nothing local is stat-ed or spawned on its behalf; an **SSH** row is
not asked by a launch at all — probing it means dialling somebody's machine,
which is `discoverUnprobed`'s own rule — and shows its reading's age instead. A
local row whose executable was just observed *missing* is not spawned at, so
the 2.1.245 row keeps both its number and its id and reads as stale beside
§20's verdict about its path. A probe that could not answer writes **nothing** —
not the number, not the timestamp — so a located binary whose `--version` fails
never erases a number we did know.

**Deferred, deliberately.** The pickers (quick open, the new-session dialog,
Settings → Environments, the companion) and the MCP `list_agents` payload still
show a bare number; each is choosing *which* agent rather than reading its
version, and the reading time is on the row for whenever that changes. No
refresh when the panel opens (§19's Tools precedent would allow it; the launch
plus "Detect agents" covers the reported failure), no update check against a
registry, no "a new version is available", and no setting for the bound — a
cadence the user has to tune is one nobody tunes.

## 21. Comments: a line or two, or none

Measured 2026-09-10: comments were **25% of `lib/`** (45,648 lines) and 20% of
`packages/`. Sections 2 and 4 already said "concise"; they were ignored, so
here is the rule as something checkable.

**A comment earns its place only by saying *why* a reader would otherwise get
it wrong.** One line, two at most. A doc comment on a public API may name what
it returns and one refusal it makes; that is all.

**Delete on sight:** anything restating the code; a measurement narrative
("measured here, 25 s, the dialog stayed at visible=0…"); the history of what
the code used to be; "why that matters" essays; a paragraph justifying a
decision. **Those belong in the commit message**, where `git log` finds them
beside the change and a reader of the code does not scroll past them.

**When trimming, a fact that is load-bearing stays as one sentence** rather
than being deleted. Everything else goes.

## 22. The session host is a bundle, and it is built where it runs

`server/` (package `karmashala_host`) carries the app's store (`packages/karmashala_store`), so it
depends on `sqlite3`, which has a build hook. Two rules follow, and both bite
silently if forgotten.

**Build it with `dart build cli`, never `dart compile exe`.** `compile exe`
refuses any target with a build hook — *"does not support build hooks. Packages
with build hooks: sqlite3."* The output is a directory, not a file:

```txt
<out>/bundle/bin/karmashala_host[.exe]
<out>/bundle/lib/libsqlite3.so   (sqlite3.dll on Windows)
```

From the repository root: `dart build cli -t server/bin/karmashala_host.dart
-o <out>`. Pass `-o <out>` so nothing has to know the `<os>_<arch>` directory
name. The
executable finds its SQLite at `../lib`, so **the bundle cannot be flattened** —
not beside `karmashala.exe`, not into a remote `bin/`.

**Build each platform's bundle on that platform.** A Linux bundle
cross-compiled on Windows is a sound ELF next to a sound `.so` and still cannot
load it: the library's relative path is written with the *building* machine's
separator, so it looks for `..\lib\libsqlite3.so`. `karmashala_host probe-store`
reports that as `STORE MISLINKED`. Linux bundles come from the
`build-host-linux` job on `ubuntu-latest`; `tool/build_release.bat` builds
this machine's and downloads the rest, and when the release has none it builds
them in WSL from the commit being built (`tool/build_host_linux.dart`).

The deployed box needs **no `libsqlite3` of its own** — SQLite is bundled. The
deployer uploads one tarball per target and unpacks it; `probe-store` says which
of four things is wrong when a machine cannot hold a store.

**The bundle is also the relay.** `karmashala_host relay` runs
`relay/`'s server, so an SSH host used as the desktop's relay needs no
second artifact and CI builds none. `relay/` stays out of the workspace and is reached by
path, as the app already reaches it; so does its contract, `relay/protocol/`,
which the server and every client of the relay read instead of repeating.

**In tests, never `dart run` the host.** Every spawn stages the bundled library
into `.dart_tool/`, and parallel workers collide on the locked library. The live
harnesses build once per isolate instead.

## 23. Probe mode — building Karmashala inside Karmashala

Karmashala is developed from sessions running **inside** the installed app. To
test a change you run a second copy beside it, and **that copy must be a
probe.** An ordinary second instance is not isolated by `KARMASHALA_DATA_DIR`
alone: on launch it rewrites the hook endpoint in `~/.claude`, `~/.codex`,
`~/.gemini` and every WSL home with *its* port and token, so the real app's
agents report their status to it; on quit it deletes those endpoint files; and
its first settings pass deletes the real app's launch-at-login entry. That
happened on 2026-09-21 (`Agent hooks: 6 installed … 3 reporting by spool` in a
debug instance's log).

**Every agent that runs a second instance of this app runs it as a probe.**
Never run a bare `flutter run`, `debug_run.bat` without `-Fresh`, or a built
exe beside the installed app.

### Running one

A release build (built by the usual route; do not install it):

```powershell
$env:KARMASHALA_PROBE = "1"
$env:KARMASHALA_DATA_DIR = "$env:TEMP\karmashala-probe"
& .\app\build\windows\x64\runner\Release\karmashala.exe
```

A debug build, from PowerShell with the Windows toolchain (§17):

```powershell
$env:KARMASHALA_PROBE = "1"
$env:KARMASHALA_DATA_DIR = "$env:TEMP\karmashala-probe"
cd app
C:\Users\<you>\flutter\bin\flutter.bat run -d windows --debug
```

or `tool\debug_run.bat -Fresh`, which sets both (data in `app\build\debug-data`).
A profile build for CPU or heap work is `tool\profile_run.bat`, which is always
a probe (data in `app\build\profile-data` unless `KARMASHALA_DATA_DIR` is set).
`flutter run` does not build `karmashala_mcp.exe`; drive a profile probe with
the Release one and `KARMASHALA_DATA_DIR` pointed at the probe.
The variables are inherited by `flutter run`'s child and by every process the
probe starts, which is what points an agent's MCP bridge inside the probe at
the probe's handshake rather than the real app's. Delete the data folder for a
clean slate. The one thing that outlives a probe is its own session host, if
it started one (host-backed panes): a detached `karmashala_host serve` holding
`<data>\host`. Stop it first, or the folder will not delete:

```powershell
$env:KARMASHALA_HOST_DIR = "$env:KARMASHALA_DATA_DIR\host"
& .\app\build\windows\x64\runner\Release\host\bin\karmashala_host.exe stop --force
```

### The rules it is built to

- **One switch, read once.** `KARMASHALA_PROBE` (`1`/`true`/`yes`/`on`) is read
  into `ProbeMode.current` (`lib/src/core/probe/probe_mode.dart`) and handed to
  the container as `probeModeProvider`; every guarded site asks that provider.
- **A probe needs its own data folder, and is refused without one.**
  `resolveDataDirectory` throws — shown on the bootstrap failure screen before
  any file is opened — when `KARMASHALA_DATA_DIR` is unset, or when it names
  the real folder. It does not invent a scratch folder: the bridge an agent in
  the probe spawns finds its handshake through that variable, so a folder the
  app chose itself would send those agents' tool calls to the real app.
- **Unmistakable.** Window title `Karmashala — PROBE`, a red banner above every
  route naming the data folder, and tray tooltip `Karmashala PROBE`.

### What a probe does not do

| Side effect | Where it is stopped |
| --- | --- |
| Hook scripts, config entries and endpoint files in every agent store (install, the WSL late re-sweep, retire on quit, uninstall) | `AgentHookInstallationService._forEachStore`, and `AppLifecycle.installAgentHooks` / the shutdown retirement step |
| Draining the spool directories in agent stores | `AgentHookSpoolDrainer(enabled: false)` |
| Skills in agent skill roots (install and removal) | `AgentSkillInstallationService._forEachStore`, `AppLifecycle.installAgentSkills` |
| Launch at login (the shared `Karmashala` Run value) and the global launcher hotkey | `SystemIntegrationService.init` / `_reconcile` |
| Remote access on the LAN: binding every interface, the beacon, the local relay on 8787. A probe pairs phones with its own server (its own `server.json`, in the probe's data folder), over the internet relay | `RemoteAccessController.setRemoteAccess` |
| OS toasts (the first rewrites the Start Menu shortcut toasts are delivered through) | `notificationPresenterProvider` |
| The env-vault key in the per-user cache folder | `EnvVault.open` keeps a probe's key in `<data>/probe-key` |
| The owner's local server (`~/.karmashala`: its socket, lock, log and sessions, and its data — the database the app opens too, `server.json`) — attaching to, listing, ending or starting it | `localHostSessionAccessProvider` gives a probe its own host in `<data>/host`, and the `serve` it starts from the same binary is handed `KARMASHALA_HOST_DIR` naming it, which `HostPaths.resolve` reads first, and `--data-dir=<data>`, so it keeps its data — the probe's database — in the probe's folder (the real app's `serve` gets no `--data-dir`: its data is the server's default folder) |
| The session host on SSH machines, which holds the owner's remote sessions | `_hostSessionAccessFor` answers null and `HostSessionsService` refuses, so a probe's SSH panes take the tmux path and its session lists stay empty |

A probe's local host socket is `<data>\host\host.sock`; when that is too long
to bind it falls back to a name hashed from that path, exactly as the `ipc/`
socket does, so it never lands on the owner's. Already scoped and left alone:
the database, logs, `mcp_bridge.json`, the
`ipc/` socket (its long-path fallback is hashed per data folder), `mcp/`
session configs, the vault, recordings and verification artifacts all live
under the data folder. The tray icon and keep-awake are per process.
Read-only work — environment discovery, CLI session import, the conversation
index, agent path and version checks — still runs; it boots WSL distributions
as the real app does.

**Still acts on shared state when you ask it to**, because the point is to
test these and each is an explicit action: switching a Claude/Codex account
(writes the real credential files), renaming or deleting a CLI session (edits
the real agent store), the browser pane (Chrome on the fixed CDP port 9222),
devices (the shared adb server), "Browse…" (prunes WSL rows from the
shared file-dialog MRU in the registry), and on an SSH machine the install
panel's install, start, stop and remove, pairing a phone to it, and using it as
the relay — each works on the one per-user host there, the owner's included.

### What degrades

- **Hook-based agent status.** Agents launched in the probe still fire the
  hooks the *real* app installed, so their live status goes to the real app and
  not to the probe; the probe falls back to its screen and state-file readers.
  The real app sees payloads for sessions it has no row for, as it does for any
  agent run outside it.
- No OS toasts (the in-app inbox still fills), no launcher hotkey, no remote
  access on the LAN (pairing goes over the internet relay), no launch at
  login. The banner's tooltip lists them.
- **SSH panes run on tmux, not the session host.** A remote host is per user
  and holds the owner's sessions, and namespacing it would need every deployed
  binary to honour `KARMASHALA_HOST_DIR` — an older one ignoring it would
  attach the probe to the owner's host without a word. So a probe cannot test
  SSH host panes; the real app can. Local host-backed panes work in full,
  against the probe's own host.
- **Not yet measured:** whether the bridge a *WSL* session in the probe spawns
  over interop inherits `KARMASHALA_DATA_DIR`. If it does not, that session's
  Karmashala tools reach the real app. Check `list_sessions` from such a
  session before relying on it. The switch-address `/mcp` listener, when it
  binds, is on the probe's own ephemeral port.

The tests are `test/core/probe/`. Each guarded seam has a non-probe twin that
proves the fixture can observe the write, so a green run is not an empty one.

## 24. Plan and task tools in chat sessions

The plan card draws what an agent's own plan tool publishes, and on
2026-10-04 neither chat bridge had one. **Karmashala does not switch them
off**; the CLIs do, and nothing here overrides them.

- **Claude Code 2.1.287** offers `TodoWrite`/`TaskCreate`/`TaskUpdate` only
  for older models (`claude-sonnet-4-*`, `claude-haiku-4-5`) or when
  `CLAUDE_CODE_ENABLE_TODO_TOOLS=true` (read off the binary: `J1()` gates
  them; `CLAUDE_CODE_ENABLE_TASKS=false` turns tasks off). A terminal session
  on a current model lacks them the same way.
- **Codex 0.160** reads `update_plan` from its own `[tools]` config
  (`tools.update_plan`); the bridge's `thread/start` carries only `cwd` and the
  MCP servers, so a thread has whatever the person's Codex config says.
