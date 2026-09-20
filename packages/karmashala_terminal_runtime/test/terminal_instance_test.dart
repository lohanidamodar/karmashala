import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a process-less pane *owns*, and what it must leave alone.
///
/// `ErrorTerminalInstance` and `DormantTerminalInstance` both hold a focus node
/// and a scroll controller that nothing else disposes, and both are torn down
/// on paths that can run twice — a pane closed while the app is shutting down.
/// The contract under test is therefore ownership, not the presence of fields:
/// disposal releases exactly those two, a second disposal is a no-op, and the
/// liveness a closed pane reports stays readable afterwards.

ErrorTerminalInstance errorPane({
  String message = 'boom',
  String? restoredScrollback,
}) => ErrorTerminalInstance(
  id: 'p1',
  title: 'PowerShell',
  profileId: 'powershell',
  workingDirectory: r'C:\ws',
  message: message,
  restoredScrollback: restoredScrollback,
);

DormantTerminalInstance dormantPane({String restoredScrollback = 'earlier'}) =>
    DormantTerminalInstance(
      id: 'p1',
      title: 'PowerShell',
      profileId: 'powershell',
      restoredScrollback: restoredScrollback,
    );

void main() {
  group('ownership', () {
    test('disposal releases the focus node and the scroll controller', () {
      final instance = errorPane();
      final focusNode = instance.focusNode;
      final scrollController = instance.scrollController;

      // Live: both accept listeners.
      focusNode.addListener(() {});
      scrollController.addListener(() {});

      instance.dispose();

      // Disposed: both refuse, which is how we know the pane really let go of
      // them rather than merely dropping its reference.
      expect(
        () => focusNode.addListener(() {}),
        throwsA(isA<FlutterError>()),
        reason: 'the focus node should have been disposed with the pane',
      );
      expect(
        () => scrollController.addListener(() {}),
        throwsA(isA<FlutterError>()),
        reason: 'the scroll controller should have been disposed with the pane',
      );
    });

    test('a second disposal is a no-op, and the guard is what makes it so', () {
      // The control: Flutter itself does not tolerate this. Disposing the pane
      // twice is only safe because the pane refuses to run its teardown twice.
      final bare = FocusNode()..dispose();
      expect(() => bare.dispose(), throwsA(isA<FlutterError>()));

      expect(() => (errorPane()..dispose()).dispose(), returnsNormally);
      expect(() => (dormantPane()..dispose()).dispose(), returnsNormally);
    });

    test('a closed pane still reports the liveness it was closed in', () {
      // Both use a constant listenable precisely so a pane with no process does
      // not own a notifier that has to survive teardown. Reading after disposal
      // is the case that would throw if it were a real ValueNotifier.
      final error = errorPane()..dispose();
      final dormant = dormantPane()..dispose();

      expect(error.liveness.value, PaneLiveness.exited);
      expect(dormant.liveness.value, PaneLiveness.restored);

      // And it stays inert rather than accumulating listeners.
      expect(() => error.liveness.addListener(() {}), returnsNormally);
      expect(() => error.liveness.removeListener(() {}), returnsNormally);
    });

    test('neither pane claims command boundaries it never observed', () {
      // No process ran, so there is nothing to have recorded. A recorder here
      // would be a lie the prompt-building code would believe.
      expect(errorPane().commandBlocks, isNull);
      expect(dormantPane().commandBlocks, isNull);
    });

    test('neither pane is something the quit sequence has to wait for', () {
      // The shutdown reaps by collecting a future per pane that owns a process.
      // These two own none, and saying otherwise would put an always-complete
      // future in a wait that exists to be slow — or worse, invite a caller to
      // treat "disposed" as "the process is gone".
      expect(errorPane(), isNot(isA<ReapableTerminalInstance>()));
      expect(dormantPane(), isNot(isA<ReapableTerminalInstance>()));
    });

    test('identity survives disposal', () {
      final instance = errorPane()..dispose();
      expect(instance.profileId, 'powershell');
      expect(instance.workingDirectory, r'C:\ws');
      expect(instance.id, 'p1');
    });
  });

  group('restored content order', () {
    test('an error pane replays history, then a marker, then the error', () {
      final instance = errorPane(
        message: 'later',
        restoredScrollback: 'earlier',
      );
      addTearDown(instance.dispose);

      final text = [
        for (var i = 0; i < 5; i++)
          instance.terminal.buffer.lines[i].getText().trim(),
      ];
      expect(text.first, 'earlier');

      final marker = text.indexWhere((l) => l.contains('restored'));
      final error = text.indexWhere((l) => l.contains('later'));
      expect(marker, greaterThan(0), reason: 'history comes before the marker');
      expect(
        error,
        greaterThan(marker),
        reason: 'the marker separates replayed history from new output',
      );
    });

    test('no marker is written when there is nothing to restore', () {
      final instance = errorPane(message: 'only this');
      addTearDown(instance.dispose);

      expect(
        instance.terminal.buffer.lines[0].getText(),
        contains('only this'),
      );
      final all = [
        for (var i = 0; i < 5; i++) instance.terminal.buffer.lines[i].getText(),
      ].join('\n');
      expect(all, isNot(contains('restored')));
    });

    test('a dormant pane replays its scrollback verbatim, with no marker', () {
      // Unlike the error pane it keeps the original string, so that starting it
      // replays exactly what was stored — no second trip through the codec and
      // no duplicated marker.
      final instance = dormantPane(restoredScrollback: 'first\r\nsecond\r\n');
      addTearDown(instance.dispose);

      expect(instance.restoredScrollback, 'first\r\nsecond\r\n');
      expect(instance.terminal.buffer.lines[0].getText().trim(), 'first');
      expect(instance.terminal.buffer.lines[1].getText().trim(), 'second');
      final all = [
        for (var i = 0; i < 4; i++) instance.terminal.buffer.lines[i].getText(),
      ].join('\n');
      expect(all, isNot(contains('restored')));
    });
  });

  group('a spawn failure names the command without burying its own error', () {
    // A shell-integrated PowerShell pane's script (once an `-EncodedCommand`
    // base64 payload) runs to thousands of characters. Printed
    // verbatim it pushed the exception — the one sentence that explains the
    // failure — off the visible buffer, so the error message hid its error.
    final blob = 'A' * 4600;

    test('a long argument is summarised, with its length kept', () {
      final line = describeLaunchArguments([
        '-NoLogo',
        '-EncodedCommand',
        blob,
      ]);

      expect(line, '-NoLogo -EncodedCommand <4600 characters elided>');
      expect(line, isNot(contains(blob)));
      // The flag before it is what says *which* argument was elided.
      expect(line, contains('-EncodedCommand'));
    });

    test('ordinary arguments survive whole', () {
      const args = [
        '-d',
        'archlinux',
        '--cd',
        r'C:\Users\dlohani\projects\popupbits\karmashala-app',
      ];

      expect(describeLaunchArguments(args), args.join(' '));
    });

    test('and nothing is elided at the boundary', () {
      final exact = 'x' * 120;
      expect(describeLaunchArguments([exact]), exact);
      expect(describeLaunchArguments(['${exact}y']), '<121 characters elided>');
    });
  });
}
