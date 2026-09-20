import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';

/// Tearing a pty down must not raise an unhandled exception.
///
/// `Pty.destroy` closes the exit port when the child has **not** exited — that
/// is the case it exists for. Upstream read that port with
/// `_exitPort.first.then(...)`, and `Stream.first` completes with
/// `StateError('No element')` when its stream closes without ever emitting.
/// Nothing awaits that future, so it surfaced as
/// `Unhandled Exception: Bad state: No element` from `Pty._onExitCode` — once
/// per pane closed while its process was still alive. Seen in a real run
/// immediately after a session restarted to apply its permission mode.
///
/// Two halves, because the plugin's library exists only inside a built app and
/// `flutter test` cannot load it (the same reason `pty_fd_lifecycle_test.dart`
/// compiles the C rather than calling it):
///
///  1. the hazard, demonstrated on a real `ReceivePort` — the exact type the
///     plugin uses — so the rule is pinned by behaviour rather than by belief;
///  2. a source assertion that the plugin follows the rule, which is what an
///     upstream merge or a re-vendor would undo.
void main() {
  test(
    'a ReceivePort closed before it emits poisons first(), not listen()',
    () async {
      Future<int> unhandledFrom(void Function(ReceivePort) read) async {
        final errors = <Object>[];
        await runZonedGuarded(() async {
          final port = ReceivePort();
          read(port);
          port.close();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }, (error, _) => errors.add(error))!;
        return errors.length;
      }

      expect(
        await unhandledFrom((port) => port.first.then((_) {})),
        1,
        reason: 'this is the crash: Stream.first has no element to give',
      );
      expect(
        await unhandledFrom((port) => port.listen((_) {})),
        0,
        reason: 'a closed port simply ends a listen',
      );
    },
  );

  test('the vendored pty reads its exit port with listen', () {
    final source = File(
      'packages/flutter_pty/lib/flutter_pty.dart',
    ).readAsStringSync();
    expect(
      source,
      contains('_exitPort.listen(_onExitCode)'),
      reason: 'destroy() closes this port with no message in it',
    );
    expect(
      source,
      isNot(contains('_exitPort.first')),
      reason: 'upstream\'s form, which crashed on every torn-down pane',
    );
    // Completing twice throws where the single-shot `first` could not.
    expect(source, contains('if (_exitCodeCompleter.isCompleted) return;'));
  });
}
