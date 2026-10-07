import 'dart:async';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// One process as the OS lists it. [created] orders processes when the OS says
/// (Windows FILETIME); null when it does not.
typedef ProcessRow = ({int pid, int parent, String name, int? created});

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

/// A pane whose process tree the Running tab lists: [PaneRoot] and where it
/// runs, with its last command line.
typedef RunningPaneRoot = ({
  int pid,
  String paneId,
  String terminalSessionId,
  String title,
  String? agentSessionId,
  String? environmentId,
  String? command,
});

/// The executables that mirror and forward devices: adb's server holds every
/// `adb forward` port, and scrcpy streams.
bool _isDeviceProcess(String name) {
  final lower = name.toLowerCase();
  return lower == 'adb' ||
      lower == 'adb.exe' ||
      lower == 'scrcpy' ||
      lower == 'scrcpy.exe';
}

/// What one combined probe printed: `P <pid> <ppid> <created> <name>` and
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
    switch (parts[0]) {
      case 'P':
        final created = parts.length > 3 ? int.tryParse(parts[3]) : null;
        processes.add((
          pid: a,
          parent: b,
          name: parts.length > 4 ? parts.sublist(4).join(' ') : '',
          created: created == null || created <= 0 ? null : created,
        ));
      case 'L':
        final rest = parts.length > 3 ? parts.sublist(3).join(' ') : '';
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
        created: null,
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
List<ListeningSocket> parseSs(String output, {bool keepUnowned = false}) {
  final sockets = <ListeningSocket>[];
  for (final line in output.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 5) continue;
    final local = parts[3];
    final cut = local.lastIndexOf(':');
    final port = cut < 0 ? null : int.tryParse(local.substring(cut + 1));
    if (port == null) continue;
    final owners = RegExp(r'pid=(\d+)').allMatches(line).toList();
    // A socket whose process this user cannot see, as pid 0.
    if (owners.isEmpty && keepUnowned && parts.first == 'LISTEN') {
      sockets.add((port: port, pid: 0, address: local.substring(0, cut)));
    }
    for (final m in owners) {
      sockets.add((
        port: port,
        pid: int.parse(m.group(1)!),
        address: local.substring(0, cut),
      ));
    }
  }
  return sockets;
}

/// Each pid under [roots] (a root included), mapped to its root's pid. A
/// process created before its "parent" is an orphan whose parent pid Windows
/// has since reused, so it is not that parent's child.
Map<int, int> descendantsOf(Iterable<int> roots, List<ProcessRow> processes) {
  final createdOf = {for (final row in processes) row.pid: row.created};
  final children = <int, List<int>>{};
  for (final row in processes) {
    if (row.pid == row.parent) continue;
    final parentCreated = createdOf[row.parent];
    if (row.created != null &&
        parentCreated != null &&
        row.created! < parentCreated) {
      continue;
    }
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
/// Creation time as a FILETIME number, which no locale formats.
const String windowsProbeScript =
    r"$ErrorActionPreference='SilentlyContinue';"
    r'Get-CimInstance Win32_Process | ForEach-Object '
    r'{ $c = if ($_.CreationDate) { $_.CreationDate.ToFileTimeUtc() } '
    r'else { 0 }; '
    r'"P $($_.ProcessId) $($_.ParentProcessId) $c $($_.Name)" };'
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

  /// [Process.run] with a timeout that kills the probe rather than orphaning
  /// it. None of the probes starts a child of its own — CIM answers from
  /// WmiPrvSE, not under powershell — so killing the one process is the tree.
  static Future<ProcessResult> _runQuietly(
    String executable,
    List<String> arguments,
  ) async {
    final process = await Process.start(executable, arguments);
    final out = process.stdout.transform(systemEncoding.decoder).join();
    final err = process.stderr.transform(systemEncoding.decoder).join();
    try {
      final code = await process.exitCode.timeout(timeout);
      return ProcessResult(process.pid, code, await out, await err);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      out.ignore();
      err.ignore();
      rethrow;
    }
  }

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
    // A pane that is, or has started, wsl.exe: its Linux side's sockets are
    // not under any Windows process here, so "none" would be a guess.
    final inWsl = {
      for (final MapEntry(key: pid, value: root) in owners.entries)
        if (names[pid]?.toLowerCase() == 'wsl.exe') root,
    };
    for (final root in roots) {
      if (inWsl.contains(root.pid)) {
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

  /// Everything under [roots], the server ([serverPid], its ports named by
  /// [serverPorts]) and device mirroring, read now. [unlisted] are panes on
  /// machines this one cannot list, kept with [notes] saying so. A pane in
  /// [readInside] has had its WSL side read already.
  Future<RunningReading> running(
    List<RunningPaneRoot> roots, {
    required int serverPid,
    Map<int, String> serverPorts = const {},
    List<RunningProcess> unlisted = const [],
    List<RunningNote> notes = const [],
    Set<String> readInside = const {},
  }) async {
    final said = [...notes];
    List<ProcessRow> processes = const [];
    List<ListeningSocket> sockets = const [];
    try {
      (processes, sockets) = await _list();
    } on Object catch (error) {
      said.add(
        RunningNote(
          'The process and socket lists could not be read '
          '(${error.runtimeType}).',
        ),
      );
    }
    final rows = {for (final row in processes) row.pid: row};
    final portsOf = <int, List<RunningPort>>{};
    for (final socket in sockets) {
      final ports = portsOf[socket.pid] ??= [];
      // One port bound on IPv4 and IPv6 is one listener.
      if (ports.any((port) => port.port == socket.port)) continue;
      ports.add(
        RunningPort(
          port: socket.port,
          address: socket.address,
          label: socket.pid == serverPid ? serverPorts[socket.port] : null,
        ),
      );
    }
    for (final ports in portsOf.values) {
      ports.sort((a, b) => a.port.compareTo(b.port));
    }
    final listed = <int>{serverPid};
    final out = <RunningProcess>[
      RunningProcess(
        pid: serverPid,
        parent: rows[serverPid]?.parent ?? 0,
        name: rows[serverPid]?.name,
        role: RunningRole.server,
        ports: portsOf[serverPid] ?? const [],
      ),
    ];
    final owners = descendantsOf([
      for (final root in roots) root.pid,
    ], processes);
    for (final root in roots) {
      final tree = [
        root.pid,
        for (final MapEntry(key: pid, value: owner) in owners.entries)
          if (owner == root.pid && pid != root.pid) pid,
      ];
      for (final pid in tree) {
        if (!listed.add(pid)) continue;
        final isRoot = pid == root.pid;
        out.add(
          RunningProcess(
            pid: pid,
            parent: rows[pid]?.parent ?? 0,
            name: rows[pid]?.name,
            role: isRoot ? RunningRole.pane : RunningRole.child,
            paneId: root.paneId,
            terminalSessionId: root.terminalSessionId,
            title: root.title,
            agentSessionId: root.agentSessionId,
            environmentId: root.environmentId,
            command: root.command,
            stoppable: !isRoot,
            ports: portsOf[pid] ?? const [],
          ),
        );
      }
      if (!readInside.contains(root.paneId) &&
          tree.any((pid) => rows[pid]?.name.toLowerCase() == 'wsl.exe')) {
        said.add(
          RunningNote(
            '"${root.title}" runs in WSL; what listens inside it is not '
            'Windows\' to attribute.',
            environmentId: root.environmentId,
          ),
        );
      }
    }
    for (final row in processes) {
      if (!_isDeviceProcess(row.name) || !listed.add(row.pid)) continue;
      out.add(
        RunningProcess(
          pid: row.pid,
          parent: row.parent,
          name: row.name,
          role: RunningRole.device,
          ports: portsOf[row.pid] ?? const [],
        ),
      );
    }
    return RunningReading(
      serverPid: serverPid,
      processes: [...out, ...unlisted],
      checkedAt: _now().toUtc(),
      notes: said,
    );
  }

  /// Stops [pid] and its children, after checking afresh that it is under one
  /// of [roots] and is neither a root nor the server. Throws [DataRefused].
  Future<void> stop(
    int pid,
    List<RunningPaneRoot> roots, {
    required int serverPid,
  }) async {
    if (pid <= 0 || pid == serverPid || roots.any((root) => root.pid == pid)) {
      throw const DataRefused.denied(
        'only a process a pane started may be stopped here',
      );
    }
    final List<ProcessRow> processes;
    try {
      (processes, _) = await _list();
    } on Object catch (error) {
      throw DataRefused.unavailable(
        'the process list could not be read (${error.runtimeType})',
      );
    }
    final owners = descendantsOf([
      for (final root in roots) root.pid,
    ], processes);
    if (!owners.containsKey(pid)) {
      throw const DataRefused.denied(
        'that process is not one a pane started, or has already ended',
      );
    }
    if (_windows) {
      await _run('taskkill', ['/PID', '$pid', '/T', '/F']);
      return;
    }
    // Children first, so none is re-parented and missed.
    final tree = descendantsOf([pid], processes).keys.toList().reversed;
    await _run('kill', ['-TERM', for (final each in tree) '$each']);
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
