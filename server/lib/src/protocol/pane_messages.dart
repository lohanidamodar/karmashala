part of 'messages.dart';

// The app's terminal panes, as facts (slice 2b): only the app sees a pane's
// OSC 133 command blocks and the directory its shell reports — it renders
// host-backed panes too — so it reports them, and the server decides what
// they mean (adopting a CLI session a person started by hand, reading a
// pane's last rows for the resume line an agent prints). Nothing here knows
// an agent.

/// One terminal pane of a client's, as the client saw it last.
class PaneFacts {
  const PaneFacts({
    required this.paneId,
    required this.live,
    this.workingDirectory,
    this.hostsLaunchedSession = false,
    this.lastCommandId,
    this.lastCommandLine,
    this.lastCommandRunning = true,
    this.tail,
  });

  final String paneId;

  /// Where the pane's shell is, or null when it never said.
  final String? workingDirectory;

  /// Whether a process runs behind the pane.
  final bool live;

  /// Whether the client opened this pane to run a session it already has a
  /// row for — never adopted.
  final bool hostsLaunchedSession;

  /// The newest OSC 133 command block's id, or null for a shell with no
  /// integration or one that has run nothing yet.
  final String? lastCommandId;

  /// That block's command line, once the shell said it runs.
  final String? lastCommandLine;

  /// Whether that block still runs. True when the shell is mute.
  final bool lastCommandRunning;

  /// The pane's bottom rows as plain text — only when the server asked for
  /// them ([PaneTailsWantedMessage]), and never for a pane replayed from a
  /// record (nothing ran in it).
  final List<String>? tail;

  PaneFacts withoutTail() => tail == null
      ? this
      : PaneFacts(
          paneId: paneId,
          live: live,
          workingDirectory: workingDirectory,
          hostsLaunchedSession: hostsLaunchedSession,
          lastCommandId: lastCommandId,
          lastCommandLine: lastCommandLine,
          lastCommandRunning: lastCommandRunning,
        );

  Map<String, Object?> toJson() => {
    'paneId': paneId,
    'live': live,
    'workingDirectory': ?workingDirectory,
    if (hostsLaunchedSession) 'hostsLaunchedSession': true,
    'lastCommandId': ?lastCommandId,
    'lastCommandLine': ?lastCommandLine,
    if (!lastCommandRunning) 'lastCommandRunning': false,
    'tail': ?tail,
  };

  static PaneFacts fromJson(Object? json) {
    final map = _object(json, 'pane');
    final tail = map['tail'];
    if (tail != null && (tail is! List || tail.any((row) => row is! String))) {
      throw const WireFormatException('"tail" is not a list of rows');
    }
    return PaneFacts(
      paneId: _required<String>(map, 'paneId'),
      live: _required<bool>(map, 'live'),
      workingDirectory: _optional<String>(map, 'workingDirectory'),
      hostsLaunchedSession:
          _optional<bool>(map, 'hostsLaunchedSession') ?? false,
      lastCommandId: _optional<String>(map, 'lastCommandId'),
      lastCommandLine: _optional<String>(map, 'lastCommandLine'),
      lastCommandRunning: _optional<bool>(map, 'lastCommandRunning') ?? true,
      tail: tail == null ? null : List<String>.unmodifiable(tail as List),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PaneFacts &&
      other.paneId == paneId &&
      other.workingDirectory == workingDirectory &&
      other.live == live &&
      other.hostsLaunchedSession == hostsLaunchedSession &&
      other.lastCommandId == lastCommandId &&
      other.lastCommandLine == lastCommandLine &&
      other.lastCommandRunning == lastCommandRunning &&
      _sameRows(other.tail, tail);

  @override
  int get hashCode => Object.hash(
    paneId,
    workingDirectory,
    live,
    hostsLaunchedSession,
    lastCommandId,
    lastCommandLine,
    lastCommandRunning,
    tail == null ? null : Object.hashAll(tail!),
  );

  static bool _sameRows(List<String>? a, List<String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'PaneFacts($paneId${live ? ' live' : ''}'
      '${lastCommandLine == null ? '' : ' "$lastCommandLine"'})';
}

/// client → host: every terminal pane the client has now — the whole list,
/// each time it changes, so the host keeps no history of a client's panes
/// and forgets them all when the link ends.
class PaneFactsMessage extends HostMessage {
  const PaneFactsMessage(this.panes);

  final List<PaneFacts> panes;

  @override
  Frame toFrame() => _jsonFrame(MessageType.paneFacts, {
    'panes': [for (final pane in panes) pane.toJson()],
  });

  static PaneFactsMessage decode(Frame frame) {
    final body = _jsonPayload(frame, 'pane facts');
    final panes = body['panes'];
    if (panes is! List) {
      throw const WireFormatException('"panes" is missing or not a list');
    }
    return PaneFactsMessage([
      for (final pane in panes) PaneFacts.fromJson(pane),
    ]);
  }
}

/// host → client: send the bottom [lines] rows of each of [paneIds] with the
/// next [PaneFactsMessage] — once; the host asks again when it wants them
/// again.
class PaneTailsWantedMessage extends HostMessage {
  const PaneTailsWantedMessage({required this.paneIds, required this.lines});

  final List<String> paneIds;
  final int lines;

  @override
  Frame toFrame() => _jsonFrame(MessageType.paneTailsWanted, {
    'paneIds': paneIds,
    'lines': lines,
  });

  static PaneTailsWantedMessage decode(Frame frame) {
    final body = _jsonPayload(frame, 'pane tails wanted');
    final ids = body['paneIds'];
    if (ids is! List || ids.any((id) => id is! String)) {
      throw const WireFormatException('"paneIds" is not a list of ids');
    }
    return PaneTailsWantedMessage(
      paneIds: List<String>.unmodifiable(ids),
      lines: _required<int>(body, 'lines'),
    );
  }
}
