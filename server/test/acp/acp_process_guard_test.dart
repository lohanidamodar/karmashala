import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_host/src/acp/acp_process_guard.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Each agent is tied to the server's life, and the next start ends only
/// the agents it can prove a previous server started: PID and start time.
void main() {
  late Directory dir;
  late String registry;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('acp_guard');
    registry = p.join(dir.path, 'acp_processes.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<IoProcessHandle> sleeper() async => IoProcessHandle(
    await Process.start(
      Platform.isWindows ? 'ping' : 'sleep',
      Platform.isWindows ? ['-n', '30', '127.0.0.1'] : ['30'],
    ),
  );

  test(
    'a started agent is contained and recorded, and forgotten on exit',
    () async {
      final system = _FakeSystem();
      final guard = AcpProcessGuard(registryFile: registry, system: system);
      final handle = await sleeper();
      addTearDown(() => Process.killPid(handle.pid, ProcessSignal.sigkill));
      system.started[handle.pid] = 1111;

      guard.adopt(handle);

      expect(system.contained, [handle.pid]);
      expect(File(registry).readAsStringSync(), contains('${handle.pid}'));

      Process.killPid(handle.pid, ProcessSignal.sigkill);
      await handle.exitCode;
      await Future<void>.delayed(Duration.zero);
      expect(File(registry).readAsStringSync(), '[]');
    },
  );

  test('the next start ends only what it can prove is its own', () async {
    File(registry).writeAsStringSync(
      '[{"pid":10,"started":500},{"pid":11,"started":600},'
      '{"pid":12,"started":700}]',
    );
    final system = _FakeSystem()
      // 10: still the same process. 11: the PID now belongs to another
      // process. 12: gone.
      ..started.addAll({10: 500, 11: 999});

    final reaped = AcpProcessGuard(
      registryFile: registry,
      system: system,
    ).reapStale();

    expect(reaped, [10]);
    expect(system.killed, [10]);
    expect(File(registry).readAsStringSync(), '[]');
  });

  test('a handle that is not a local process is left alone', () {
    final system = _FakeSystem();
    AcpProcessGuard(registryFile: registry, system: system).adopt(_NotLocal());
    expect(system.contained, isEmpty);
    expect(File(registry).existsSync(), isFalse);
  });

  test(
    'on Windows, a real process joins the job and its tree is ended',
    () async {
      final system = WindowsAcpProcessSystem();
      final top = await Process.start('cmd.exe', [
        '/c',
        'ping -n 30 127.0.0.1 >NUL',
      ]);
      addTearDown(() async {
        await Process.run('taskkill', ['/PID', '${top.pid}', '/T', '/F']);
      });
      expect(system.contain(top.pid), isTrue);
      expect(system.startedAt(top.pid), isNotNull);
      system.killTree(top.pid);
      await top.exitCode.timeout(const Duration(seconds: 10));
      expect(system.startedAt(top.pid), isNull);
    },
    skip: Platform.isWindows ? false : 'job objects are Windows only',
  );
}

class _FakeSystem implements AcpProcessSystem {
  final started = <int, int>{};
  final contained = <int>[];
  final killed = <int>[];

  @override
  bool contain(int pid) {
    contained.add(pid);
    return true;
  }

  @override
  int? startedAt(int pid) => started[pid];

  @override
  void killTree(int pid) => killed.add(pid);
}

class _NotLocal implements ProcessHandle {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
