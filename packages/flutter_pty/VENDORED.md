# Vendored: flutter_pty 0.4.2

- **Upstream:** https://github.com/TerminalStudio/flutter_pty
- **Version:** 0.4.2 (pub.dev), copied from the local pub cache
- **Vendored on:** 2026-09-03 (profiling session — see `docs/PROFILE-2026-09-03.md`)

## Why this is forked

A 70-minute profiling session measured the app's open file descriptors going
**117 -> 165** and its thread count **21 -> 30** while the number of live child
processes stayed at 4. At the end, `lsof` showed 18 pty descriptors and 10
`(revoked)` entries against 4 live panes: every pane that had ended left its
descriptors behind.

Upstream 0.4.2 has **no teardown at all**. `Pty` exposes `write`, `resize`,
`kill`, `pid`, `exitCode`, `output` and `ackRead` — nothing that releases
anything, and `pty_create`'s handle is never freed. `TerminalInstance.dispose()`
does everything right on the Dart side and still could not give the pty back,
because there was no call to make.

Measured with `test/fd_lifecycle_harness.c`, upstream leaks **2 descriptors per
pty**; after this fork, 128 create/destroy cycles leave the count flat.
`test/tooling/pty_fd_lifecycle_test.dart` runs that harness in the suite.

Upstream shipped its last release in 2024 and 0.4.2 is still latest, so there is
no branch to upstream to and little drift to carry.

## Why it lives here and not in its own repository

The terminal fork moved out of `packages/xterm` and into `xterm2`, a separate
repository pinned by commit whose `KARMASHALA.md` records every divergence — so
the project's current convention for a *fork* is an external pin, and the
in-repo `packages/` entries left are first-party code and platform stubs.

This is deliberately the older shape for now, because moving it out is a
decision with a cost this change should not make silently: a second repository
to keep rebased, and a native plugin pinned by commit rather than built from
the tree it is tested in. Everything needed to move it is here — the diff
against 0.4.2 is entirely in the files listed below. If it is moved, this file
is what `KARMASHALA.md` should be seeded from.

## What changed

**`src/forkpty.c`** — the parent now closes the pty *slave*. `pty_forkpty` only
ever handed it back through an out-param, and `pty_create` — its only caller —
passes `NULL`, so one descriptor per pty was stranded at birth. libc's own
`forkpty()` closes it in the same place. This was the larger half of the leak
and is independent of teardown: it leaked even for a pane that was never closed.

**`src/flutter_pty_unix.c`**
- `pty_destroy()` added: closes the master, frees the handle, and is idempotent.
- `read_loop` now waits on `poll()` over the pty *and* a self-pipe, so a destroy
  can end it. It closes the master on the way out and frees its own options —
  upstream returned from a bare `read()` without closing or freeing either.
  The self-pipe is not decoration: closing the master to wake a thread blocked
  reading it is a use-after-free on the descriptor *number*, since the kernel
  can hand the same `int` to another thread's `open()` first.
- Whichever of `pty_destroy` and the read thread finishes last frees the handle,
  under a lifecycle mutex separate from the existing ackRead one (that mutex is
  held across the blocking read, so reusing it would deadlock).
- `pty_write`/`pty_resize` check the descriptor under that mutex, so a late
  write cannot land on a recycled fd.
- Both threads are now `pthread_detach`ed; nothing joins them, so their stacks
  were retained after they returned.
- `wait_exit_thread` frees its options.
- A child whose `execvp` fails now `_exit(127)`s. Upstream fell through and the
  forked child carried on running the *parent's* code — allocating a handle,
  starting threads, and returning into the Flutter engine as a second copy.
- `#include <string.h>` for `strlen`, which upstream used without declaring.

**`src/flutter_pty_win.c`** — same shape, so a long Windows session does not
accumulate handles: `pty_destroy()` added (`ClosePseudoConsole`, which is also
what unblocks the reader, then the pipe handles); `read_loop` and
`wait_exit_thread` free their options; both `CreateThread` handles are
`CloseHandle`d, the Win32 counterpart of `pthread_detach`.

Also: the bare **`Sleep(1000)`** between `CreatePseudoConsole` and
`CreateProcessW` is gone. `pty_create` is a synchronous FFI call, so upstream
spent that second on whichever isolate called `Pty.start` — for this app the UI
isolate, inside the Start button's `onPressed` — and it is two orders of
magnitude more than everything else the start path does put together. Nothing
needs it: the HPCON is already valid and already bound to the attribute list,
the reader and waiter threads start *after* the spawn, and the POSIX half of
this plugin sleeps nowhere. `test/tooling/pty_spawn_latency_test.dart` is a
source guard against a re-vendor putting it back.

**`lib/flutter_pty.dart`** — the exit port is read with `listen` rather than
upstream's `first`. `Stream.first` completes with `StateError('No element')`
when its stream closes without emitting, and `destroy()` closes that port
exactly when the child has *not* exited — so upstream's form turned every pane
torn down while its process was alive into
`Unhandled Exception: Bad state: No element`. `_onExitCode` also guards against
completing twice, which `listen` makes possible where a single-shot `first`
could not. Covered by `test/tooling/pty_exit_port_test.dart`.

`Pty.destroy()`, idempotent, closing both receive ports (`_onExitCode` only runs when the child actually exited, which is not the
case this exists for). `write`/`resize`/`ackRead` no-op afterwards, and `pid` is
memoised so `kill` still answers once the handle is gone.

**`lib/src/flutter_pty_bindings_generated.dart`** — the `pty_destroy` binding,
written by hand in ffigen's shape. ffigen is not re-run: this project forbids
code generation (ARCHITECTURE constraint 3).

## Known limitation

`pty_destroy` wakes the reader through the self-pipe, which only helps a reader
sitting in `poll()`. With `ackRead: true` the reader can instead be blocked on
the ackRead mutex waiting for Dart, and nothing releases it — that handle would
never be freed. This app never sets `ackRead` (it is `false` by default and
`TerminalInstance` does not pass it), so the path is untaken here; it is written
down rather than fixed because fixing it means restructuring upstream's flow
control, and an unused path is not worth that risk.

## What was NOT vendored

- `example/` — a full multi-platform Flutter app, irrelevant here.

## Verifying

    flutter test test/tooling/pty_fd_lifecycle_test.dart
    flutter test test/tooling/pty_spawn_latency_test.dart

The harness is POSIX-only. The Windows changes are the same shape but are not
exercised by it, and have not been run on Windows hardware — including the
removed `Sleep`, which needs a Windows build and
`pwsh tool/live_tests.ps1 -Family wsl` (a real ConPTY, in
`live_wsl_pane_test.dart` and `live_pane_resize_test.dart`) to confirm the
spawn and the first output still arrive.
