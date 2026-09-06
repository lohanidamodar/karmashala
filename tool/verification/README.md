# Manual verification programs

## Android idle/resume freeze — 2026-09-06

`android_stream_probe.dart` runs the production stream service and player
configuration against a physical device and a real libmpv. It creates its own
scrcpy session, skips orphan reaping, and stops only that session on exit.
It does not drive the phone: leave it idle, then use a harmless expander or
scroll. `vo=null` means this verifies native playback, not Flutter's texture.

Run from Windows PowerShell in the checkout (WSL callers must use the Windows
toolchain from CLAUDE.md §17 and redirect stdin from `/dev/null`):

```powershell
& C:\Users\dlohani\flutter\bin\cache\dart-sdk\bin\dart.exe --disable-dart-dev `
  --packages=C:\Users\dlohani\flutter\packages\flutter_tools\.dart_tool\package_config.json `
  C:\Users\dlohani\flutter\bin\cache\flutter_tools.snapshot test `
  tool/verification/android_stream_probe.dart --reporter expanded `
  --dart-define=DEVICE_SERIAL=F6IZLV6LMFT4U4ZT `
  --dart-define=ADB_PATH=C:\Users\dlohani\AppData\Local\Android\Sdk\platform-tools\adb.exe `
  '--dart-define=LIBMPV_PATH=C:\Program Files\Karmashala\libmpv-2.dll'
```

Replace the device and SDK/library paths for another machine. Samples default
to 45; `--dart-define=PROBE_SAMPLES=90` extends the observation. The exit state
must have received frames and must not be EOF or paused. A passing exit alone
does not prove idle/resume: inspect frame counts and position across the input.

Measured on CPH1989, using the installed Windows libmpv and production settings:

| Configuration | Received frames after idle/input | Player position | EOF / paused |
| --- | --- | --- | --- |
| media_kit's inherited 5s timeout | 22 → 138 | stuck at 1.000000 | yes / yes |
| local live stream timeout disabled | 11 → 103 | 0.900000 → 7.323878 | no / no |
| same fixed stream, another idle/burst | 103 → 114 | 7.323878 → 8.339878 | no / no |

The fault was normal scrcpy silence being treated as HTTP EOF. The patch sets
`network-timeout=0` for this player. The service still owns socket/process
liveness and closes HTTP when stopped. Cost: 10 property writes per player
setup instead of 9; no added periodic work. The hermetic regression test checks
the override and setup-write count, not elapsed time.

The watchdog's delivery-vs-presentation blind spot, incomplete cached GOP
replay, and uncapped pending writes remain separate findings. They were not
needed to explain this reproduction and are not claimed fixed by this patch.

Comparison: `serve-avd` uses screenrecord and a browser H.264 decoder; its
recovery and buffering policies are useful references, but replacing scrcpy is
not necessary for this failure. iOS currently uses WDA/XCTest and MJPEG, whereas
`serve-sim` uses a native Swift helper with H.264/MJPEG and browser playback.
References: https://github.com/hsandhu/serve-avd and
https://github.com/EvanBacon/serve-sim. No iOS device was available on this host.

## Other probes

These drive **real** browsers, devices and agent CLIs. None of them is part of
`flutter test`: they live under `tool/` so that test discovery cannot pick them
up, and so that their presence never reads as automated coverage.

Until Loop 63 they sat under `test/` and `integration_test/`. Four of them were
named so that discovery skipped them silently (no `_test.dart` suffix), and the
fifth ran on every CI pass without asserting anything useful. Both arrangements
overstated coverage and made the programs hard to find. They are here now, with
their prerequisites written down.

Run everything from the repository root.

| Program | Command | Needs |
| --- | --- | --- |
| `real_chrome_smoke.dart` | `dart run tool/verification/real_chrome_smoke.dart` | Chrome; free port 9333 |
| `real_chrome_tools_smoke.dart` | `dart run tool/verification/real_chrome_tools_smoke.dart [url]` | Chrome; free port 9334 |
| `real_chrome_pane_check.dart` | `flutter test tool/verification/real_chrome_pane_check.dart` | Chrome; free port 9335 |
| `real_verification_run.dart` | `flutter test tool/verification/real_verification_run.dart` | Chrome (port 9336) **and** an attached Android device with `adb` |
| `resume_conflict_probe.dart` | `flutter test -d windows tool/verification/resume_conflict_probe.dart` | Windows desktop; WSL; a logged-in `codex` and/or `claude` in the distro |
| `notification_delivery_probe.dart` | `flutter test -d windows tool/verification/notification_delivery_probe.dart` | Windows desktop with a visible notification area and toasts enabled for the app |

Each Chrome program spawns its own browser on its own port with a throwaway
profile, and kills the browser and deletes its temp directories on the way out.
Exit code 0 means every check passed. `real_verification_run.dart` writes only
to an in-memory database and a temp artifact directory.

`notification_delivery_probe.dart` raises one real toast and puts a second,
badged tray icon in the notification area for ten seconds, then destroys it. It
is the only program here that asserts something about the operating system: it
waits for the plugin's `onShow` callback rather than sleeping, and fails if the
toast is never handed to WinToast. The tray half has no callback to wait on and
has to be looked at — that is the dwell, not a race.

`real_verification_run.dart` also touches the attached phone: it launches
Settings, taps one element and presses Home afterwards, so the device is left as
it was found. It is the only program here with a side effect outside this
machine.

## What moved here in Loop 69

`notification_delivery_probe.dart` was `integration_test/notification_delivery_test.dart`:
twenty-six seconds of fixed sleeps (6 s, 8 s, 10 s) and not one assertion about
OS delivery or the tray. Its two real assertions — the coalescer's burst title
and `SessionAttention.menuLabel` — needed no operating system and were already
covered by `notification_coalescer_test.dart` and `agent_status_watcher_test.dart`,
so they are not repeated in the probe. This is the same verdict the test audit
reached for `resume_conflict_probe.dart`, applied to a file it did not look at.

The SSH latency measurements that sat at the bottom of
`test/features/ssh/live_ssh_test.dart` moved in the same loop, to
`tool/benchmark/ssh_latency_bench.dart` — a benchmark, not a test, so it lives
beside `paint_bench.dart` rather than here.

## `resume_conflict_probe.dart` is a diagnostic, not a test

It prints; it does not meaningfully assert. The codex case asserts only that
pane A produced a rollout file — nothing about the *second* resume, which is the
behaviour its name promises. The claude case asserts nothing at all. Read the
`TRACE` and `SCREEN` dumps it emits; a green run is not evidence.

It is also not hermetic. It depends on installed CLIs, live accounts, whatever
session state `~/.codex` and `~/.claude` already hold, and fixed 15–35 second
sleeps, under an eight-minute timeout.

### What a real second-resume conflict test would need

Turning this into a regression test — the audit's missing test #5 — needs four
things this program does not have. It was left as a probe because none of them
can be faked at the seam it currently uses:

1. **An isolated agent home per run.** Point `CODEX_HOME`/`HOME` (and the
   equivalent for Claude) at a temp directory seeded with a known conversation,
   so the run neither reads nor corrupts the developer's real history. Today
   both cases resume whatever the host happens to have.
2. **A stand-in for the agent.** The behaviour under test is *ours* — what the
   app does when a resume is refused — not the CLI's. A fake executable that
   holds a lock file and prints each agent's real refusal text makes the
   conflict deterministic and removes the account requirement. Capture the real
   refusal strings with this probe first; they are the fixture.
3. **A named observable state instead of a sleep.** Poll
   `TerminalGridStatusSource` for the specific status and screen text that means
   "refused to resume", with a bounded timeout, and fail on the timeout. The
   fixed delays here are the reason it takes eight minutes and still races.
4. **An assertion about pane B.** The outcome to assert is what the second pane
   ends up in — refused, with the message surfaced, and pane A still live and
   unharmed. Nothing in the current program looks at pane B's state at all.

With (1) and (2) the test stops needing WSL, an install or an account, and can
move back into the automated suite. Without them it stays here.
