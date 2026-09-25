import 'dart:async';
import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';

/// Opens a pty session whose child waits for ever, then kills this process's
/// main isolate with an unhandled error, as a broken stdout pipe once did.
/// Prints the child's pid first, so the test can clean up. Used by `posix_pty_spawn_test.dart`: the VM must still
/// exit, however many pty readers are waiting on children that never speak.
Future<void> main() async {
  final pty = PosixPtyLauncher().start(
    const PtySpawnRequest(argv: ['sleep', '600']),
  );
  pty.output.listen((_) {});
  stdout.writeln('child ${pty.pid}');
  await stdout.flush();
  // Long enough for the reader isolate to be waiting on the pty.
  await Future<void>.delayed(const Duration(milliseconds: 500));
  Timer.run(() => throw StateError('the main isolate died'));
}
