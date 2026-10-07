import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// What the Running tab reads (`terminals.running`) and the one act it asks
/// for (`terminals.stopProcess`), through the envelope as JSON text.
void main() {
  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  R roundTrip<R>(DataRequest<R> request, R result) => DataEnvelope.readAnswer(
    overTheWire(
      DataEnvelope.answer(4, request, DataReply(result, 9, const [])),
    ),
    request,
  ).value;

  test('both requests round-trip with their arguments', () {
    for (final request in <TerminalWorkRequest<Object?>>[
      const TerminalsRunning(),
      const TerminalStopProcess(4242),
    ]) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request!.runtimeType, request.runtimeType);
      expect(read.request!.argumentsToJson(), request.argumentsToJson());
    }
  });

  test('a reading crosses whole', () {
    final reading = RunningReading(
      serverPid: 10,
      checkedAt: DateTime.utc(2026, 10, 6, 12),
      processes: const [
        RunningProcess(
          pid: 10,
          parent: 1,
          name: 'karmashala_host.exe',
          role: RunningRole.server,
          ports: [
            RunningPort(
              port: 47821,
              address: '127.0.0.1',
              label: 'MCP endpoint',
            ),
          ],
        ),
        RunningProcess(
          pid: 20,
          parent: 10,
          name: 'pwsh.exe',
          role: RunningRole.pane,
          paneId: 'p1',
          terminalSessionId: 'karmashala_s1',
          title: 'Fix the build',
          agentSessionId: 's1',
          command: 'npm run dev',
        ),
        RunningProcess(
          pid: 21,
          parent: 20,
          name: 'node.exe',
          role: RunningRole.child,
          paneId: 'p1',
          terminalSessionId: 'karmashala_s1',
          title: 'Fix the build',
          agentSessionId: 's1',
          stoppable: true,
          ports: [RunningPort(port: 5173, address: '::1')],
        ),
        RunningProcess(
          pid: 0,
          parent: 0,
          role: RunningRole.pane,
          paneId: 'p2',
          terminalSessionId: 'karmashala_local_p2',
          title: 'ubuntu',
          environmentId: 'wsl:Ubuntu',
        ),
      ],
      notes: const [
        RunningNote(
          '"ubuntu" runs in WSL; its ports are not read.',
          environmentId: 'wsl:Ubuntu',
        ),
      ],
    );
    final read = roundTrip(const TerminalsRunning(), reading);
    expect(read.serverPid, 10);
    expect(read.checkedAt, reading.checkedAt);
    expect(read.processes, hasLength(4));
    expect(read.processes[0].role, RunningRole.server);
    expect(read.processes[0].ports.single.label, 'MCP endpoint');
    final child = read.processes[2];
    expect(child.stoppable, isTrue);
    expect(child.agentSessionId, 's1');
    expect(child.ports.single.port, 5173);
    expect(read.processes[1].command, 'npm run dev');
    expect(read.processes[3].environmentId, 'wsl:Ubuntu');
    expect(read.notes.single.environmentId, 'wsl:Ubuntu');
  });

  test('a role this build does not know reads as a child it cannot stop', () {
    final process = RunningProcess.fromJson(const {
      'pid': 5,
      'parent': 4,
      'role': 'somethingNewer',
      'stoppable': true,
    });
    expect(process.role, RunningRole.child);
    expect(process.ports, isEmpty);
  });

  test(
    'a stop inside another machine names it; a local one says nothing new',
    () {
      const there = TerminalStopProcess(4242, machine: 'wsl:Ubuntu');
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, there)),
      );
      expect((read.request! as TerminalStopProcess).machine, 'wsl:Ubuntu');
      expect((read.request! as TerminalStopProcess).pid, 4242);
      // An older server reads exactly what it always read.
      expect(const TerminalStopProcess(7).argumentsToJson(), {'pid': 7});
    },
  );

  test('a process inside WSL or on an SSH box crosses with its machine, its '
      'command line and a Stop an older app cannot see', () {
    const inside = RunningProcess(
      pid: 812,
      parent: 800,
      name: 'node',
      role: RunningRole.child,
      paneId: 'p2',
      agentSessionId: 's2',
      environmentId: 'wsl:Ubuntu',
      pidMachine: 'wsl:Ubuntu',
      commandLine: 'node /work/node_modules/.bin/vite',
      stoppable: true,
      ports: [RunningPort(port: 3000, address: '0.0.0.0')],
    );
    final json = overTheWire(inside.toJson());
    // An older app offers Stop on `stoppable`, and would send this pid to be
    // stopped on Windows.
    expect(json['stoppable'], isFalse);
    final read = RunningProcess.fromJson(json);
    expect(read.pidMachine, 'wsl:Ubuntu');
    expect(read.commandLine, 'node /work/node_modules/.bin/vite');
    expect(read.stoppable, isTrue);
    expect(read.ports.single.port, 3000);

    const box = RunningPort(port: 8080, address: '0.0.0.0', host: 'box.lan');
    expect(RunningPort.fromJson(overTheWire(box.toJson())).host, 'box.lan');
  });

  test('a listener no session started has a role of its own, which an older '
      'build reads as a child it cannot stop', () {
    const listener = RunningProcess(
      pid: 0,
      parent: 0,
      role: RunningRole.listener,
      environmentId: 'wsl:Ubuntu',
      pidMachine: 'wsl:Ubuntu',
      ports: [RunningPort(port: 5432, address: '127.0.0.1')],
    );
    final read = RunningProcess.fromJson(overTheWire(listener.toJson()));
    expect(read.role, RunningRole.listener);
    expect(read.stoppable, isFalse);
  });
}
