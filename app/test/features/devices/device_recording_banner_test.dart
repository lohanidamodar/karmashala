// The banner is the whole of "a recording is visible and stoppable". It reads
// a provider rather than pane state on purpose, so it is tested the same way:
// by putting a recording in the provider and rebuilding the widget from
// scratch, which is what a pane switch does.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/devices/application/device_bindings.dart';
import 'package:karmashala/src/app/shell/reveal_in_file_manager.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_device_pane/providers.dart';
import 'package:karmashala_device_pane/widgets.dart';

import '../../support/fake_command_runner.dart';

AndroidDevice _device([
  String serial = 'emulator-5554',
  DeviceConnectionState state = DeviceConnectionState.device,
]) => AndroidDevice(serial: serial, environmentId: 'windows', state: state);

AndroidTarget _target([String serial = 'emulator-5554']) =>
    AndroidTarget(_device(serial));

/// A recorder whose state the test sets directly. The controller's own
/// behaviour is covered by `device_recording_controller_test.dart`; what is
/// under test here is what the banner says about it.
class _StubRecorder extends DeviceRecordingController {
  _StubRecorder(this.initial);

  final DeviceRecordingState initial;
  int stops = 0;
  int dismissals = 0;

  @override
  DeviceRecordingState build() => initial;

  @override
  Future<void> stop() async => stops++;

  @override
  void dismiss() => dismissals++;
}

Future<_StubRecorder> _pump(
  WidgetTester tester,
  DeviceRecordingState state, {
  List<AndroidDevice> devices = const [],
}) async {
  final recorder = _StubRecorder(state);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // The app's half of `karmashala_devices`: its clock, its runner
        // factory, its settings and its shell, behind the package's ports.
        ...deviceBindings,
        deviceRecordingProvider.overrideWith(() => recorder),
        devicesProvider.overrideWith((ref) async => devices),
        // Composed by hand rather than left to the app's provider, which
        // resolves an environment out of the database. Pinned to Windows so
        // "can this path be shown" is the same answer on every host the suite
        // runs on.
        revealInFileManagerProvider.overrideWithValue(
          RevealInFileManager(
            host: FakeCommandRunner(),
            translator: const PathTranslator(),
            environmentFor: (_) => windowsHostEnvironment(DateTime.utc(2026)),
            fileManagerOverride: HostFileManager.windowsExplorer,
          ),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: DeviceRecordingBanner())),
    ),
  );
  await tester.pumpAndSettle();
  return recorder;
}

void main() {
  testWidgets('says nothing when nothing has been recorded', (tester) async {
    await _pump(tester, const DeviceRecordingIdle());
    expect(find.byKey(const Key('device-recording-stop')), findsNothing);
    expect(find.textContaining('Recording'), findsNothing);
  });

  testWidgets('a running recording names the device and the file', (
    tester,
  ) async {
    await _pump(
      tester,
      DeviceRecordingActive(
        target: _target(),
        path: r'C:\data\recordings\emulator-5554-20260908-140307.ts',
        startedAt: DateTime.utc(2026, 9, 8, 14, 3, 7),
      ),
      devices: [_device()],
    );

    expect(find.textContaining('Recording emulator-5554'), findsOneWidget);
    expect(
      find.textContaining(r'C:\data\recordings\emulator-5554'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('device-recording-stop')), findsOneWidget);
  });

  testWidgets('Stop asks the recorder to stop', (tester) async {
    final recorder = await _pump(
      tester,
      DeviceRecordingActive(
        target: _target(),
        path: '/rec/a.ts',
        startedAt: DateTime.utc(2026),
      ),
      devices: [_device()],
    );

    await tester.tap(find.byKey(const Key('device-recording-stop')));
    await tester.pumpAndSettle();

    expect(recorder.stops, 1);
  });

  testWidgets('a paused recording says the live view is off, not that it is '
      'recording', (tester) async {
    await _pump(
      tester,
      DeviceRecordingActive(
        target: _target(),
        path: '/rec/a.ts',
        startedAt: DateTime.utc(2026),
        receiving: false,
      ),
      devices: [_device()],
    );

    expect(find.textContaining('paused'), findsOneWidget);
    expect(
      find.textContaining('resumes when the live view comes back'),
      findsOneWidget,
    );
  });

  testWidgets('a device that has gone is a different sentence from a pane '
      'that was switched away from', (tester) async {
    await _pump(
      tester,
      DeviceRecordingActive(
        target: _target(),
        path: '/rec/a.ts',
        startedAt: DateTime.utc(2026),
        receiving: false,
      ),
    );

    expect(
      find.textContaining('emulator-5554 is no longer connected'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Stop the recording to keep what was captured'),
      findsOneWidget,
    );
  });

  testWidgets('an unauthorized device says which state it is in', (
    tester,
  ) async {
    await _pump(
      tester,
      DeviceRecordingActive(
        target: _target(),
        path: '/rec/a.ts',
        startedAt: DateTime.utc(2026),
        receiving: false,
      ),
      devices: [_device('emulator-5554', DeviceConnectionState.unauthorized)],
    );

    expect(find.textContaining('is unauthorized'), findsOneWidget);
  });

  testWidgets('a finished recording is still on screen after the pane came '
      'back', (tester) async {
    final recorder = await _pump(
      tester,
      DeviceRecordingIdle(
        DeviceRecordingOutcome.saved(
          target: _target(),
          path: r'C:\rec\a.ts',
          bytes: 4404019,
          length: const Duration(seconds: 12),
        ),
      ),
    );

    expect(
      find.textContaining(r'Recording saved to C:\rec\a.ts'),
      findsOneWidget,
    );
    expect(find.textContaining('4.2 MB over 12s'), findsOneWidget);
    expect(find.byKey(const Key('device-recording-reveal')), findsOneWidget);

    await tester.tap(find.byKey(const Key('device-recording-dismiss')));
    await tester.pumpAndSettle();
    expect(recorder.dismissals, 1);
  });

  testWidgets('a recording that captured nothing offers no file to show', (
    tester,
  ) async {
    await _pump(
      tester,
      DeviceRecordingIdle(
        DeviceRecordingOutcome.empty(
          target: _target(),
          reason: 'no frames arrived',
        ),
      ),
    );

    expect(find.textContaining('Nothing was recorded'), findsOneWidget);
    expect(find.byKey(const Key('device-recording-reveal')), findsNothing);
  });

  testWidgets('a write that ran out of disk says so, and keeps the file', (
    tester,
  ) async {
    await _pump(
      tester,
      DeviceRecordingIdle(
        DeviceRecordingOutcome.writeFailed(
          target: _target(),
          path: '/rec/a.ts',
          reason: 'FileSystemException: There is not enough space on the disk',
          bytes: 3145728,
        ),
      ),
    );

    expect(find.textContaining('not enough space'), findsOneWidget);
    expect(find.textContaining('3.0 MB was saved before it'), findsOneWidget);
  });
}
