// Dev servers: the TCP ports processes under a server-run pane listen on,
// read when asked (`terminals.listeningPorts`), never on a timer.

/// One listening socket owned by a process in a pane's process tree.
final class ListeningPort {
  const ListeningPort({
    required this.port,
    required this.address,
    required this.pid,
    required this.paneId,
    required this.terminalSessionId,
    required this.title,
    this.process,
    this.agentSessionId,
  });

  final int port;

  /// The bound address as the OS spells it: `127.0.0.1`, `::`, `0.0.0.0`…
  final String address;
  final int pid;

  /// The executable's name, when the OS said.
  final String? process;
  final String paneId;
  final String terminalSessionId;

  /// The pane's title as its screen reads it.
  final String title;

  /// The Karmashala session the pane runs, for an agent pane.
  final String? agentSessionId;

  /// Where a browser on this machine reaches it.
  String get url => 'http://localhost:$port';

  Map<String, Object?> toJson() => {
    'port': port,
    'address': address,
    'pid': pid,
    'process': process,
    'paneId': paneId,
    'terminalSessionId': terminalSessionId,
    'title': title,
    'agentSessionId': agentSessionId,
  };

  factory ListeningPort.fromJson(Map<String, Object?> json) => ListeningPort(
    port: (json['port']! as num).toInt(),
    address: json['address'] as String? ?? '',
    pid: (json['pid'] as num?)?.toInt() ?? 0,
    process: json['process'] as String?,
    paneId: json['paneId'] as String? ?? '',
    terminalSessionId: json['terminalSessionId'] as String? ?? '',
    title: json['title'] as String? ?? '',
    agentSessionId: json['agentSessionId'] as String?,
  );
}

/// What one look found, when, and what it could not see.
final class ListeningPortsReading {
  const ListeningPortsReading({
    required this.ports,
    required this.checkedAt,
    this.unread = const [],
  });

  final List<ListeningPort> ports;
  final DateTime checkedAt;

  /// Sentences naming what was not looked at or could not be read: a WSL or
  /// SSH pane, a probe that failed. Empty when every pane was read.
  final List<String> unread;

  Map<String, Object?> toJson() => {
    'ports': [for (final port in ports) port.toJson()],
    'checkedAt': checkedAt.toUtc().toIso8601String(),
    'unread': unread,
  };

  factory ListeningPortsReading.fromJson(Map<String, Object?> json) =>
      ListeningPortsReading(
        ports: [
          for (final port in (json['ports'] as List?) ?? const [])
            if (port is Map) ListeningPort.fromJson(port.cast()),
        ],
        checkedAt:
            DateTime.tryParse(json['checkedAt'] as String? ?? '') ??
            DateTime.utc(1970),
        unread: [
          for (final line in (json['unread'] as List?) ?? const [])
            if (line is String) line,
        ],
      );
}
