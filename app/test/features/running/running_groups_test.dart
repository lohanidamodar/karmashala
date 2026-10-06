import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/running/domain/running_groups.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

final _reading = RunningReading(
  serverPid: 1,
  checkedAt: DateTime.utc(2026, 10, 6),
  processes: const [
    RunningProcess(pid: 1, parent: 0, role: RunningRole.server),
    RunningProcess(
      pid: 10,
      parent: 1,
      role: RunningRole.pane,
      paneId: 'p1',
      title: 'Fix the build',
      agentSessionId: 's1',
    ),
    RunningProcess(
      pid: 11,
      parent: 10,
      role: RunningRole.child,
      paneId: 'p1',
      title: 'Fix the build',
      agentSessionId: 's1',
      stoppable: true,
      ports: [RunningPort(port: 5173, address: '::1')],
    ),
    RunningProcess(
      pid: 20,
      parent: 1,
      role: RunningRole.pane,
      paneId: 'p2',
      title: 'ubuntu',
      environmentId: 'wsl:Ubuntu',
    ),
    RunningProcess(
      pid: 0,
      parent: 0,
      role: RunningRole.pane,
      paneId: 'p3',
      title: 'box',
      agentSessionId: 's2',
      environmentId: 'ssh:h1',
    ),
    RunningProcess(
      pid: 50,
      parent: 1,
      role: RunningRole.device,
      name: 'adb.exe',
    ),
  ],
  notes: const [
    RunningNote('box is not read', environmentId: 'ssh:h1'),
    RunningNote('the lists could not be read'),
  ],
);

void main() {
  test('each process is filed under its machine, this one first', () {
    final machines = groupByMachine(_reading, localEnvironmentId: 'windows');
    expect(machines.map((m) => m.environmentId), [
      'windows',
      'wsl:Ubuntu',
      'ssh:h1',
    ]);

    final here = machines.first;
    expect(here.server?.pid, 1);
    expect(here.devices.single.pid, 50);
    expect(here.panes.single.paneId, 'p1');
    expect(here.panes.single.processes.map((p) => p.pid), [10, 11]);
    expect(here.notes.single.text, 'the lists could not be read');

    expect(machines[1].server, isNull);
    expect(machines[1].panes.single.title, 'ubuntu');
    expect(machines[2].notes.single.text, 'box is not read');
  });

  test('a machine filter keeps one machine; a session filter one session', () {
    expect(
      groupByMachine(
        _reading,
        localEnvironmentId: 'windows',
        environmentId: 'wsl:Ubuntu',
      ).map((m) => m.environmentId),
      ['wsl:Ubuntu'],
    );
    final one = groupByMachine(
      _reading,
      localEnvironmentId: 'windows',
      sessionId: 's1',
    );
    expect(one, hasLength(1));
    expect(one.single.panes.single.agentSessionId, 's1');
    expect(one.single.server, isNull, reason: 'the server is no session\'s');
    expect(one.single.devices, isEmpty);
  });

  test('a session\'s port count is what its panes listen on', () {
    expect(portsOfSession(_reading, 's1').map((p) => p.port.port), [5173]);
    expect(portsOfSession(_reading, 's2'), isEmpty);
  });
}
