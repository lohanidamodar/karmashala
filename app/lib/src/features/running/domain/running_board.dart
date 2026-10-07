/// A [RunningReading] arranged to be read: what listens first, then one card
/// per session with its wrappers hidden and its duplicates grouped.
library;

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import 'port_label.dart';

/// Who a listening port belongs to.
enum PortOwner { session, terminal, server, device, machine }

/// One listening port, what it is, and who holds it.
class BoardPort {
  const BoardPort({
    required this.process,
    required this.port,
    required this.label,
    required this.machine,
    required this.owner,
  });

  final RunningProcess process;
  final RunningPort port;
  final PortLabel label;

  /// The environment id it runs on.
  final String machine;
  final PortOwner owner;

  /// `localhost:3000`, or `host:port` on a box.
  String get address => '${port.host ?? 'localhost'}:${port.port}';

  /// What a browser on the server's machine opens: null for a port that is
  /// not http, or one on a box that nothing forwards here.
  String? get url => label.isHttp && port.host == null
      ? 'http://localhost:${port.port}'
      : null;

  /// Inside WSL, whether Windows' localhost reaches it: WSL forwards a port
  /// bound to loopback or every address, not one bound to the VM's own.
  bool get forwardedFromWsl {
    final address = port.address.replaceAll(RegExp(r'^\[|\]$'), '');
    return const {
          '',
          '*',
          '0.0.0.0',
          '::',
          '127.0.0.1',
          '::1',
        }.contains(address) ||
        address.startsWith('127.');
  }
}

/// Processes of one name in one session: `flutter_tester.exe ×6`.
class ProcessGroup {
  const ProcessGroup(this.name, this.processes);

  final String name;
  final List<RunningProcess> processes;

  int get count => processes.length;
  bool get listens => processes.any((p) => p.ports.isNotEmpty);
  Iterable<RunningPort> get ports => processes.expand((p) => p.ports);
}

/// One pane's processes, wherever they run, read as a card.
class BoardSession {
  const BoardSession({
    required this.key,
    required this.machine,
    required this.processes,
    required this.headline,
    required this.others,
    required this.helpers,
    this.paneId,
    this.title,
    this.agentSessionId,
    this.notes = const [],
  });

  final String key;
  final String? paneId;
  final String? title;
  final String? agentSessionId;
  final String machine;

  /// Every process, the pane's root first.
  final List<RunningProcess> processes;

  /// What listens, then the tools a person started (node, vite, dart…).
  final List<ProcessGroup> headline;

  /// The rest that is not a wrapper.
  final List<ProcessGroup> others;

  /// conhost, cmd and the WSL relays: hidden behind a count.
  final List<RunningProcess> helpers;

  /// What was not read about it, said on it.
  final List<RunningNote> notes;

  /// The processes that are really running — a pane on a machine that was
  /// not read is listed with pid 0.
  int get processCount => processes.where((p) => p.pid > 0).length;
  int get portCount => processes.fold(0, (sum, p) => sum + p.ports.length);
}

/// The Running tab's whole board.
class RunningBoard {
  const RunningBoard({
    required this.ports,
    required this.sessions,
    this.server,
    this.devices = const [],
    this.notes = const [],
  });

  /// The Karmashala server, when it is on the board.
  final RunningProcess? server;

  /// Every listening port but the server's own, sessions' first.
  final List<BoardPort> ports;
  final List<BoardSession> sessions;

  /// Device mirroring that listens on nothing.
  final List<RunningProcess> devices;

  /// What was not read and belongs to no session's card.
  final List<RunningNote> notes;

  bool get isEmpty =>
      server == null && ports.isEmpty && sessions.isEmpty && devices.isEmpty;
}

/// The wrappers a pane's tree is full of: consoles, `cmd /c` shells and the
/// relays WSL runs on Windows. Shown only when they listen.
bool isHelperProcess(RunningProcess process) =>
    process.ports.isEmpty &&
    const {
      'conhost',
      'openconsole',
      'cmd',
      'wslhost',
      'wsl',
      'wslrelay',
    }.contains(processStem(process.name));

/// The tools a person runs on purpose, which a card names first.
bool isKnownTool(RunningProcess process) => const {
  'node',
  'vite',
  'bun',
  'deno',
  'npm',
  'npx',
  'pnpm',
  'yarn',
  'python',
  'python3',
  'uvicorn',
  'flutter',
  'flutter_tester',
  'dart',
  'dartvm',
  'dartaotruntime',
  'docker',
  'go',
  'cargo',
  'java',
  'ruby',
  'php',
  'postgres',
  'redis-server',
}.contains(processStem(process.name));

/// `node.exe` → `node`; a path's last part, lowercased.
String processStem(String? name) {
  final last = (name ?? '').split(RegExp(r'[\\/]')).last.toLowerCase();
  return last.endsWith('.exe') ? last.substring(0, last.length - 4) : last;
}

/// [reading] as a board. [environmentId] keeps one machine and [sessionId]
/// one session (which drops the server and devices); [query] keeps the ports
/// and processes whose port, name, command line or owner holds it.
RunningBoard buildRunningBoard(
  RunningReading reading, {
  required String localEnvironmentId,
  String? environmentId,
  String? sessionId,
  String query = '',
  PortFacts facts = const PortFacts(),
}) {
  String machineOf(RunningProcess process) =>
      process.environmentId ?? localEnvironmentId;
  bool onMachine(String machine) =>
      environmentId == null || machine == environmentId;
  final needle = query.trim().toLowerCase();
  bool holds(String? text) =>
      text != null && text.toLowerCase().contains(needle);
  bool processMatches(RunningProcess process) =>
      needle.isEmpty ||
      holds(process.name) ||
      holds(process.commandLine) ||
      process.ports.any((port) => '${port.port}'.contains(needle));

  RunningProcess? server;
  final devices = <RunningProcess>[];
  final ports = <BoardPort>[];
  final byPane = <String, List<RunningProcess>>{};
  for (final process in reading.processes) {
    final machine = machineOf(process);
    switch (process.role) {
      case RunningRole.server:
        if (sessionId == null && onMachine(machine)) server = process;
        continue;
      case RunningRole.device:
        if (sessionId != null || !onMachine(machine)) continue;
        if (process.ports.isEmpty) devices.add(process);
      case RunningRole.listener:
        if (sessionId != null || !onMachine(machine)) continue;
      case RunningRole.pane || RunningRole.child:
        if (sessionId != null && process.agentSessionId != sessionId) continue;
        if (!onMachine(machine)) continue;
        final key =
            process.paneId ?? process.terminalSessionId ?? 'pid:${process.pid}';
        (byPane[key] ??= []).add(process);
    }
    final owner = switch (process.role) {
      RunningRole.device => PortOwner.device,
      RunningRole.listener => PortOwner.machine,
      _ when process.agentSessionId != null => PortOwner.session,
      _ => PortOwner.terminal,
    };
    for (final port in process.ports) {
      final label = labelPort(
        process: process.name,
        port: port.port,
        command: process.commandLine ?? process.command,
        facts: facts,
      );
      if (needle.isNotEmpty &&
          !'${port.port}'.contains(needle) &&
          !holds(label.name) &&
          !holds(process.name) &&
          !holds(process.title) &&
          !holds(process.commandLine)) {
        continue;
      }
      ports.add(
        BoardPort(
          process: process,
          port: port,
          label: label,
          machine: machine,
          owner: owner,
        ),
      );
    }
  }
  int ownerRank(PortOwner owner) => switch (owner) {
    PortOwner.session || PortOwner.terminal => 0,
    PortOwner.device => 1,
    PortOwner.machine => 2,
    PortOwner.server => 3,
  };
  ports.sort((a, b) {
    final byOwner = ownerRank(a.owner).compareTo(ownerRank(b.owner));
    return byOwner != 0 ? byOwner : a.port.port.compareTo(b.port.port);
  });

  final notes = [
    for (final note in reading.notes)
      if (sessionId == null &&
          onMachine(note.environmentId ?? localEnvironmentId))
        note,
  ];
  final sessions = <BoardSession>[];
  for (final MapEntry(key: key, value: all) in byPane.entries) {
    final first = all.first;
    final title = all.map((p) => p.title).nonNulls.firstOrNull;
    final titleMatches = needle.isNotEmpty && holds(title);
    final processes = [
      ...all.where((p) => p.role == RunningRole.pane),
      ...all.where((p) => p.role != RunningRole.pane),
    ];
    final shown = titleMatches
        ? processes
        : processes.where(processMatches).toList();
    if (needle.isNotEmpty && shown.isEmpty) continue;
    final machine = machineOf(
      processes.firstWhere(
        (p) => p.role == RunningRole.pane,
        orElse: () => first,
      ),
    );
    final mine = [
      for (final note in notes)
        if (title != null &&
            note.text.startsWith('"$title"') &&
            (note.environmentId ?? localEnvironmentId) == machine)
          note,
    ];
    notes.removeWhere(mine.contains);
    final live = shown.where((p) => p.pid > 0 || p.role != RunningRole.pane);
    final helpers = live.where(isHelperProcess).toList();
    final groups = _groupByName(live.where((p) => !isHelperProcess(p)));
    final headline = groups
        .where((g) => g.listens || g.processes.any(isKnownTool))
        .toList();
    sessions.add(
      BoardSession(
        key: key,
        paneId: first.paneId,
        title: title,
        agentSessionId: all.map((p) => p.agentSessionId).nonNulls.firstOrNull,
        machine: machine,
        processes: shown,
        headline: headline,
        others: groups.where((g) => !headline.contains(g)).toList(),
        helpers: helpers,
        notes: mine,
      ),
    );
  }
  int machineRank(String id) => id == localEnvironmentId
      ? 0
      : id.startsWith('wsl:')
      ? 1
      : 2;
  sessions.sort((a, b) {
    // A session that listens is the one being looked for.
    final byPorts = (b.portCount > 0 ? 1 : 0) - (a.portCount > 0 ? 1 : 0);
    if (byPorts != 0) return byPorts;
    final byMachine = machineRank(a.machine) - machineRank(b.machine);
    if (byMachine != 0) return byMachine;
    return (a.title ?? '').toLowerCase().compareTo(
      (b.title ?? '').toLowerCase(),
    );
  });
  return RunningBoard(
    server: needle.isEmpty ? server : null,
    ports: ports,
    sessions: sessions,
    devices: needle.isEmpty ? devices : const [],
    notes: notes,
  );
}

/// [processes] by name, those that listen first, then the most numerous. A
/// process that listens is its own group: vite is not the agent's node.
List<ProcessGroup> _groupByName(Iterable<RunningProcess> processes) {
  final byName = <String, List<RunningProcess>>{};
  for (final process in processes) {
    final name = (process.name ?? 'process').toLowerCase();
    final key = process.ports.isEmpty ? name : '$name#${process.pid}';
    (byName[key] ??= []).add(process);
  }
  final groups = [
    for (final list in byName.values) ProcessGroup(list.first.name ?? '', list),
  ];
  groups.sort((a, b) {
    if (a.listens != b.listens) return a.listens ? -1 : 1;
    final byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : a.name.compareTo(b.name);
  });
  return groups;
}
