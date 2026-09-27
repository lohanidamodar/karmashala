import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
import 'package:karmashala_host/src/domain/session_registry.dart';
import 'package:karmashala_host/src/mcp/tools/recording_tool_set.dart';
import 'package:karmashala_host/src/pty/fake_pty.dart';
import 'package:karmashala_host/src/terminals/server_terminals.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Recordings in the server (slice 5b): a terminal's is an asciicast written
/// from the session's own bytes — never a video pretended — and a device's
/// is made by the device's own recorder on the server's machine.
void main() {
  late Directory directory;
  late FakePtyLauncher launcher;
  late SessionRegistry registry;
  late ServerTerminals terminals;
  late _Runner runner;
  late List<DeviceTarget> ready;
  late Set<String> held;
  late RecordingToolSet tools;

  AndroidTarget android(String serial) => AndroidTarget(
    AndroidDevice(
      serial: serial,
      environmentId: 'local',
      state: DeviceConnectionState.device,
    ),
  );

  setUp(() {
    directory = Directory.systemTemp.createTempSync('recordings_');
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher, hostname: 'this-mac');
    terminals = ServerTerminals(
      registry: registry,
      environments: () => const [],
      tell: (_) {},
      hostEnvironment: const {'SHELL': '/bin/zsh'},
      installedShells: () => const ['/bin/zsh'],
      windows: false,
      settle: Duration.zero,
    );
    runner = _Runner();
    ready = [android('emulator-5554')];
    held = {};
    tools = RecordingToolSet(
      terminals: terminals,
      registry: registry,
      recordingsDirectory: directory.path,
      readyDevices: () async => ready,
      heldBy: (_) => held,
      adb: () async => AdbService(
        runner: runner,
        sdk: const AndroidSdk(
          root: EnvironmentPath(environmentId: 'local', path: '/sdk'),
          adb: EnvironmentPath(environmentId: 'local', path: '/sdk/adb'),
        ),
      ),
    );
  });

  tearDown(() async {
    await tools.close();
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await terminals.dispose();
    directory.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> call(
    String tool, [
    Map<String, dynamic> arguments = const {},
    String? caller,
  ]) async =>
      (await tools.call(tool, arguments, caller))! as Map<String, Object?>;

  group('a terminal', () {
    test('is recorded from its own bytes as an asciicast, and the answer '
        'says no video was made', () async {
      terminals.open(const TerminalOpen(paneId: 'p1', columns: 90, rows: 30));
      final pty = launcher.handles.single;
      pty.emit(utf8.encode('before\r\n'));
      await pumpEventQueue();

      final started = await call('terminal_record_start', {'paneId': 'p1'});
      expect(started['recording'], 'p1');
      pty.emit(utf8.encode('héllo\r\n'));
      pty.emit([0xe2, 0x9c]);
      pty.emit([0x93, 0x0d, 0x0a]);
      await pumpEventQueue();

      final stopped = await call('terminal_record_stop', {
        'paneId': 'p1',
        'format': 'mp4',
      });
      expect(stopped['format'], 'cast');
      expect(stopped['isVideo'], isFalse);
      expect(stopped['note'], contains('mp4 was NOT produced'));
      final file = File(stopped['file']! as String);
      expect(p.extension(file.path), '.cast');
      expect(p.dirname(file.path), directory.path);
      final lines = file.readAsLinesSync();
      final header = jsonDecode(lines.first) as Map;
      expect(header['version'], 2);
      expect((header['width'], header['height']), (90, 30));
      final text = [
        for (final line in lines.skip(1)) (jsonDecode(line) as List)[2],
      ].join();
      expect(text, 'héllo\r\n✓\r\n');
      expect(text, isNot(contains('before')));
    });

    test(
      'an unknown pane, a second stop and a bad format are refused',
      () async {
        await expectLater(
          call('terminal_record_start', {'paneId': 'nope'}),
          throwsA(isA<ArgumentError>()),
        );
        terminals.open(const TerminalOpen(paneId: 'p1', columns: 80, rows: 24));
        await call('terminal_record_start', {'paneId': 'p1'});
        await expectLater(
          call('terminal_record_stop', {'paneId': 'p1', 'format': 'webm'}),
          throwsA(isA<ArgumentError>()),
        );
        await call('terminal_record_stop', {'paneId': 'p1'});
        await expectLater(
          call('terminal_record_stop', {'paneId': 'p1'}),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  group('a device', () {
    test('an Android device records itself with screenrecord; stop pulls '
        'the MP4 here', () async {
      final started = await call('device_record_start');
      expect(started['recording'], 'emulator-5554');
      expect(started['note'], contains('180'));
      expect(runner.started.single.arguments.take(4), [
        '-s',
        'emulator-5554',
        'shell',
        'screenrecord',
      ]);
      final stopped = await call('device_record_stop');
      expect(stopped['result'], 'saved');
      expect(stopped['isVideo'], isTrue);
      final file = File(stopped['file']! as String);
      expect(file.existsSync(), isTrue);
      expect(p.extension(file.path), '.mp4');
    });

    test(
      'with several ready, the one this session holds is recorded',
      () async {
        ready = [android('A'), android('B')];
        held = {'B'};
        final started = await call('device_record_start', const {}, 's1');
        expect(started['recording'], 'B');
      },
    );

    test(
      'with several ready and none held, it is refused listing them',
      () async {
        ready = [android('A'), android('B')];
        await expectLater(
          call('device_record_start'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('A, B'),
            ),
          ),
        );
      },
    );

    test(
      'with none ready, or asked for MPEG-TS, it is refused in words',
      () async {
        await expectLater(
          call('device_record_start', {'format': 'ts'}),
          throwsA(isA<StateError>()),
        );
        ready = [];
        await expectLater(
          call('device_record_start'),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          call('device_record_stop'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'No device recording is running.',
            ),
          ),
        );
      },
    );
  });
}

/// adb, as far as a device recording asks it: `screenrecord` runs until an
/// interrupt, a pull writes the file it names.
class _Runner implements CommandRunner {
  final started = <CommandRequest>[];
  _Process? _screenrecord;

  @override
  String get environmentId => 'local';

  @override
  Future<CommandResult> run(CommandRequest request) async {
    final args = request.arguments;
    if (args.contains('pkill')) _screenrecord?.end(0);
    if (args.contains('pull')) {
      File(args.last).writeAsBytesSync(List.filled(32, 7));
      return const CommandResult(
        exitCode: 0,
        stdout: '1 file pulled',
        stderr: '',
      );
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) async {
    started.add(request);
    return _screenrecord = _Process();
  }
}

class _Process implements ProcessHandle {
  final _exit = Completer<int>();

  void end(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Stream<String> get stdoutLines => const Stream.empty();

  @override
  Stream<List<int>> get stdoutBytes => const Stream.empty();

  @override
  Stream<String> get stderrLines => const Stream.empty();

  @override
  void writeLine(String line) {}

  @override
  Future<void> closeStdin() async {}

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> interrupt() async => end(0);

  @override
  Future<void> kill() async => end(-9);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
