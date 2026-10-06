import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/terminals/listening_ports.dart';
import 'package:test/test.dart';

/// The server at 100, a pane's shell at 10 running node at 11 (port 5173,
/// bound twice), an adb server at 50 forwarding 27183, and an unrelated
/// process at 70.
const _windowsListing =
    'P 100 1 100 karmashala_host.exe\n'
    'P 10 100 200 pwsh.exe\n'
    'P 11 10 300 node.exe\n'
    'P 12 11 400 esbuild.exe\n'
    'P 50 1 50 adb.exe\n'
    'P 70 1 70 other.exe\n'
    'L 47821 100 127.0.0.1\n'
    'L 47999 100 127.0.0.1\n'
    'L 5173 11 127.0.0.1\n'
    'L 5173 11 ::1\n'
    'L 27183 50 127.0.0.1\n'
    'L 9999 70 0.0.0.0\n';

const RunningPaneRoot _pane = (
  pid: 10,
  paneId: 'p1',
  terminalSessionId: 'karmashala_s1',
  title: 'Fix the build',
  agentSessionId: 's1',
  environmentId: null,
  command: 'npm run dev',
);

void main() {
  late List<List<String>> ran;

  ListeningPortProbe probe({String listing = _windowsListing}) {
    ran = [];
    return ListeningPortProbe(
      windows: true,
      run: (executable, arguments) async {
        ran.add([executable, ...arguments]);
        return ProcessResult(1, 0, listing, '');
      },
      clock: () => DateTime.utc(2026, 10, 6),
    );
  }

  RunningProcess byPid(RunningReading reading, int pid) =>
      reading.processes.singleWhere((p) => p.pid == pid);

  test(
    'the server, a pane, its children and device mirroring, owned',
    () async {
      final reading = await probe().running(
        [_pane],
        serverPid: 100,
        serverPorts: const {47821: 'MCP endpoint'},
      );
      expect(reading.serverPid, 100);

      final server = byPid(reading, 100);
      expect(server.role, RunningRole.server);
      expect(server.stoppable, isFalse);
      expect(
        {for (final port in server.ports) port.port: port.label},
        {47821: 'MCP endpoint', 47999: null},
      );

      final shell = byPid(reading, 10);
      expect(shell.role, RunningRole.pane);
      expect(shell.stoppable, isFalse, reason: 'a root ends with its pane');
      expect(shell.command, 'npm run dev');

      final node = byPid(reading, 11);
      expect(node.role, RunningRole.child);
      expect(node.stoppable, isTrue);
      expect(node.agentSessionId, 's1');
      expect(node.paneId, 'p1');
      expect(node.ports.map((p) => p.port), [
        5173,
      ], reason: 'v4 and v6 are one');
      expect(byPid(reading, 12).role, RunningRole.child);

      final adb = byPid(reading, 50);
      expect(adb.role, RunningRole.device);
      expect(adb.stoppable, isFalse);
      expect(adb.ports.single.port, 27183);

      expect(reading.processes.where((p) => p.pid == 70), isEmpty);
    },
  );

  test('panes it cannot list are kept, with a note on their machine', () async {
    final reading = await probe().running(
      [],
      serverPid: 100,
      unlisted: const [
        RunningProcess(
          pid: 0,
          parent: 0,
          role: RunningRole.pane,
          title: 'box',
          environmentId: 'ssh:h1',
        ),
      ],
      notes: const [
        RunningNote('"box" runs on an SSH machine.', environmentId: 'ssh:h1'),
      ],
    );
    expect(
      reading.processes.where((p) => p.environmentId == 'ssh:h1'),
      hasLength(1),
    );
    expect(reading.notes.single.environmentId, 'ssh:h1');
  });

  test('a failed listing is said, and the panes still listed', () async {
    final reading = await probe(listing: '').running([_pane], serverPid: 100);
    expect(byPid(reading, 10).role, RunningRole.pane);
    expect(reading.notes, isNotEmpty);
  });

  test('stopping ends a child and its tree', () async {
    final ports = probe();
    await ports.stop(11, [_pane], serverPid: 100);
    expect(ran.last, ['taskkill', '/PID', '11', '/T', '/F']);
  });

  test('the server, a pane root and a stranger are refused', () async {
    final ports = probe();
    for (final pid in [100, 10, 70, 4242]) {
      await expectLater(
        ports.stop(pid, [_pane], serverPid: 100),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.denied,
          ),
        ),
        reason: 'pid $pid',
      );
    }
    expect(ran.where((argv) => argv.first == 'taskkill'), isEmpty);
  });
}
