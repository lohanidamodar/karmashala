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

  /// Tells the one client a window's intent, as the server would.
  void tellIntent(ClientIntent intent) => _server._tell(null, [intent]);

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
            (throw const DataRefused.notFound('This session no longer exists.'));
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
      case SessionForkFromCheckpoint():
        throw const DataRefused.invalid('not scripted');
    }
  }

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
    final worktree = spec.existingWorktree ??
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
          (spec.forkConversationId == null && _assignsOwnId(spec)
              ? id
              : null),
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
      throw DataRefused(
        DataRefusalCode.failed,
        'could not start $agentId',
      );
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

  AgentPaneLaunch _launchOf(Session row) {
    final installation = _server.installationRows.getById(
      row.agentInstallationId,
    );
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
