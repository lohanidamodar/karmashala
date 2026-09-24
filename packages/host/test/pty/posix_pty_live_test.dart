@Tags(['live'])
@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// The pty layer against a real kernel, for the one failure no stand-in shows:
/// a job that left the leader's group keeps the slave open after the leader is
/// gone, so the reader never sees end-of-file and the session never ends.
///
/// On 2026-09-24 that was a `claude login` typed at a zsh pane. Ending the pane
/// signalled zsh's group only — macOS has no `/proc` to find the rest by — and
/// the host then closed the master under the still-blocked reader, on the
/// isolate that answers every client, and stopped answering for hours.
void main() {
  test(
    'killing a session reaches a job in a group of its own',
    () async {
      final pty = PosixPtyLauncher().start(
        const PtySpawnRequest(
          // `set -m` puts the job in a group of its own, as an interactive
          // shell's job control does, and ignores the hangup the leader's death
          // sends, as `claude` did. The sleep bounds a failing run.
          argv: [
            '/bin/sh',
            '-c',
            r'set -m; sh -c "trap \"\" HUP; echo job=\$\$; sleep 20"; :',
          ],
        ),
      );
      final said = StringBuffer();
      final ended = Completer<void>();
      pty.output.listen(
        (bytes) => said.write(String.fromCharCodes(bytes)),
        onDone: ended.complete,
      );
      final job = RegExp(r'job=(\d+)');
      while (job.firstMatch(said.toString()) == null) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final jobPid = int.parse(job.firstMatch(said.toString())!.group(1)!);

      pty.kill(9);
      await ended.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'output never ended: pid $jobPid still holds the slave '
          '(alive: ${Process.killPid(jobPid, ProcessSignal.sigcont)})',
        ),
      );
      await pty.exitCode.timeout(const Duration(seconds: 5));
      await pty.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        // Signal 0 is not offered, so SIGCONT: harmless, and false when gone.
        Process.killPid(jobPid, ProcessSignal.sigcont),
        isFalse,
        reason: 'the job outlived the session it belonged to',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'close() leaves this isolate running while a job still holds the slave',
    () async {
      final pty = PosixPtyLauncher().start(
        const PtySpawnRequest(
          argv: ['/bin/sh', '-c', r'echo ready; read -t 20 x'],
        ),
      );
      final said = StringBuffer();
      pty.output.listen((bytes) => said.write(String.fromCharCodes(bytes)));
      while (!said.toString().contains('ready')) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final clock = Stopwatch()..start();
      final closing = pty.close();
      // A turn of this isolate's event loop, which cannot run while a close
      // is asleep inside it.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      await closing.timeout(const Duration(seconds: 5));
      // By pid: a closed handle signals nothing.
      Process.killPid(pty.pid, ProcessSignal.sigkill);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
