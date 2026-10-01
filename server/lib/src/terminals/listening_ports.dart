import 'dart:async';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// One process as the OS lists it.
typedef ProcessRow = ({int pid, int parent, String name});

/// One listening TCP socket and the process holding it.
typedef ListeningSocket = ({int port, int pid, String address});

/// A pane whose process tree is searched: its root process and how to name it.
typedef PaneRoot = ({
  int pid,
  String paneId,
  String terminalSessionId,
  String title,
  String? agentSessionId,
});

/// What one combined probe printed: `P <pid> <ppid> <name>` and
/// `L <port> <pid> <address>` lines, the shape [windowsProbeScript] prints.
({List<ProcessRow> processes, List<ListeningSocket> sockets}) parseProbeLines(
  String output,
) {
  final processes = <ProcessRow>[];
  final sockets = <ListeningSocket>[];
  for (final raw in output.split('\n')) {
    final parts = raw.trim().split(RegExp(r'\s+'));
    if (parts.length < 3) continue;
    final a = int.tryParse(parts[1]);
    final b = int.tryParse(parts[2]);
    if (a == null || b == null) continue;
    final rest = parts.length > 3 ? parts.sublist(3).join(' ') : '';
    switch (parts[0]) {
      case 'P':
        processes.add((pid: a, parent: b, name: rest));
      case 'L':
        sockets.add((port: a, pid: b, address: rest));
    }
  }
  return (processes: processes, sockets: sockets);
}

/// `ps -A -o pid=,ppid=,comm=`.
List<ProcessRow> parsePs(String output) => [
  for (final line in output.split('\n'))
    if (RegExp(r'^\s*(\d+)\s+(\d+)\s+(.*)$').firstMatch(line) case final m?)
      (
        pid: int.parse(m.group(1)!),
        parent: int.parse(m.group(2)!),
        name: m.group(3)!.trim().split('/').last,
      ),
];

/// `lsof -nP -iTCP -sTCP:LISTEN -F pn`: a `p<pid>` line, then `n<addr>:<port>`
/// lines for that process.
List<ListeningSocket> parseLsof(String output) {
  final sockets = <ListeningSocket>[];
  int? pid;
  for (final line in output.split('\n')) {
    final text = line.trim();
    if (text.startsWith('p')) {
      pid = int.tryParse(text.substring(1));
    } else if (text.startsWith('n') && pid != null) {
      final name = text.substring(1);
      final cut = name.lastIndexOf(':');
      final port = cut < 0 ? null : int.tryParse(name.substring(cut + 1));
      if (port != null) {
        sockets.add((port: port, pid: pid, address: name.substring(0, cut)));
      }
    }
  }
  return sockets;
}

/// `ss -ltnpH`: `LISTEN 0 511 127.0.0.1:5173 0.0.0.0:* users:(("node",pid=12,fd=20))`.
List<ListeningSocket> parseSs(String output) {
  final sockets = <ListeningSocket>[];
  for (final line in output.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 6) continue;
    final local = parts[3];
    final cut = local.lastIndexOf(':');
    final port = cut < 0 ? null : int.tryParse(local.substring(cut + 1));
    if (port == null) continue;
    for (final m in RegExp(r'pid=(\d+)').allMatches(line)) {
      sockets.add((
        port: port,
        pid: int.parse(m.group(1)!),
        address: local.substring(0, cut),
      ));
    }
  }
  return sockets;
}

/// Each pid under [roots] (a root included), mapped to its root's pid.
Map<int, int> descendantsOf(Iterable<int> roots, List<ProcessRow> processes) {
  final children = <int, List<int>>{};
  for (final row in processes) {
    if (row.pid == row.parent) continue;
    (children[row.parent] ??= []).add(row.pid);
  }
  final owner = <int, int>{};
  for (final root in roots) {
    final queue = [root];
    while (queue.isNotEmpty) {
      final pid = queue.removeLast();
      if (owner.containsKey(pid)) continue;
      owner[pid] = root;
      queue.addAll(children[pid] ?? const []);
    }
  }
  return owner;
}

/// One PowerShell spawn for both lists: `Get-NetTCPConnection` rather than
/// `netstat`, whose state column is translated on a non-English Windows.
const String windowsProbeScript =
    r"$ErrorActionPreference='SilentlyContinue';"
    r'Get-CimInstance Win32_Process | ForEach-Object '
    r'{ "P $($_.ProcessId) $($_.ParentProcessId) $($_.Name)" };'
    r'Get-NetTCPConnection -State Listen | ForEach-Object '
    r'{ "L $($_.LocalPort) $($_.OwningProcess) $($_.LocalAddress)" }';

/// Which ports the processes under each pane listen on, measured when asked:
/// **on demand, never on a timer** (PROJECT.md §19 — a probe costs processes).
class ListeningPortProbe {
  ListeningPortProbe({
    bool? windows,
    bool? macOS,
    Future<ProcessResult> Function(String executable, List<String> arguments)?
    run,
    DateTime Function()? clock,
  }) : _windows = windows ?? Platform.isWindows,
       _macOS = macOS ?? Platform.isMacOS,
       _run = run ?? _runQuietly,
       _now = clock ?? DateTime.now;

  final bool _windows;
  final bool _macOS;
  final Future<ProcessResult> Function(String, List<String>) _run;
  final DateTime Function() _now;

  static const Duration timeout = Duration(seconds: 15);

  static Future<ProcessResult> _runQuietly(
    String executable,
    List<String> arguments,
  ) => Process.run(executable, arguments).timeout(timeout);

  /// The ports under [roots]; a pane in [unreadPanes] is named as not looked
  /// at, and a probe that fails is said rather than read as "none".
  Future<ListeningPortsReading> read(
    List<PaneRoot> roots, {
    List<String> unreadPanes = const [],
  }) async {
    final unread = [...unreadPanes];
    if (roots.isEmpty) {
      return ListeningPortsReading(
        ports: const [],
        checkedAt: _now().toUtc(),
        unread: unread,
      );
    }
    List<ProcessRow> processes = const [];
    List<ListeningSocket> sockets = const [];
    try {
      (processes, sockets) = await _list();
    } on Object catch (error) {
      unread.add(
        'The process and socket lists could not be read '
        '(${error.runtimeType}).',
      );
    }
    final owners = descendantsOf([
      for (final root in roots) root.pid,
    ], processes);
    final byRoot = {for (final root in roots) root.pid: root};
    final names = {for (final row in processes) row.pid: row.name};
    for (final root in roots) {
      if (names[root.pid]?.toLowerCase() == 'wsl.exe') {
        unread.add(
          '"${root.title}" runs in WSL; what listens inside it is not '
          'Windows\' to attribute.',
        );
      }
    }
    final seen = <String>{};
    final ports = <ListeningPort>[];
    for (final socket in sockets) {
      final root = byRoot[owners[socket.pid]];
      if (root == null) continue;
      // One port bound on IPv4 and IPv6 is one dev server.
      if (!seen.add('${root.paneId}:${socket.port}')) continue;
      ports.add(
        ListeningPort(
          port: socket.port,
          address: socket.address,
          pid: socket.pid,
          process: names[socket.pid],
          paneId: root.paneId,
          terminalSessionId: root.terminalSessionId,
          title: root.title,
          agentSessionId: root.agentSessionId,
        ),
      );
    }
    ports.sort((a, b) => a.port.compareTo(b.port));
    return ListeningPortsReading(
      ports: ports,
      checkedAt: _now().toUtc(),
      unread: unread,
    );
  }

  Future<(List<ProcessRow>, List<ListeningSocket>)> _list() async {
    if (_windows) {
      final result = await _run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        windowsProbeScript,
      ]);
      final parsed = parseProbeLines('${result.stdout}');
      if (parsed.processes.isEmpty) {
        throw StateError('powershell listed no processes');
      }
      return (parsed.processes, parsed.sockets);
    }
    final ps = await _run('ps', ['-A', '-o', 'pid=,ppid=,comm=']);
    final processes = parsePs('${ps.stdout}');
    if (processes.isEmpty) throw StateError('ps listed no processes');
    if (!_macOS) {
      try {
        final ss = await _run('ss', ['-ltnpH']);
        if (ss.exitCode == 0) return (processes, parseSs('${ss.stdout}'));
      } on Object {
        // No ss: lsof below.
      }
    }
    final lsof = await _run('lsof', [
      '-nP',
      '-iTCP',
      '-sTCP:LISTEN',
      '-F',
      'pn',
    ]);
    return (processes, parseLsof('${lsof.stdout}'));
  }
}
