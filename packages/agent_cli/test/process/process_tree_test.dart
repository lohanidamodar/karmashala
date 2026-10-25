import 'dart:async';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:test/test.dart';

void main() {
  group('an IoProcessHandle that ends its tree', () {
    test(
      'closes stdin first and kills nothing when the process leaves',
      () async {
        final process = _FakeProcess(exitsOnEof: true);
        final killer = _RecordingKiller(process);
        final handle = IoProcessHandle(
          process,
          endsTree: true,
          grace: const Duration(seconds: 2),
          treeKiller: killer,
        );

        await handle.kill();

        expect(process.events, ['stdin closed', 'exited']);
        expect(killer.killed, isEmpty);
      },
    );

    test('kills the whole tree only after the grace has passed', () async {
      final process = _FakeProcess(exitsOnEof: false);
      final killer = _RecordingKiller(process);
      final handle = IoProcessHandle(
        process,
        endsTree: true,
        grace: const Duration(milliseconds: 200),
        treeKiller: killer,
      );

      final started = DateTime.now();
      await handle.kill();

      expect(process.events, ['stdin closed', 'tree killed', 'exited']);
      expect(killer.killed, [process.pid]);
      expect(
        DateTime.now().difference(started),
        greaterThanOrEqualTo(const Duration(milliseconds: 200)),
      );
      // Never the top process alone.
      expect(process.signals, isEmpty);
    });

    test('kills the top process itself when the tree kill misses it', () async {
      final process = _FakeProcess(exitsOnEof: false);
      final handle = IoProcessHandle(
        process,
        endsTree: true,
        grace: const Duration(milliseconds: 50),
        treeKiller: _FailingKiller(),
      );

      await handle.kill();

      expect(process.signals, [ProcessSignal.sigkill]);
    });

    test('without the flag, kill is the top process alone, at once', () async {
      final process = _FakeProcess(exitsOnEof: false, exitsOnSignal: true);
      final killer = _RecordingKiller(process);
      await IoProcessHandle(process, treeKiller: killer).kill();

      expect(killer.killed, isEmpty);
      expect(process.events, isNot(contains('stdin closed')));
      expect(process.signals, [ProcessSignal.sigterm]);
    });
  });

  test('descendants come leaves first, and a cycle ends', () {
    expect(
      descendantsLeavesFirst(1, {
        1: [2, 3],
        2: [4],
        4: [1],
      }),
      [4, 2, 3],
    );
  });

  test('the system killer ends a child the top process started', () async {
    final top = await Process.start('cmd.exe', [
      '/c',
      'ping -n 60 127.0.0.1 >NUL',
    ]);
    final child = await _childOf(top.pid);
    expect(child, isNotNull, reason: 'ping should be running under cmd');

    await const SystemProcessTreeKiller().killTree(top.pid);
    await top.exitCode.timeout(const Duration(seconds: 10));

    expect(await _alive(child!), isFalse);
  }, skip: Platform.isWindows ? false : 'taskkill is Windows only');
}

Future<int?> _childOf(int parent) async {
  for (var i = 0; i < 20; i++) {
    final listed = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      '(Get-CimInstance Win32_Process -Filter "ParentProcessId=$parent" | '
          "Where-Object Name -eq 'PING.EXE').ProcessId",
    ]);
    final pid = int.tryParse('${listed.stdout}'.trim());
    if (pid != null) return pid;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return null;
}

Future<bool> _alive(int pid) async {
  final listed = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH']);
  return '${listed.stdout}'.contains('$pid');
}

class _RecordingKiller implements ProcessTreeKiller {
  _RecordingKiller(this.process);
  final _FakeProcess process;
  final killed = <int>[];

  @override
  Future<void> killTree(int pid) async {
    killed.add(pid);
    process.events.add('tree killed');
    process.exit(1);
  }
}

class _FailingKiller implements ProcessTreeKiller {
  @override
  Future<void> killTree(int pid) async => throw StateError('no taskkill');
}

class _FakeProcess implements Process {
  _FakeProcess({required this.exitsOnEof, this.exitsOnSignal = false}) {
    _stdin.stream.listen(
      (_) {},
      onDone: () {
        events.add('stdin closed');
        if (exitsOnEof) exit(0);
      },
    );
  }

  final bool exitsOnEof;
  final bool exitsOnSignal;
  final events = <String>[];
  final signals = <ProcessSignal>[];
  final _exit = Completer<int>();
  final _stdin = StreamController<List<int>>();
  late final IOSink _sink = IOSink(_stdin.sink);

  void exit(int code) {
    if (_exit.isCompleted) return;
    events.add('exited');
    _exit.complete(code);
  }

  @override
  int get pid => 4242;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  IOSink get stdin => _sink;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    if (exitsOnSignal || signal == ProcessSignal.sigkill) exit(137);
    return true;
  }
}
