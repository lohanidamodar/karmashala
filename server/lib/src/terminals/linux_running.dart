import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_launch/karmashala_launch.dart'
    show kSessionIdEnvironmentVariable;

import 'listening_ports.dart';

/// Runs a script under `sh` on a Linux machine and answers what it printed.
/// Throws when it cannot.
typedef LinuxShell = Future<String> Function(String script);

/// A shell on an SSH box, over a connection that is already open, and the
/// address its ports are reached at.
typedef BoxShell = ({String address, LinuxShell run});

/// One Linux process as [linuxRunningScript] printed it. [sessionId] is the
/// `KARMASHALA_SESSION_ID` in its own environment, when it could be read.
typedef LinuxProcess = ({
  int pid,
  int parent,
  String name,
  String commandLine,
  String? sessionId,
});

/// What one probe of a Linux machine found. [probe] is the probe's own shell,
/// whose tree is never anybody's.
typedef LinuxListing = ({
  List<LinuxProcess> processes,
  List<ListeningSocket> sockets,
  int? probe,
});

/// The pane a session runs in, which processes naming that session are filed
/// under.
typedef LinuxSessionPane = ({
  String paneId,
  String terminalSessionId,
  String title,
  String? command,
});

/// One look at a Linux machine, in one `sh`: every process with its command
/// line, the session id each one's environment names, and what listens.
/// `ps` and one `grep` over every `environ`, not a loop of forks per process.
const String linuxRunningScript =
    '''
export LC_ALL=C
echo "@@self \$\$"
echo "@@ps"
ps -A -o pid=,ppid=,args= 2>/dev/null
echo "@@comm"
ps -A -o pid=,comm= 2>/dev/null
echo "@@env"
if printf 'a\\0' | grep -qaz a 2>/dev/null; then
  grep -aHoz '^$kSessionIdEnvironmentVariable=[^[:cntrl:]]*' /proc/[0-9]*/environ 2>/dev/null | tr '\\0' '\\n'
fi
if command -v ss >/dev/null 2>&1; then
  echo "@@ss"
  ss -ltnpH 2>/dev/null || ss -ltnp 2>/dev/null
elif command -v lsof >/dev/null 2>&1; then
  echo "@@lsof"
  lsof -nP -iTCP -sTCP:LISTEN -F pn 2>/dev/null
fi
echo "@@end"
''';

/// `kill -TERM` for [pids] in order, the last one the process asked for:
/// prints `stopped` only when that one was signalled.
String linuxStopScript(List<int> pids) {
  final [...rest, last] = pids;
  return [
    if (rest.isNotEmpty) 'kill -TERM ${rest.join(' ')} 2>/dev/null',
    'kill -TERM $last && echo stopped',
  ].join('\n');
}

final _pidLine = RegExp(r'^\s*(\d+)\s+(\d+)\s?(.*)$');
final _commLine = RegExp(r'^\s*(\d+)\s?(.*)$');
final _environLine = RegExp(
  '^/proc/(\\d+)/environ:$kSessionIdEnvironmentVariable=(.*)\$',
);

/// [output] of [linuxRunningScript]. Throws [FormatException] when it is not
/// a whole one — a probe cut short is not "nothing runs".
LinuxListing parseLinuxListing(String output) {
  final args = <int, ({int parent, String line})>{};
  final names = <int, String>{};
  final sessions = <int, String>{};
  final ss = StringBuffer();
  final lsof = StringBuffer();
  int? probe;
  var section = '';
  var ended = false;
  for (final raw in const LineSplitter().convert(output)) {
    final line = raw.trimRight();
    if (line.startsWith('@@')) {
      final parts = line.substring(2).split(' ');
      section = parts.first;
      if (section == 'self' && parts.length > 1) {
        probe = int.tryParse(parts[1]);
      }
      if (section == 'end') ended = true;
      continue;
    }
    switch (section) {
      case 'ps':
        if (_pidLine.firstMatch(line) case final m?) {
          args[int.parse(m[1]!)] = (parent: int.parse(m[2]!), line: m[3]!);
        }
      case 'comm':
        if (_commLine.firstMatch(line) case final m?) {
          names[int.parse(m[1]!)] = m[2]!.trim();
        }
      case 'env':
        if (_environLine.firstMatch(line) case final m?) {
          final id = m[2]!.trim();
          if (id.isNotEmpty) sessions[int.parse(m[1]!)] = id;
        }
      case 'ss':
        ss.writeln(line);
      case 'lsof':
        lsof.writeln(line);
    }
  }
  if (!ended || args.isEmpty) {
    throw const FormatException('the probe did not finish its listing');
  }
  return (
    processes: [
      for (final MapEntry(key: pid, value: row) in args.entries)
        (
          pid: pid,
          parent: row.parent,
          name: _nameOf(row.line, names[pid]),
          commandLine: row.line.trim(),
          sessionId: sessions[pid],
        ),
    ],
    sockets: [...parseSs('$ss', keepUnowned: true), ...parseLsof('$lsof')],
    probe: probe,
  );
}

/// The program [line] runs, by its argv[0]: `comm` is a thread's name once a
/// runtime renames it (Node's reads `node-MainThread`). A kernel thread's
/// bracketed line keeps [comm].
String _nameOf(String line, String? comm) {
  final first = line.trim().split(RegExp(r'\s+')).first;
  if (first.isEmpty || first.startsWith('[')) return comm ?? first;
  final base = first.split('/').last;
  final name = base.endsWith(':') ? base.substring(0, base.length - 1) : base;
  return name.isEmpty ? (comm ?? first) : name;
}

/// The processes and ports of one probe, by pid, with the session each one
/// belongs to: its own `KARMASHALA_SESSION_ID`, else its nearest ancestor's.
class _Attributed {
  _Attributed(this.listing) {
    for (final process in listing.processes) {
      byPid[process.pid] = process;
      if (process.parent != process.pid) {
        (children[process.parent] ??= []).add(process.pid);
      }
    }
    if (listing.probe case final probe?) probeTree.addAll(treeOf(probe));
  }

  final LinuxListing listing;
  final byPid = <int, LinuxProcess>{};
  final children = <int, List<int>>{};
  final probeTree = <int>{};
  final _session = <int, String?>{};

  /// [pid] and everything under it, children before their parents.
  List<int> treeOf(int pid) {
    final out = <int>[];
    void visit(int each, int depth) {
      if (depth > 256 || out.contains(each)) return;
      for (final child in children[each] ?? const <int>[]) {
        visit(child, depth + 1);
      }
      out.add(each);
    }

    visit(pid, 0);
    return out;
  }

  String? sessionOf(int pid) {
    if (_session.containsKey(pid)) return _session[pid];
    String? found;
    final seen = <int>{};
    for (int? at = pid; at != null && seen.add(at);) {
      final process = byPid[at];
      if (process == null) break;
      if (process.sessionId case final id?) {
        found = id;
        break;
      }
      at = process.parent == 0 ? null : process.parent;
    }
    return _session[pid] = found;
  }

  /// The topmost process of its session: it ends with the pane.
  bool isSessionRoot(int pid) {
    final parent = byPid[pid]?.parent;
    return parent == null || parent == 0 || sessionOf(parent) != sessionOf(pid);
  }
}

bool _isKarmashala(String name) => name.toLowerCase().startsWith('karmashala');

/// [listing], read on [machine]: each process of a session in [sessions] —
/// its pane's, stoppable unless it is the session's root or Karmashala — and
/// each other listening process as a [RunningRole.listener]. [host] is where
/// the ports are reached, for a box.
List<RunningProcess> attributeLinuxListing(
  LinuxListing listing, {
  required String machine,
  required Map<String, LinuxSessionPane> sessions,
  String? host,
}) {
  final tree = _Attributed(listing);
  final portsOf = <int, List<RunningPort>>{};
  for (final socket in listing.sockets) {
    if (tree.probeTree.contains(socket.pid)) continue;
    final ports = portsOf[socket.pid] ??= [];
    // One port bound on IPv4 and IPv6 is one listener.
    if (ports.any((port) => port.port == socket.port)) continue;
    ports.add(
      RunningPort(port: socket.port, address: socket.address, host: host),
    );
  }
  for (final ports in portsOf.values) {
    ports.sort((a, b) => a.port.compareTo(b.port));
  }
  final out = <RunningProcess>[];
  final ordered = [...listing.processes]..sort((a, b) => a.pid - b.pid);
  for (final process in ordered) {
    if (tree.probeTree.contains(process.pid)) continue;
    final sessionId = tree.sessionOf(process.pid);
    final pane = sessions[sessionId];
    final ports = portsOf.remove(process.pid) ?? const <RunningPort>[];
    if (pane != null) {
      out.add(
        RunningProcess(
          pid: process.pid,
          parent: process.parent,
          name: process.name,
          role: RunningRole.child,
          paneId: pane.paneId,
          terminalSessionId: pane.terminalSessionId,
          title: pane.title,
          agentSessionId: sessionId,
          environmentId: machine,
          command: pane.command,
          pidMachine: machine,
          commandLine: process.commandLine,
          stoppable:
              process.pid > 1 &&
              !tree.isSessionRoot(process.pid) &&
              !_isKarmashala(process.name),
          ports: ports,
        ),
      );
    } else if (ports.isNotEmpty) {
      out.add(
        RunningProcess(
          pid: process.pid,
          parent: process.parent,
          name: process.name,
          role: RunningRole.listener,
          environmentId: machine,
          pidMachine: machine,
          commandLine: process.commandLine,
          ports: ports,
        ),
      );
    }
  }
  // Sockets of processes this user cannot see: what listens, by nobody named.
  final unowned = [for (final ports in portsOf.values) ...ports]
    ..sort((a, b) => a.port.compareTo(b.port));
  if (unowned.isNotEmpty) {
    out.add(
      RunningProcess(
        pid: 0,
        parent: 0,
        role: RunningRole.listener,
        environmentId: machine,
        pidMachine: machine,
        ports: unowned,
      ),
    );
  }
  return out;
}

/// What stopping [pid] signals, children first and [pid] last — refused
/// (`denied`) unless a session in [sessions] started it, and it is neither
/// that session's root nor Karmashala.
List<int> linuxStopPlan(
  LinuxListing listing,
  int pid,
  Map<String, LinuxSessionPane> sessions,
) {
  final tree = _Attributed(listing);
  final process = tree.byPid[pid];
  if (process == null || pid <= 1 || tree.probeTree.contains(pid)) {
    throw const DataRefused.denied(
      'that process is not one a session started, or has already ended',
    );
  }
  if (!sessions.containsKey(tree.sessionOf(pid))) {
    throw const DataRefused.denied(
      'only a process a session here started may be stopped here',
    );
  }
  if (_isKarmashala(process.name)) {
    throw const DataRefused.denied(
      'the Karmashala server there is managed in Settings, not stopped here',
    );
  }
  if (tree.isSessionRoot(pid)) {
    throw const DataRefused.denied(
      'a session\'s own process ends with its pane, not from here',
    );
  }
  return [
    for (final each in tree.treeOf(pid))
      if (!tree.probeTree.contains(each)) each,
  ];
}

/// `wsl.exe -d <distribution> -e sh -s`, the script on stdin, killed when it
/// outlasts [timeout]. Never `-e` with the script as an argument: Windows
/// would have to quote it.
LinuxShell wslShell(
  String? distribution, {
  Duration timeout = ListeningPortProbe.timeout,
}) => (script) async {
  final process = await Process.start('wsl.exe', [
    if (distribution != null && distribution.isNotEmpty) ...[
      '-d',
      distribution,
    ],
    '-e',
    'sh',
    '-s',
  ]);
  final out = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final err = process.stderr.drain<void>();
  process.stdin.write(script);
  await process.stdin.close();
  try {
    await process.exitCode.timeout(timeout);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    out.ignore();
    err.ignore();
    rethrow;
  }
  await err;
  return out;
};
