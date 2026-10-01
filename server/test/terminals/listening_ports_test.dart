import 'dart:io';

import 'package:karmashala_host/src/terminals/listening_ports.dart';
import 'package:test/test.dart';

PaneRoot _pane(int pid, String title) => (
  pid: pid,
  paneId: 'pane-$pid',
  terminalSessionId: 't-$pid',
  title: title,
  agentSessionId: null,
);

ListeningPortProbe _probe(String output) => ListeningPortProbe(
  windows: true,
  run: (_, _) async => ProcessResult(1, 0, output, ''),
  clock: () => DateTime.utc(2026, 10, 1),
);

void main() {
  test('the probe line carries creation time before the name', () {
    final parsed = parseProbeLines(
      'P 10 4 1000 pwsh.exe\n'
      'P 0 0 0 System Idle Process\n'
      'L 5173 10 127.0.0.1\n',
    );
    expect(parsed.processes.first, (
      pid: 10,
      parent: 4,
      name: 'pwsh.exe',
      created: 1000,
    ));
    expect(parsed.processes.last.name, 'System Idle Process');
    expect(parsed.processes.last.created, isNull);
    expect(parsed.sockets.single.port, 5173);
  });

  test('a process older than its parent pid is not that pid\'s child', () {
    final owners = descendantsOf(
      [10],
      [
        (pid: 10, parent: 1, name: 'pwsh.exe', created: 500),
        (pid: 11, parent: 10, name: 'node.exe', created: 600),
        // Started before pid 10 existed: its own parent was an earlier 10.
        (pid: 12, parent: 10, name: 'old.exe', created: 100),
      ],
    );
    expect(owners.keys, unorderedEquals([10, 11]));
  });

  test('without creation times, the parent pid is trusted', () {
    final owners = descendantsOf(
      [10],
      [
        (pid: 10, parent: 1, name: 'bash', created: null),
        (pid: 11, parent: 10, name: 'node', created: null),
      ],
    );
    expect(owners.keys, unorderedEquals([10, 11]));
  });

  test('a pane that started wsl.exe is not read, not empty', () async {
    final reading = await _probe(
      'P 10 1 500 pwsh.exe\n'
      'P 11 10 600 wsl.exe\n'
      'P 20 1 500 pwsh.exe\n'
      'P 21 20 600 node.exe\n'
      'L 3000 21 127.0.0.1\n',
    ).read([_pane(10, 'Linux shell'), _pane(20, 'Windows shell')]);

    expect(reading.ports.single.port, 3000);
    expect(reading.unread.single, contains('"Linux shell" runs in WSL'));
  });
}
