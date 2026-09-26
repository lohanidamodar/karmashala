part of 'remote_companion_gateway.dart';

// The session list and what a row on it is made of: refreshing it,
// subscribing to what it holds, turning a host snapshot into a summary, and
// the activity reading that sits under one.

Duration _nonNegative(Duration value) =>
    value.isNegative ? Duration.zero : value;

extension _GatewaySessions on RemoteCompanionGateway {
  Future<void> _refreshSessions() => _refreshing ??= _refreshSessionsNow()
      .whenComplete(() => _refreshing = null);

  Future<void> _refreshSessionsNow() async {
    final client = _client;
    if (client == null || !client.isConnected) return;
    List<CompanionSessionSummary> list;
    try {
      list = await listSessions();
    } on GatewayException {
      return;
    }
    for (final session in list) {
      await _ensureSubscribed(client, session.id);
    }
  }

  Future<void> _ensureSubscribed(
    CompanionClient client,
    String sessionId,
  ) async {
    if (_subscribed.contains(sessionId)) return;
    try {
      await client.subscribeSession(sessionId);
      _subscribed.add(sessionId);
    } on Object catch (error) {
      onLog?.call('subscribe $sessionId failed: $error');
    }
  }

  void _setSessions(List<CompanionSessionSummary> list) {
    _sessions = List.unmodifiable(list);
    if (!_sessionChanges.isClosed) _sessionChanges.add(_sessions!);
  }

  CompanionSessionSummary? _currentSummary(String sessionId) {
    for (final session in _sessions ?? const <CompanionSessionSummary>[]) {
      if (session.id == sessionId) return session;
    }
    return null;
  }

  /// What a snapshot claims of the user, as one word: an open prompt first —
  /// it is the one thing to act on — then a usage limit, then the rest.
  String? _attentionWordOf(RemoteSessionSnapshot snapshot) =>
      snapshot.attention == kAttentionNeedsApproval
      ? snapshot.attention
      : snapshot.usageLimit != null
      ? kAttentionUsageLimit
      : snapshot.attention;

  CompanionSessionSummary _summaryOf(
    RemoteSessionSnapshot snapshot, {
    Map<String, Object?>? raw,
  }) {
    final kind = _kindOf(_attentionWordOf(snapshot));
    CompanionAttention? attention;
    if (kind != null) {
      final previous = _currentSummary(snapshot.sessionId)?.attention;
      attention = previous != null && previous.kind == kind
          ? previous
          : CompanionAttention(kind: kind, at: _now().toUtc());
    }
    // The checkout facts the desktop card's third line is made of. They are
    // read straight off the row rather than through the typed snapshot: the
    // host that sends them is newer than this build's payload type, and a
    // host that does not simply leaves the line as it is today.
    String? text(String key) {
      final value = raw?[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    return CompanionSessionSummary(
      id: snapshot.sessionId,
      title: snapshot.title,
      // The host words the card's first line itself; an older host that
      // sent no label leaves only its own status word — the phone never
      // invents a claim about a process it cannot see.
      agentLabel: snapshot.agentLabel ?? snapshot.status.replaceAll('_', ' '),
      // The project the desktop's Explorer groups under, not the repository
      // inside it — one project holding several repos is one header here too.
      // Older hosts send no project, so the repository still answers.
      projectName:
          snapshot.projectName ?? snapshot.repositoryName ?? 'No project',
      projectId: snapshot.projectId ?? snapshot.repositoryId,
      projectPath: snapshot.projectPath,
      status: _statusOf(snapshot),
      live: snapshot.status == 'running',
      whereabouts: snapshot.whereabouts,
      branch: text('branch'),
      subPath: text('subPath'),
      worktree: raw?['worktree'] == true,
      lastActivityAt: _parseInstant(snapshot.lastActivityAt),
      attention: attention,
      deliveryStage: snapshot.stage,
      imported: snapshot.imported,
      archived: snapshot.archived,
      folderMissing: snapshot.folderMissing || raw?['folderMissing'] == true,
      attachments: snapshot.attachments,
      environmentBadge: snapshot.environmentBadge ?? text('environmentBadge'),
      environmentName: snapshot.environmentName ?? text('environmentName'),
      environmentId: snapshot.environmentId ?? text('environmentId'),
      environmentKind: snapshot.environmentKind ?? text('environmentKind'),
      model: snapshot.model,
      usageLimit: snapshot.usageLimit,
    );
  }

  /// An ISO-8601 instant off the wire, or null for anything unreadable — a
  /// missing age renders as nothing, never as a guess.
  DateTime? _parseInstant(String? iso) =>
      iso == null ? null : DateTime.tryParse(iso)?.toUtc();

  CompanionSessionStatus _statusOf(RemoteSessionSnapshot snapshot) {
    // A session that has ended says how, whatever its agent last did: an
    // agent's "idle" beside a cancelled row is a claim about nothing.
    switch (snapshot.status) {
      case 'completed':
        return CompanionSessionStatus.ended;
      case 'cancelled':
        return CompanionSessionStatus.stoppedByYou;
      case 'failed':
        return CompanionSessionStatus.failed;
      case 'unknown':
        return CompanionSessionStatus.unknown;
    }
    if (snapshot.attention == 'needs_approval') {
      return CompanionSessionStatus.needsYou;
    }
    if (snapshot.attention == 'failed') return CompanionSessionStatus.failed;
    return switch (snapshot.status) {
      // A running process is not a working agent: the agent's own status says
      // whether it is mid-turn or at rest at its prompt. Only when nobody
      // keeps one does the process's word stand.
      'running' => switch (snapshot.activity) {
        'idle' => CompanionSessionStatus.idle,
        'awaitingApproval' => CompanionSessionStatus.needsYou,
        'failed' => CompanionSessionStatus.failed,
        _ => CompanionSessionStatus.working,
      },
      'idle' || 'created' => CompanionSessionStatus.idle,
      _ => CompanionSessionStatus.unknown,
    };
  }

  CompanionAttentionKind? _kindOf(String? attention) => switch (attention) {
    null => null,
    'needs_approval' => CompanionAttentionKind.needsYou,
    'failed' => CompanionAttentionKind.failed,
    'finished' => CompanionAttentionKind.finished,
    kAttentionUsageLimit => CompanionAttentionKind.usageLimit,
    // A claim this build predates; "needs you" is the only safe reading of
    // a claim on the user.
    _ => CompanionAttentionKind.needsYou,
  };

  /// Reads the current activity from the host, and words its refusal when it
  /// has one. A pairing without `view_activity` is refused in a sentence, never
  /// an empty list, which would say the session is running nothing.
  Future<void> _primeActivity(String sessionId) async {
    try {
      await _ready;
      final client = _client;
      if (client == null) return;
      final activity = await client.activity(sessionId);
      _acceptActivity(activity);
    } on RemoteApiException catch (error) {
      _activityOf(sessionId).value = CompanionActivity(
        at: _now(),
        refused: error.message,
      );
    } on Object catch (error) {
      onLog?.call('activity for a session could not be read: $error');
    }
  }

  /// Folds one `session.activity` reading in, whether it was asked for or
  /// stated.
  void _acceptActivity(RemoteSessionActivity activity) {
    _activityOf(activity.sessionId).value = CompanionActivity(
      at: _now(),
      absence: activity.absence,
      calls: [
        for (final call in activity.calls)
          CompanionActivityCall(
            summary: call.summary,
            subagent: call.subagent,
            // Both instants are the host's, so this duration is the one number
            // here that needs no clock of ours.
            elapsed: _nonNegative(
              activity.observedAt.difference(call.startedAt),
            ),
          ),
      ],
    );
  }

  _Watched<CompanionActivity> _activityOf(String sessionId) =>
      _activity[sessionId] ??= _Watched(CompanionActivity.unknown);

  void _ensureCurrentClient(CompanionClient client) {
    if (identical(_client, client)) return;
    // A make-before-break promotion swaps the link under a request in flight
    // without changing the machine, and the answer that just came back is
    // still this host's. Only a different host is news the caller needs.
    if (_client?.pairing.hostId == client.pairing.hostId) return;
    throw const GatewayException(
      'The active machine changed while this request was in flight. Nothing '
      'was applied to the new one.',
    );
  }
}
