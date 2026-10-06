part of 'fake_data_server.dart';

/// The server's terminals (slice 5a), in memory: what a client asked for,
/// the profiles it is offered, and the records the server keeps. Nothing is
/// spawned — a pane test that needs a real terminal attaches to a real host.
class FakeTerminalsWork {
  FakeTerminalsWork._(this._server);

  final FakeDataServer _server;

  /// What `terminals.profiles` answers; a POSIX login shell by default.
  List<TerminalProfile> profiles = [
    TerminalProfile.posix('/bin/zsh', isLoginShell: true),
  ];

  /// Every `terminals.open` asked, in order.
  final opened = <TerminalOpen>[];

  /// Every `terminals.close` asked, by session id.
  final closed = <String>[];

  /// The records the server holds, by session id.
  final records = <String, TerminalRecord>{};

  /// Set to refuse the next opens in these words.
  String? refuseWith;

  /// Seeds a terminal the server runs, as if started before the test.
  void seed(TerminalRecord record) {
    records[record.sessionId] = record;
    _server._tell(null, [TerminalChanged(record)]);
  }

  /// Terminal [sessionId] closed by somebody else — `terminal_close`, another
  /// window, a phone — or, with [closed] false, its ended record pruned.
  void remove(String sessionId, {bool closed = true}) {
    records.remove(sessionId);
    _server._tell(null, [TerminalRemoved(sessionId, closed: closed)]);
  }

  Object? _handle(TerminalWorkRequest<Object?> request) {
    switch (request) {
      case TerminalsProfiles():
        return profiles;
      case final TerminalOpen open:
        final refusal = refuseWith;
        if (refusal != null) {
          throw DataRefused(DataRefusalCode.failed, refusal);
        }
        opened.add(open);
        final own = terminalSessionId(
          paneId: open.paneId,
          agentSessionId: open.agentLaunch?.sessionId,
        );
        // A box's terminal is named `ssh:<hostId>/<id>` at the server (5d).
        final environment = open.environmentId;
        final boxHost =
            open.agentLaunch?.sshHostId ??
            (environment != null && environment.startsWith('ssh:')
                ? environment.substring('ssh:'.length)
                : null);
        final sessionId = boxHost == null ? own : 'ssh:$boxHost/$own';
        final existing = records[sessionId];
        final adopted = existing != null && existing.isLive;
        final record =
            existing ??
            TerminalRecord(
              sessionId: sessionId,
              paneId: open.paneId,
              profileId: open.agentLaunch?.profileId ?? open.profileId ?? '',
              title: open.agentLaunch?.title ?? 'Terminal',
              startedAt: _server._now(),
            );
        if (!adopted) seed(record);
        return TerminalOpened(
          sessionId: sessionId,
          paneId: open.paneId,
          title: record.title,
          profileId: record.profileId,
          shellIntegration: false,
          adopted: adopted,
        );
      case TerminalsList():
        return records.values.toList();
      case TerminalClose(:final sessionId):
        closed.add(sessionId);
        if (records.remove(sessionId) == null) {
          throw DataRefused.notFound('no terminal $sessionId');
        }
        _server._tell(null, [TerminalRemoved(sessionId, closed: true)]);
      case TerminalRename(:final sessionId, :final title):
        final record = records[sessionId];
        if (record == null) throw DataRefused.notFound('no terminal $sessionId');
        seed(record.copyWith(title: title));
      case TerminalsListeningPorts():
        return ListeningPortsReading(
          ports: const [],
          checkedAt: _server._now(),
        );
    }
    return const DataAck();
  }
}
