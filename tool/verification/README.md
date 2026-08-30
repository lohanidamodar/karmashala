# Manual verification programs

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

Each Chrome program spawns its own browser on its own port with a throwaway
profile, and kills the browser and deletes its temp directories on the way out.
Exit code 0 means every check passed. `real_verification_run.dart` writes only
to an in-memory database and a temp artifact directory.

`real_verification_run.dart` also touches the attached phone: it launches
Settings, taps one element and presses Home afterwards, so the device is left as
it was found. It is the only program here with a side effect outside this
machine.

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
