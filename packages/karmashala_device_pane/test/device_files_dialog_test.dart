import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:path/path.dart' as p;
import 'package:agent_cli/process.dart';
import 'package:karmashala_device_pane/providers.dart';
import 'package:karmashala_device_pane/dialogs.dart';

import 'support/fake_command_runner.dart';
import 'fake_scrcpy_control_channel.dart';

// A temp root this host could hand the staging code, which joins with the
// host's own separator.
final _temp = Platform.isWindows ? r'C:\Temp' : '/tmp';

/// The device file browser as a surface: copy, cut, paste, the two clipboards
/// kept apart, and a drag that lands where the pointer is.
const _serial = 'emulator-5554';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
);

const _device = AndroidDevice(
  serial: _serial,
  environmentId: 'windows',
  state: DeviceConnectionState.device,
);

CommandResult _out(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');

CommandResult _lsOut(String listing) =>
    _out(base64.encode(utf8.encode(listing)));

/// `/sdcard` holding one file and one folder, and `ls -lad` answers for both.
FakeCommandRunner _runner() => FakeCommandRunner(
  responder: (request) {
    final argv = request.arguments;
    final command = argv.last;
    if (argv.contains('pull') || argv.contains('push')) {
      // Both print their summary on stderr with exit 0.
      return CommandResult(
        exitCode: 0,
        stdout: '',
        stderr: '1 file pushed, 0 skipped. 12 bytes in 0.001s',
      );
    }
    if (command.startsWith("ls -la '/sdcard/'")) {
      return _lsOut(
        'total 8\n'
        'drwxrwx--- 2 u0_a1 media_rw 4096 2026-09-07 10:00 Download\n'
        '-rw-rw---- 1 u0_a1 media_rw   12 2026-09-07 10:00 a.txt\n',
      );
    }
    if (command.startsWith("ls -la '/sdcard/Download/'")) {
      return _lsOut('total 0\n');
    }
    if (command.contains("ls -lad '/sdcard'")) {
      return _lsOut(
        'drwxrwx--- 2 u0_a1 media_rw 4096 2026-09-07 10:00 /sdcard',
      );
    }
    if (command.contains("ls -lad '/sdcard/Download'")) {
      return _lsOut(
        'drwxrwx--- 2 u0_a1 media_rw 4096 2026-09-07 10:00 /sdcard/Download',
      );
    }
    if (command.contains("ls -lad '/sdcard/a.txt'")) {
      return _lsOut(
        '-rw-rw---- 1 u0_a1 media_rw 12 2026-09-07 10:00 /sdcard/a.txt',
      );
    }
    if (command.startsWith('ls -lad ')) {
      return _lsOut('ls: x: No such file or directory');
    }
    return _out('');
  },
);

/// Pumps the dialog with a fleet built on [runner] and nothing else real.
Future<void> _pump(
  WidgetTester tester, {
  required FakeCommandRunner runner,
  required FakeHostClipboard host,
  List<String>? directoriesMade,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceFleetProvider.overrideWithValue(
          () async => DeviceFleet(
            adb: AdbService(runner: runner, sdk: _sdk()),
            simctl: null,
            backend: null,
            bootSimulator: (_) async {},
            simulatorIsBusy: (_) => false,
            refreshAndroid: () {},
            refreshSimulators: () {},
          ),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: DeviceFilesDialog(
            device: _device,
            host: host,
            temporaryDirectory: _temp,
            // A real `Directory.create` never completes inside a widget test's
            // FakeAsync zone, and the symptom is `pumpAndSettle timed out`
            // rather than anything about the filesystem.
            makeDirectory: (path) async => directoriesMade?.add(path),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Lets any showing SnackBar finish so the next one in the queue appears.
///
/// `ScaffoldMessenger` shows one at a time and holds the rest behind a four
/// second timer, which `pumpAndSettle` does not advance — it stops as soon as
/// no frame is scheduled. Without this, an assertion about the second message
/// reads the first one and fails for the wrong reason.
Future<void> _nextMessage(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

/// Drags the row named [from] onto the row named [onto].
///
/// Both centres are taken **before** the drag starts, on purpose: once it does,
/// `childWhenDragging` and the feedback both carry the same label, so
/// `find.text` would match three widgets and the gesture would have nowhere
/// unambiguous to go.
Future<void> _drag(
  WidgetTester tester, {
  required String from,
  required String onto,
}) async {
  final start = tester.getCenter(find.text(from));
  final target = tester.getCenter(find.text(onto));
  final gesture = await tester.startGesture(start);
  // Past the drag threshold, which is what starts a `Draggable` — it is not a
  // long press.
  await gesture.moveBy(const Offset(0, 24));
  await tester.pump();
  await gesture.moveTo(target);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// The device command lines that changed something.
List<String> _writes(FakeCommandRunner runner) => runner.requests
    .map((request) => request.arguments.last)
    .where(
      (command) =>
          command.startsWith('cp ') ||
          command.startsWith('mv ') ||
          command.startsWith('rm '),
    )
    .toList();

void main() {
  testWidgets('lists the first root and puts folders before files', (
    tester,
  ) async {
    await _pump(tester, runner: _runner(), host: FakeHostClipboard());
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('a.txt'), findsOneWidget);
    // Nothing is on the clipboard yet, so there is no Paste to press.
    expect(find.byKey(const Key('device-files-paste')), findsNothing);
  });

  testWidgets('cut then paste is one mv on the device, and consumes the cut', (
    tester,
  ) async {
    final runner = _runner();
    await _pump(tester, runner: runner, host: FakeHostClipboard());

    await tester.tap(find.byKey(const Key('device-file-menu-a.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cut on the device'));
    await tester.pumpAndSettle();

    // The button says what it holds, so a Paste pressed later is not a guess.
    expect(find.text('Paste — Cut a.txt'), findsOneWidget);

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-files-paste')));
    await tester.pumpAndSettle();

    expect(_writes(runner), ["mv '/sdcard/a.txt' '/sdcard/Download/a.txt'"]);
    // A cut pasted twice would move a path that is no longer there.
    expect(find.byKey(const Key('device-files-paste')), findsNothing);
  });

  testWidgets('a copy survives its paste, so it can go into several folders', (
    tester,
  ) async {
    final runner = _runner();
    await _pump(tester, runner: runner, host: FakeHostClipboard());

    await tester.tap(find.byKey(const Key('device-file-menu-a.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy on the device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-files-paste')));
    await tester.pumpAndSettle();

    expect(_writes(runner), ["cp -p '/sdcard/a.txt' '/sdcard/Download/a.txt'"]);
    expect(find.text('Paste — Copy a.txt'), findsOneWidget);
  });

  testWidgets('a paste into the folder it came from is refused, not run', (
    tester,
  ) async {
    final runner = _runner();
    await _pump(tester, runner: runner, host: FakeHostClipboard());

    await tester.tap(find.byKey(const Key('device-file-menu-a.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy on the device'));
    await tester.pumpAndSettle();
    await _nextMessage(tester);
    await tester.tap(find.byKey(const Key('device-files-paste')));
    await tester.pumpAndSettle();

    expect(find.textContaining('already in /sdcard'), findsOneWidget);
    expect(_writes(runner), isEmpty);
  });

  testWidgets('dragging a file onto a folder moves it there', (tester) async {
    // The gesture the whole `pointerDragAnchorStrategy` note is about: without
    // it `DragTargetDetails.offset` is the feedback's top-left rather than the
    // pointer, and the drop lands on a row the user was not pointing at.
    final runner = _runner();
    await _pump(tester, runner: runner, host: FakeHostClipboard());

    await _drag(tester, from: 'a.txt', onto: 'Download');

    expect(_writes(runner), ["mv '/sdcard/a.txt' '/sdcard/Download/a.txt'"]);
  });

  testWidgets('a drag leaves the app clipboard alone', (tester) async {
    // A drag is not a cut. Clobbering a held Copy because somebody dragged
    // something would lose work they had queued.
    final runner = _runner();
    await _pump(tester, runner: runner, host: FakeHostClipboard());

    await tester.tap(find.byKey(const Key('device-file-menu-a.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy on the device'));
    await tester.pumpAndSettle();

    await _drag(tester, from: 'a.txt', onto: 'Download');

    expect(find.text('Paste — Copy a.txt'), findsOneWidget);
  });

  testWidgets('"Copy for this computer" stages the file and uses fileSafeId', (
    tester,
  ) async {
    final host = FakeHostClipboard();
    final made = <String>[];
    await _pump(tester, runner: _runner(), host: host, directoriesMade: made);

    await tester.tap(find.byKey(const Key('device-file-menu-a.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy for this computer'));
    await tester.pumpAndSettle();

    final staged = p.join(_temp, 'karmashala-device-files', 'emulator-5554');
    expect(made.single, staged);
    expect(host.filesWritten, hasLength(1));
    expect(host.filesWritten.single.single, p.join(staged, 'a.txt'));
    expect(find.textContaining('paste it anywhere'), findsOneWidget);
  });

  testWidgets('a folder is not offered "Copy for this computer"', (
    tester,
  ) async {
    await _pump(tester, runner: _runner(), host: FakeHostClipboard());
    await tester.tap(find.byKey(const Key('device-file-menu-Download')));
    await tester.pumpAndSettle();
    expect(find.text('Copy for this computer'), findsNothing);
    expect(find.text('Copy on the device'), findsOneWidget);
  });

  testWidgets('"Paste from this computer" pushes the files on the clipboard', (
    tester,
  ) async {
    final runner = _runner();
    await _pump(
      tester,
      runner: runner,
      host: FakeHostClipboard(files: [r'C:\Users\x\Desktop\shot.png']),
    );

    await tester.tap(find.byKey(const Key('device-files-paste-from-host')));
    await tester.pumpAndSettle();

    expect(
      runner.requests.any(
        (request) =>
            request.arguments.contains('push') &&
            request.arguments.contains(r'C:\Users\x\Desktop\shot.png'),
      ),
      isTrue,
    );
    expect(find.textContaining('Copied shot.png'), findsOneWidget);
  });

  testWidgets('an adb that cannot run clears the busy state and says so', (
    tester,
  ) async {
    // Only DeviceRefusal used to be caught; a CommandException left `_busy`
    // set and every control disabled until the dialog was closed.
    final runner = _runner();
    await _pump(tester, runner: runner, host: FakeHostClipboard());
    runner.throwError = CommandException('adb.exe vanished');

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();

    expect(find.byType(InlineSpinner), findsNothing);
    expect(find.textContaining('adb could not be run'), findsOneWidget);
    expect(find.textContaining('Not permitted'), findsOneWidget);
    // The Up button is live again: the dialog is not wedged.
    runner.throwError = null;
    await tester.tap(find.byKey(const Key('device-files-up')));
    await tester.pumpAndSettle();
    expect(find.text('a.txt'), findsOneWidget);
  });

  testWidgets('an adb that cannot run mid-paste clears the busy state', (
    tester,
  ) async {
    final runner = _runner();
    await _pump(tester, runner: runner, host: FakeHostClipboard());
    await tester.tap(find.byKey(const Key('device-file-menu-a.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cut on the device'));
    await tester.pumpAndSettle();
    await _nextMessage(tester);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    runner.throwError = CommandException('adb.exe vanished');

    await tester.tap(find.byKey(const Key('device-files-paste')));
    await tester.pumpAndSettle();

    expect(find.byType(InlineSpinner), findsNothing);
    expect(find.textContaining('adb could not be run'), findsOneWidget);
  });

  testWidgets('an empty file clipboard says so rather than failing', (
    tester,
  ) async {
    // The usual reason is that what was copied was text, and "paste failed"
    // sends the user looking at the phone instead of at their own clipboard.
    await _pump(tester, runner: _runner(), host: FakeHostClipboard());
    await tester.tap(find.byKey(const Key('device-files-paste-from-host')));
    await tester.pumpAndSettle();
    expect(find.textContaining('no files on this computer'), findsOneWidget);
  });
}
