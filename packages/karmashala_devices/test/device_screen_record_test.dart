import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_command_runner.dart';

/// Slice 5b: a server records its own machine's Android devices with the
/// device's own `screenrecord` — no live view, no pane — stopped by an
/// interrupt, pulled to this machine and removed from the device.
void main() {
  late Directory directory;
  late FakeCommandRunner runner;
  late FakeProcessHandle screenrecord;
  late AdbService adb;
  late DeviceRecorder recorder;

  final target = AndroidTarget(
    const AndroidDevice(
      serial: 'emulator-5554',
      environmentId: 'local',
      state: DeviceConnectionState.device,
    ),
  );

  List<String> argv(CommandRequest request) => request.arguments;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('screenrecord_');
    screenrecord = FakeProcessHandle();
    runner = FakeCommandRunner(processFactory: (_) => screenrecord);
    adb = AdbService(
      runner: runner,
      sdk: const AndroidSdk(
        root: EnvironmentPath(environmentId: 'local', path: '/sdk'),
        adb: EnvironmentPath(environmentId: 'local', path: '/sdk/adb'),
      ),
    );
    recorder = DeviceRecorder(
      clock: const SystemClock(),
      recordingDirectory: () async => directory.path,
      simctl: () => null,
    );
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('starts screenrecord on the device, and a stop interrupts it, pulls '
      'the file and removes it there', () async {
    runner.responder = (request) {
      final args = argv(request);
      if (args.contains('pull')) {
        File(args.last).writeAsBytesSync(List.filled(64, 1));
        // `stop` waits for the device process to exit before pulling.
        return const CommandResult(
          exitCode: 0,
          stdout: '/data/local/tmp/x.mp4: 1 file pulled',
          stderr: '',
        );
      }
      if (args.contains('pkill')) screenrecord.complete(0);
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    };

    await recorder.startScreenRecord(target, adb);
    final active = recorder.state as DeviceRecordingActive;
    final start = argv(runner.startRequests.single);
    expect(start.take(4), ['-s', 'emulator-5554', 'shell', 'screenrecord']);
    final devicePath = start.last;
    expect(devicePath, startsWith('/data/local/tmp/karmashala-'));

    await recorder.stop();

    final ran = [for (final request in runner.requests) argv(request)];
    expect(ran[0], [
      '-s',
      'emulator-5554',
      'shell',
      'pkill',
      '-INT',
      'screenrecord',
    ]);
    expect(ran[1], ['-s', 'emulator-5554', 'pull', devicePath, active.path]);
    expect(ran[2].take(3), ['-s', 'emulator-5554', 'shell']);
    expect(ran[2].last, contains('rm'));
    final idle = recorder.state as DeviceRecordingIdle;
    expect(idle.last?.result, DeviceRecordingResult.saved);
    expect(idle.last?.path, active.path);
    expect(p.extension(active.path), '.mp4');
    expect(File(active.path).lengthSync(), 64);
  });

  test('screenrecord ending on its own (its time limit) is an early end, '
      'with what it captured, and nothing is interrupted', () async {
    runner.responder = (request) {
      final args = argv(request);
      if (args.contains('pull')) {
        File(args.last).writeAsBytesSync(List.filled(8, 1));
        return const CommandResult(
          exitCode: 0,
          stdout: '1 file pulled',
          stderr: '',
        );
      }
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    };
    await recorder.startScreenRecord(target, adb);
    screenrecord.complete(0);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final idle = recorder.state as DeviceRecordingIdle;
    expect(idle.last?.result, DeviceRecordingResult.saved);
    expect(idle.last?.message, contains('180 seconds'));
    expect(
      runner.requests.any((request) => argv(request).contains('pkill')),
      isFalse,
    );
  });

  test('a pull that fails leaves no file and says why', () async {
    runner.responder = (request) {
      final args = argv(request);
      if (args.contains('pull')) {
        return const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'adb: error: remote object does not exist',
        );
      }
      if (args.contains('pkill')) screenrecord.complete(0);
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    };
    await recorder.startScreenRecord(target, adb);
    final active = recorder.state as DeviceRecordingActive;
    await recorder.stop();
    final idle = recorder.state as DeviceRecordingIdle;
    expect(idle.last?.result, DeviceRecordingResult.failed);
    expect(idle.last?.message, contains('does not exist'));
    expect(File(active.path).existsSync(), isFalse);
  });
}
