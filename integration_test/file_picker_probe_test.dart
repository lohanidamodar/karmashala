import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

/// Manual verification — opens the **real** Win32 file dialog from a **real**
/// Flutter Windows window and records how far it gets.
///
///   flutter test integration_test/file_picker_probe_test.dart -d windows
///
/// Exists because the failure it investigates ends the process at the OS level:
/// the owner reported the app dying on the SSH host dialog's Browse button, and
/// the app's own log stops mid-run with nothing in it. Every step here is
/// therefore appended to [_logPath] **synchronously**, with `flush: true`, so a
/// process that is killed still leaves the last line it reached. `LogFileSink`
/// could not be used for the same reason: it queues behind a 400 ms timer.
///
/// Deliberately does not run the app's `main()`. Nothing here opens the app
/// database, binds a port, writes `mcp_bridge.json`, registers a global hotkey
/// or puts up a tray icon, so it is safe to run alongside the installed
/// instance — the same rule `tool/verification/notification_delivery_probe.dart`
/// follows.
///
/// A COM modal dialog is not a Flutter surface, so `tester` cannot dismiss it.
/// `tool/verification/pick_probe_file.ps1` drives it: it confirms the first
/// dialog with a real selection and cancels the second. Without that driver the
/// dialog simply stays up until [_dialogBudget] expires and the case reports
/// that nothing dismissed it, which is still an answer.
const _logPath = r'C:\Users\dlohani\karmashala-picker-probe.log';

/// How long one `openFile()` may take before the case gives up. Generous: the
/// first shell dialog in a process is slow, and the driver polls.
const _dialogBudget = Duration(seconds: 45);

void say(String line) {
  final stamped = '${DateTime.now().toIso8601String()} $line';
  stdout.writeln('PROBE $stamped');
  // Synchronous and unbuffered, one line at a time. See the note above.
  File(
    _logPath,
  ).writeAsStringSync('$stamped\n', mode: FileMode.append, flush: true);
}

/// Runs [body] and logs whatever it throws instead of failing the case: the
/// point of the run is to get as far as the picker, so a setup step that is
/// refused should be recorded and stepped over, not turned into a red test that
/// never opens a dialog at all.
Future<void> step(String label, Future<void> Function() body) async {
  say('  step $label');
  try {
    await body();
  } on Object catch (error) {
    say('  step $label FAILED: $error');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    File(_logPath).writeAsStringSync(
      '=== picker probe ${DateTime.now().toIso8601String()} pid=$pid '
      'exe=${Platform.resolvedExecutable} ===\n',
      flush: true,
    );
    say('probe start');
  });

  testWidgets('1. openFile from a focused Flutter dialog, with '
      'window_manager as the app configures it', (tester) async {
    await tester.runAsync(() async {
      // The app's own launch order: libmpv, then the window.
      await step('MediaKit.ensureInitialized', () async {
        MediaKit.ensureInitialized();
      });
      await step('windowManager.ensureInitialized', windowManager.ensureInitialized);
      await step('waitUntilReadyToShow', () async {
        await windowManager.waitUntilReadyToShow(
          WindowOptions(
            size: const Size(1200, 800),
            minimumSize: const Size(720, 560),
            center: true,
            title: 'Karmashala picker probe',
          ),
          () async {
            await windowManager.show();
            await windowManager.focus();
          },
        );
      });
      // Applied unconditionally by `SystemIntegrationService.apply`: it is what
      // makes WM_CLOSE reach Dart instead of destroying the window.
      await step('setPreventClose(true)', () async {
        await windowManager.setPreventClose(true);
      });
      final listener = _LoggingWindowListener();
      windowManager.addListener(listener);
      addTearDown(() => windowManager.removeListener(listener));
      say('1: window ready');
    });

    // A focused text field is part of the reported scenario: the SSH host
    // dialog's first field is `autofocus: true`, so a text input connection —
    // and on Windows an IME context — is live when the picker opens.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _BrowseDialog(),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    say('1: tapping Open');
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    say('1: dialog up, focus=${FocusManager.instance.primaryFocus?.debugLabel}');

    await tester.runAsync(() async {
      say('1: >>> calling openFile()');
      try {
        final file = await openFile().timeout(_dialogBudget);
        say('1: <<< openFile returned path=${file?.path}');
      } on TimeoutException {
        say('1: <<< openFile TIMED OUT — nothing dismissed the dialog');
      } on Object catch (error, stack) {
        say('1: <<< openFile THREW $error\n$stack');
      }
      say('1: still alive after openFile');
      // The window regains activation here; window_manager emits `focus`, which
      // in the app answers with native retries. Give that a moment to happen
      // while something is still watching.
      await Future<void>.delayed(const Duration(seconds: 5));
      say('1: still alive 5s later');
    });
  });

  testWidgets('2. a second openFile in the same process', (tester) async {
    await tester.runAsync(() async {
      say('2: >>> calling openFile()');
      try {
        final file = await openFile().timeout(_dialogBudget);
        say('2: <<< openFile returned path=${file?.path}');
      } on TimeoutException {
        say('2: <<< openFile TIMED OUT');
      } on Object catch (error, stack) {
        say('2: <<< openFile THREW $error\n$stack');
      }
      say('2: still alive after openFile');
      await Future<void>.delayed(const Duration(seconds: 5));
      say('2: still alive 5s later');
    });
  });

  tearDownAll(() {
    say('probe end — reached the end of the run');
  });
}

/// Logs the window events `window_manager` raises, because the activation
/// changes a modal dialog causes are the suspected trigger.
class _LoggingWindowListener extends WindowListener {
  @override
  void onWindowEvent(String eventName) => say('  window: event $eventName');
}

class _BrowseDialog extends StatelessWidget {
  const _BrowseDialog();

  @override
  Widget build(BuildContext context) => const AlertDialog(
    title: Text('Add SSH host'),
    content: SizedBox(
      width: 560,
      child: TextField(
        autofocus: true,
        decoration: InputDecoration(labelText: 'Name'),
      ),
    ),
  );
}
