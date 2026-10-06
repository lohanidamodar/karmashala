// What Karmashala runs: the server, its panes' process trees with the ports
// they listen on, and device mirroring — read when asked
// (`terminals.running`), never on a timer.

/// Why a process is in the reading.
enum RunningRole {
  /// The Karmashala server itself. Never stopped from a reading.
  server,

  /// The process a pane started: its shell, or its agent.
  pane,

  /// A process under a pane's root.
  child,

  /// adb or scrcpy: what mirrors and forwards devices.
  device,
}

/// One listening TCP socket. [label] is what the server knows it to be — its
/// own MCP endpoint, its relay — and null for anything else.
final class RunningPort {
  const RunningPort({required this.port, required this.address, this.label});

  final int port;
  final String address;
  final String? label;

  Map<String, Object?> toJson() => {
    'port': port,
    'address': address,
    'label': ?label,
  };

  factory RunningPort.fromJson(Map<String, Object?> json) => RunningPort(
    port: (json['port']! as num).toInt(),
    address: json['address'] as String? ?? '',
    label: json['label'] as String?,
  );
}

/// One process, what owns it, and what it listens on. A pane on a machine the
/// server cannot list (WSL, SSH) is here with pid 0 and no ports.
final class RunningProcess {
  const RunningProcess({
    required this.pid,
    required this.parent,
    required this.role,
    this.name,
    this.paneId,
    this.terminalSessionId,
    this.title,
    this.agentSessionId,
    this.environmentId,
    this.command,
    this.stoppable = false,
    this.ports = const [],
  });

  final int pid;
  final int parent;
  final RunningRole role;

  /// The executable's name, when the OS said.
  final String? name;
  final String? paneId;
  final String? terminalSessionId;

  /// The owning pane's title.
  final String? title;

  /// The Karmashala session the owning pane runs, for an agent pane.
  final String? agentSessionId;

  /// The machine it runs on; null for the server's own.
  final String? environmentId;

  /// The owning pane's last command line, when its shell said.
  final String? command;

  /// Whether the server would stop it: a process under a pane, never a
  /// pane's root nor the server. The server checks again when asked.
  final bool stoppable;
  final List<RunningPort> ports;

  Map<String, Object?> toJson() => {
    'pid': pid,
    'parent': parent,
    'role': role.name,
    'name': ?name,
    'paneId': ?paneId,
    'terminalSessionId': ?terminalSessionId,
    'title': ?title,
    'agentSessionId': ?agentSessionId,
    'environmentId': ?environmentId,
    'command': ?command,
    'stoppable': stoppable,
    'ports': [for (final port in ports) port.toJson()],
  };

  factory RunningProcess.fromJson(Map<String, Object?> json) {
    final role = RunningRole.values
        .where((role) => role.name == json['role'])
        .firstOrNull;
    return RunningProcess(
      pid: (json['pid'] as num?)?.toInt() ?? 0,
      parent: (json['parent'] as num?)?.toInt() ?? 0,
      // A newer server's role is something this build cannot vouch for.
      role: role ?? RunningRole.child,
      name: json['name'] as String?,
      paneId: json['paneId'] as String?,
      terminalSessionId: json['terminalSessionId'] as String?,
      title: json['title'] as String?,
      agentSessionId: json['agentSessionId'] as String?,
      environmentId: json['environmentId'] as String?,
      command: json['command'] as String?,
      stoppable: role != null && json['stoppable'] == true,
      ports: [
        for (final port in (json['ports'] as List?) ?? const [])
          if (port is Map) RunningPort.fromJson(port.cast()),
      ],
    );
  }
}

/// A sentence about what was not read, filed under its machine.
final class RunningNote {
  const RunningNote(this.text, {this.environmentId});

  final String text;
  final String? environmentId;

  Map<String, Object?> toJson() => {
    'text': text,
    'environmentId': ?environmentId,
  };

  factory RunningNote.fromJson(Map<String, Object?> json) => RunningNote(
    json['text'] as String? ?? '',
    environmentId: json['environmentId'] as String?,
  );
}

/// What one look found, and when.
final class RunningReading {
  const RunningReading({
    required this.serverPid,
    required this.processes,
    required this.checkedAt,
    this.notes = const [],
  });

  final int serverPid;
  final List<RunningProcess> processes;
  final DateTime checkedAt;
  final List<RunningNote> notes;

  Map<String, Object?> toJson() => {
    'serverPid': serverPid,
    'processes': [for (final process in processes) process.toJson()],
    'checkedAt': checkedAt.toUtc().toIso8601String(),
    'notes': [for (final note in notes) note.toJson()],
  };

  factory RunningReading.fromJson(Map<String, Object?> json) => RunningReading(
    serverPid: (json['serverPid'] as num?)?.toInt() ?? 0,
    processes: [
      for (final process in (json['processes'] as List?) ?? const [])
        if (process is Map) RunningProcess.fromJson(process.cast()),
    ],
    checkedAt:
        DateTime.tryParse(json['checkedAt'] as String? ?? '') ??
        DateTime.utc(1970),
    notes: [
      for (final note in (json['notes'] as List?) ?? const [])
        if (note is Map) RunningNote.fromJson(note.cast()),
    ],
  );
}
