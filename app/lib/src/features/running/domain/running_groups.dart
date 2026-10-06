/// A [RunningReading] filed by machine, and by pane within a machine.
library;

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// One pane's process tree: its root first, then what it started.
class RunningPane {
  const RunningPane({
    required this.paneId,
    required this.title,
    required this.processes,
    this.agentSessionId,
  });

  final String? paneId;
  final String? title;
  final String? agentSessionId;
  final List<RunningProcess> processes;
}

/// What runs on one machine. [server] and [devices] are only ever the
/// server's own machine's.
class RunningMachine {
  const RunningMachine({
    required this.environmentId,
    required this.panes,
    this.server,
    this.devices = const [],
    this.notes = const [],
  });

  final String environmentId;
  final RunningProcess? server;
  final List<RunningPane> panes;
  final List<RunningProcess> devices;
  final List<RunningNote> notes;
}

/// One listening port and the process holding it.
typedef OwnedPort = ({RunningProcess process, RunningPort port});

/// [reading] by machine, the server's own ([localEnvironmentId]) first, then
/// WSL, then SSH. [environmentId] keeps one machine; [sessionId] keeps that
/// session's panes only, and drops the server and devices, which are no
/// session's.
List<RunningMachine> groupByMachine(
  RunningReading reading, {
  required String localEnvironmentId,
  String? environmentId,
  String? sessionId,
}) {
  String machineOf(String? id) => id ?? localEnvironmentId;
  final panes = <String, Map<String, List<RunningProcess>>>{};
  RunningProcess? server;
  final devices = <RunningProcess>[];
  for (final process in reading.processes) {
    switch (process.role) {
      case RunningRole.server:
        server = process;
      case RunningRole.device:
        devices.add(process);
      case RunningRole.pane || RunningRole.child:
        if (sessionId != null && process.agentSessionId != sessionId) continue;
        final machine = machineOf(process.environmentId);
        final key =
            process.paneId ?? process.terminalSessionId ?? '${process.pid}';
        ((panes[machine] ??= {})[key] ??= []).add(process);
    }
  }
  final ids = <String>{
    if (sessionId == null) localEnvironmentId,
    ...panes.keys,
    if (sessionId == null)
      for (final note in reading.notes) machineOf(note.environmentId),
  };
  int rank(String id) => id == localEnvironmentId
      ? 0
      : id.startsWith('wsl:')
      ? 1
      : 2;
  final ordered =
      ids.where((id) => environmentId == null || id == environmentId).toList()
        ..sort((a, b) {
          final byRank = rank(a).compareTo(rank(b));
          return byRank != 0 ? byRank : a.compareTo(b);
        });
  return [
    for (final id in ordered)
      RunningMachine(
        environmentId: id,
        server: sessionId == null && id == localEnvironmentId ? server : null,
        devices: sessionId == null && id == localEnvironmentId
            ? devices
            : const [],
        panes: [
          for (final processes in (panes[id] ?? const {}).values)
            RunningPane(
              paneId: processes.first.paneId,
              title: processes.first.title,
              agentSessionId: processes.first.agentSessionId,
              processes: [
                ...processes.where((p) => p.role == RunningRole.pane),
                ...processes.where((p) => p.role != RunningRole.pane),
              ],
            ),
        ],
        notes: [
          for (final note in reading.notes)
            if (machineOf(note.environmentId) == id) note,
        ],
      ),
  ];
}

/// Every port the panes of session [sessionId] listen on.
List<OwnedPort> portsOfSession(RunningReading reading, String sessionId) => [
  for (final process in reading.processes)
    if (process.agentSessionId == sessionId &&
        process.role != RunningRole.server)
      for (final port in process.ports) (process: process, port: port),
];

/// Every port in [reading], with its process.
List<OwnedPort> allPorts(RunningReading reading) => [
  for (final process in reading.processes)
    for (final port in process.ports) (process: process, port: port),
];
