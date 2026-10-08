part of 'fake_data_server.dart';

/// The server's one launch path (slice 5b), in memory: what a client asked
/// to start, resume, hand off, fork or end, and the rows it wrote. Nothing is
/// spawned; what the server's decisions are is tested in
/// `server/test/sessions/launch/`.
class FakeSessionWork {
  FakeSessionWork._(this._server);

  final FakeDataServer _server;

  /// Every request, in order.
  final asked = <SessionWorkRequest<Object?>>[];

  /// Sessions the server runs now, by row id.
  final running = <String>{};

  /// Set to refuse the next requests in these words.
  String? refuseWith;

  /// Agent ids whose process will not start: the server writes the row, marks
  /// it failed, and refuses — a partial launch.
  Set<String> failsFor = const {};

  var _ids = 0;

  /// How the server names a new row; `started-<n>` unless a test says.
  String Function()? newId;

  /// Whether `sessions.send` and `sessions.interrupt` are taken here: into a
  /// session the server runs ([running]), answered as sent over its
  /// protocol; refused `notFound` for one it does not run, as the server
  /// refuses. Off, every send is refused as unavailable, as it always was.
  bool typesSends = false;

  /// Every `sessions.send` taken, in order.
  final sent = <SessionSend>[];

  /// A send to a session it does not run resumes it first, as a server that
  /// announces `sessions.send.resumes` does; off, it is refused `notFound`.
  bool resumesOnSend = false;

  /// Set to refuse a send's resume in these words, as the server refuses an
  /// agent that would not start — a login it asks for first.
  String? resumeOnSendRefusesWith;

  /// Tells the one client a window's intent, as the server would.
  void tellIntent(ClientIntent intent) => _server._tell(null, [intent]);

  /// Sessions mid-turn: a send to one is queued (`sessions.queue`), as the
  /// server queues it.
  final busy = <String>{};

  /// Set to refuse `sessions.queue.sendNext` in these words, as the server
  /// refuses a resume that would not start.
  String? sendNextRefusesWith;

  /// What each session holds queued, in order.
  final queues = <String, List<QueuedMessage>>{};

  var _queuedIds = 0;

  /// Every queue request, in order.
  final queueAsked = <SessionInputRequest<Object?>>[];

  /// The turn of [sessionId] ended: its head is delivered, as the server's
  /// queue delivers one per turn.
  void deliverHead(String sessionId) {
    final queue = queues[sessionId] ?? [];
    if (queue.isEmpty) return;
    final head = queue.removeAt(0);
    sent.add(SessionSend(sessionId: sessionId, text: head.text));
    _tellQueue(sessionId, delivered: [head.id]);
  }

  /// What holds each session's queue, marked on its queued messages.
  final holds = <String, QueueHold>{};

  /// The server holds [sessionId]'s queue for [hold], or lets it go.
  void holdQueue(String sessionId, QueueHold? hold) {
    if (hold == null) {
      holds.remove(sessionId);
    } else {
      holds[sessionId] = hold;
    }
    _tellQueue(sessionId);
  }

  List<QueuedMessage> _told(String sessionId) {
    final hold = holds[sessionId];
    return [
      for (final message in queues[sessionId] ?? const <QueuedMessage>[])
        hold != null && message.state == QueuedMessageState.queued
            ? message.copyWith(hold: hold)
            : message,
    ];
  }

  void _tellQueue(String sessionId, {List<String> delivered = const []}) =>
      _server._tell(null, [
        SessionQueueChanged(
          sessionId: sessionId,
          messages: _told(sessionId),
          delivered: delivered,
        ),
      ]);

  Object? _queueRequest(SessionInputRequest<Object?> request) {
    queueAsked.add(request);
    final queue = queues[request.sessionId] ??= [];
    switch (request) {
      case SessionQueueList():
        return _told(request.sessionId);
      case SessionQueueEdit(:final id, :final text):
        final at = queue.indexWhere((m) => m.id == id);
        if (at < 0) throw const DataRefused.notFound('no such message');
        final edited = queue[at] = queue[at].copyWith(text: text);
        _tellQueue(request.sessionId);
        return edited;
      case SessionQueueCancel(:final id):
        final at = queue.indexWhere((m) => m.id == id);
        if (at < 0) throw const DataRefused.notFound('no such message');
        final cancelled = queue
            .removeAt(at)
            .copyWith(state: QueuedMessageState.cancelled);
        _tellQueue(request.sessionId);
        return cancelled;
      case SessionQueueSendNext(:final sessionId):
        if (sendNextRefusesWith case final words?) {
          throw DataRefused(DataRefusalCode.failed, words);
        }
        if (queue.isEmpty) {
          throw const DataRefused.notFound('nothing waits in this queue');
        }
        final head = queue.removeAt(0);
        running.add(sessionId);
        sent.add(SessionSend(sessionId: sessionId, text: head.text));
        _tellQueue(sessionId);
        return head.copyWith(state: QueuedMessageState.delivered);
      case SessionQueueSendNow(:final sessionId, :final id):
        final at = queue.indexWhere((m) => m.id == id);
        if (at < 0) throw const DataRefused.notFound('no such message');
        final message = queue.removeAt(at);
        sent.add(SessionSend(sessionId: sessionId, text: message.text));
        _tellQueue(sessionId);
        return message.copyWith(state: QueuedMessageState.delivered);
      case SessionQueueSendAll(:final sessionId):
        if (queue.isEmpty) {
          throw const DataRefused.notFound('nothing waits in this queue');
        }
        final all = [...queue];
        queue.clear();
        sent.add(
          SessionSend(
            sessionId: sessionId,
            text: [for (final m in all) m.text].join('\n\n'),
          ),
        );
        _tellQueue(sessionId);
        return [
          for (final m in all) m.copyWith(state: QueuedMessageState.delivered),
        ];
      case SessionQueuePause(:final sessionId, :final paused):
        holdQueue(
          sessionId,
          paused ? const QueueHold(QueueHoldKind.paused) : null,
        );
        return _told(sessionId);
      case SessionSend() || SessionInterrupt():
        return null;
    }
  }

  Object? _input(SessionInputRequest<Object?> request) {
    if (request
        case SessionQueueList() ||
            SessionQueueEdit() ||
            SessionQueueCancel() ||
            SessionQueueSendNext() ||
            SessionQueueSendNow() ||
            SessionQueueSendAll() ||
            SessionQueuePause()) {
      return _queueRequest(request);
    }
    if (request case SessionSend(
      :final sessionId,
      :final text,
    ) when typesSends && busy.contains(sessionId)) {
      final queue = queues[sessionId] ??= [];
      final message = QueuedMessage(
        id: 'q${++_queuedIds}',
        sessionId: sessionId,
        seq: queue.length + 1,
        text: text,
        state: QueuedMessageState.queued,
        origin: QueuedMessageOrigin.app,
        createdAt: DateTime.utc(2026, 10, 3),
        updatedAt: DateTime.utc(2026, 10, 3),
      );
      queue.add(message);
      _tellQueue(sessionId);
      return SessionSent(
        sent: true,
        via: SessionSent.queuedVia,
        queuedId: message.id,
        position: queue.length,
      );
    }
    if (!typesSends) {
      throw const DataRefused.unavailable('this fake types into no sessions');
    }
    final sessionId = request.sessionId;
    var resumed = false;
    if (!running.contains(sessionId)) {
      final row = _server.sessionRows.getById(sessionId);
      if (request is! SessionSend || !resumesOnSend || row == null) {
        throw const DataRefused.notFound('this session is not running here');
      }
      if (resumeOnSendRefusesWith case final words?) {
        throw DataRefused(DataRefusalCode.failed, words);
      }
      // As a server that resumes on send (`sessions.send.resumes`).
      running.add(sessionId);
      _server.sessionRows.put(row.copyWith(status: SessionStatus.running));
      resumed = true;
    }
    if (request case final SessionSend send) {
      sent.add(send);
      return SessionSent(sent: true, via: 'protocol', resumed: resumed);
    }
    return const DataAck();
  }

  Object? _handle(SessionWorkRequest<Object?> request) {
    asked.add(request);
    final refusal = refuseWith;
    if (refusal != null) throw DataRefused.invalid(refusal);
    switch (request) {
      case SessionStart(:final spec):
        return _start(spec);
      case final SessionResume r:
        final row =
            _server.sessionRows.getById(r.sessionId) ??
            (throw const DataRefused.notFound(
              'This session no longer exists.',
            ));
        final conversation = row.externalSessionId;
        if (r.restart && (conversation == null || conversation.isEmpty)) {
          throw const DataRefused.invalid(
            'The agent has not named a conversation for this session yet, so '
            'restarting it would open a new conversation instead of '
            'continuing this one.',
          );
        }
        if (running.contains(row.id) && !r.restart) {
          return SessionStarted(
            session: row,
            launch: _launchOf(row),
            adopted: true,
          );
        }
        running.add(row.id);
        final resumed = row.copyWith(status: SessionStatus.running);
        _server.sessionRows.put(resumed);
        return SessionStarted(session: resumed, launch: _launchOf(resumed));
      case SessionEndRequest(:final sessionId):
        if (!running.remove(sessionId)) {
          throw const DataRefused.notFound('Nothing is running that session.');
        }
        return const DataAck();
      case SessionSourceBrief():
        return const HandoffSourceBrief.notWritten('nobody is there to ask.');
      case final SessionHandoffPreview r:
        return 'packet for ${r.targetAgentName}: ${r.instruction}';
      case final SessionHandoff r:
        final source = _server.sessionRows.getById(r.sessionId)!;
        return _start(
          SessionStartSpec(
            repositoryId: source.repositoryId,
            installationId: r.targetInstallationId,
            title: '${source.title} · handoff',
            parentSessionId: source.id,
            parentLink: SessionLink.handoff,
          ),
        );
      case final SessionFork r:
        final source = _server.sessionRows.getById(r.sessionId)!;
        return _start(
          SessionStartSpec(
            repositoryId: source.repositoryId,
            installationId: source.agentInstallationId,
            title: '${source.title} (fork)',
            parentSessionId: source.id,
            parentLink: SessionLink.fork,
          ),
        );
      case final SessionSwitchAgent r:
        switches.add(r);
        final before = _server.sessionRows.getById(r.sessionId)!;
        _server.sessionRows.put(
          before.copyWith(agentInstallationId: r.targetInstallationId),
        );
        final row = _server.sessionRows.getById(r.sessionId)!;
        return SessionStarted(session: row, launch: _launchOf(row));
      case SessionForkFromCheckpoint():
        throw const DataRefused.invalid('not scripted');
    }
  }

  /// Every switch asked of the server, in order.
  final switches = <SessionSwitchAgent>[];

  SessionStarted _start(SessionStartSpec spec) {
    // A conversation the server already runs is answered as it is.
    final conversation = spec.resumeConversationId;
    if (conversation != null && spec.restartSessionId == null) {
      for (final row in _server.sessionRows.getAll()) {
        if (row.externalSessionId == conversation &&
            row.repositoryId == spec.repositoryId &&
            running.contains(row.id)) {
          return SessionStarted(
            session: row,
            launch: _launchOf(row),
            adopted: true,
          );
        }
      }
    }
    // A resume or a restart continues its row, as the server's does.
    final reused = spec.restartSessionId != null
        ? _server.sessionRows.getById(spec.restartSessionId!)
        : conversation == null
        ? null
        : _server.sessionRows
              .getAll()
              .where(
                (row) =>
                    row.externalSessionId == conversation &&
                    row.repositoryId == spec.repositoryId &&
                    row.agentInstallationId == spec.installationId &&
                    !running.contains(row.id),
              )
              .firstOrNull;
    if (reused != null) {
      final continued = reused.copyWith(
        status: SessionStatus.running,
        permissionMode: spec.permissionMode,
        modelId: spec.modelId,
      );
      _server.sessionRows.put(continued);
      running.add(continued.id);
      return SessionStarted(session: continued, launch: _launchOf(continued));
    }
    final id = newId?.call() ?? 'started-${++_ids}';
    final named = newSessionTitle(spec.title, typed: spec.titleTyped);
    final repository = _server.repositoryRows.getById(spec.repositoryId);
    // A worktree of its own is the server's to make; here it is named, as
    // the server's `sessionWorktreeName` names it, and not created.
    final worktree =
        spec.existingWorktree ??
        (spec.worktree && repository != null
            ? EnvironmentPath(
                environmentId: repository.path.environmentId,
                path: '${repository.path.path}-worktrees/$id',
              )
            : null);
    final row = Session(
      id: id,
      repositoryId: spec.repositoryId,
      agentInstallationId: spec.installationId,
      title: named.title,
      titleByUser: named.byUser,
      useWorktree: worktree != null,
      worktree: worktree,
      workingDirectory: worktree ?? spec.workingDirectory ?? repository?.path,
      status: SessionStatus.running,
      createdAt: _server._now(),
      // As for an agent that takes our id (Claude Code): a new conversation
      // is named after its row; a fork's is the CLI's to mint.
      externalSessionId:
          spec.resumeConversationId ??
          (spec.forkConversationId == null && _assignsOwnId(spec) ? id : null),
      parentSessionId: spec.parentSessionId,
      parentLink: spec.parentLink,
      permissionMode: spec.permissionMode,
      modelId: spec.modelId,
      surface: spec.surface,
    );
    final agentId = _server.installationRows
        .getById(spec.installationId)
        ?.agentId;
    if (failsFor.contains(agentId)) {
      _server.sessionRows.insert(row.copyWith(status: SessionStatus.failed));
      throw DataRefused(DataRefusalCode.failed, 'could not start $agentId');
    }
    _server.sessionRows.insert(row);
    running.add(id);
    return SessionStarted(session: row, launch: _launchOf(row));
  }

  bool _assignsOwnId(SessionStartSpec spec) {
    final agentId = _server.installationRows
        .getById(spec.installationId)
        ?.agentId;
    return agentId != null &&
        (AgentRegistry.builtIn
                .byId(agentId)
                ?.launch
                .sessionIdAssignment
                .isSupported ??
            false);
  }

  /// Null for an agent spoken to over ACP, as the server answers: it runs the
  /// agent itself, so there is no terminal for a pane to attach to.
  AgentPaneLaunch? _launchOf(Session row) {
    final installation = _server.installationRows.getById(
      row.agentInstallationId,
    );
    final agentId = installation?.agentId;
    if (agentId != null &&
        AgentRegistry.builtIn.adapterFor(agentId)?.acp != null) {
      return null;
    }
    final directory =
        row.workingDirectory ??
        row.worktree ??
        _server.repositoryRows.getById(row.repositoryId)?.path;
    return AgentPaneLaunch(
      agentId: installation?.agentId ?? 'claudeCode',
      executable: installation?.executable.path ?? 'claude',
      workingDirectory: directory?.path,
      sessionId: row.id,
      title: row.title,
    );
  }
}
