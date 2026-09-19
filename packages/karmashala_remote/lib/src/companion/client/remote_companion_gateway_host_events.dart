part of 'remote_companion_gateway.dart';

// What the host says on its own, and what the phone does about it: the frame
// switch, the `host.status` that refreshes where the desktop can be met, the
// session snapshot that becomes a row, and the attention it may claim.

extension _GatewayHostEvents on RemoteCompanionGateway {
  void _onEvent(CompanionEvent event) {
    switch (event) {
      case SessionChangedEvent(:final snapshot, :final raw):
        _applySnapshot(snapshot, raw: raw);
      case TranscriptAppendedEvent(:final page):
        _applyAppended(page);
      case SessionActivityEvent(:final activity):
        _acceptActivity(activity);
      case ApprovalRequestedEvent(:final request):
        _applyApproval(request);
      case ApprovalResolvedEvent(:final resolution):
        _retireApproval(
          resolution.sessionId,
          switch (resolution.outcome) {
            RemoteApprovalOutcome.approved =>
              CompanionApprovalOutcome.approved,
            RemoteApprovalOutcome.denied => CompanionApprovalOutcome.denied,
            RemoteApprovalOutcome.elsewhere =>
              CompanionApprovalOutcome.elsewhere,
            RemoteApprovalOutcome.answered =>
              CompanionApprovalOutcome.answered,
          },
        );
      case PairingRevokedEvent():
        // The one case where silence would have been read as a busy desktop.
        // Now it is a fact, so the link stops claiming anything else.
        _revoked = true;
        onLog?.call('the host revoked this pairing; the link is over');
        _link.value = CompanionLinkState.disconnected;
        _declareDead();
      case HostStatusEvent(:final status):
        _lastHostStatus = status;
        // The greeting that opens a connection arrives while the client is
        // still about to persist its own record, so applying it here would be
        // overwritten; the connect loop applies it once the link is up.
        if (_link.value == CompanionLinkState.connected) {
          unawaited(_applyHostStatus(status));
        }
    }
  }

  /// The refresh that removes re-pairing for good: the host says where it can
  /// be met and this phone's saved candidates become that, health carried over
  /// for the relays that survive. An empty announcement changes nothing.
  Future<void> _applyHostStatus(RemoteHostStatus status) async {
    final record = _record;
    if (record == null || _closed) return;
    if (status.relays.isEmpty && status.lanHint == null) return;
    final merged = mergeRelayCandidates(record.candidates, status.relays);
    final sameRelays =
        merged.length == record.candidates.length &&
        !merged.indexed.any((e) => e.$2.key != record.candidates[e.$1].key);
    final hint = status.lanHint ?? record.lanHint;
    if (sameRelays && hint == record.lanHint) return;
    try {
      _all = await stored.CompanionConnections.mutate(store, (all) {
        final saved = all.byHost(record.hostId.value);
        if (saved == null) return all;
        all.upsert(
          saved.copyWith(
            candidates: mergeRelayCandidates(saved.candidates, status.relays),
            lanHint: hint,
          ),
        );
        return all;
      });
      if (_all.activeHostId?.value == record.hostId.value) {
        _record = _all.active ?? _record;
      }
      onLog?.call('saved relay candidates refreshed from host.status');
    } on Object catch (error) {
      onLog?.call('relay candidate refresh failed: $error');
    }
  }

  void _applySnapshot(
    RemoteSessionSnapshot snapshot, {
    Map<String, Object?>? raw,
  }) {
    // Archived rows stay listed and say so; the desktop still holds them.
    final summary = _summaryOf(snapshot, raw: raw);
    final current = _sessions ?? const <CompanionSessionSummary>[];
    final next = <CompanionSessionSummary>[];
    var found = false;
    for (final session in current) {
      if (session.id == snapshot.sessionId) {
        found = true;
        next.add(summary);
      } else {
        next.add(session);
      }
    }
    if (!found) {
      // A late arrival goes where the host would have put it, not on the end:
      // beside its own project's rows, so the list does not reshuffle under
      // the user's thumb. A refresh then restores the host's exact order.
      next.insert(_placeFor(next, summary), summary);
    }
    _setSessions(next);
    // Re-derived, never accumulated: every snapshot carries whether the session
    // is still asking, so a card the phone kept through a dead link is retired
    // the moment it hears the truth again.
    if (snapshot.attention != kAttentionNeedsApproval) {
      _retireApproval(snapshot.sessionId, CompanionApprovalOutcome.elsewhere);
    }
    _noteAttention(snapshot.sessionId, snapshot.attention, snapshot.title);
    if (!found) {
      final client = _client;
      if (client != null) {
        unawaited(_ensureSubscribed(client, snapshot.sessionId));
        // Re-read so the newcomer lands in the host's own ordering.
        unawaited(_refreshSessions());
      }
    }
  }

  /// Where a session the list has never held belongs: after the last row of
  /// its own project, or at the end when that project is new here too.
  int _placeFor(
    List<CompanionSessionSummary> list,
    CompanionSessionSummary arrival,
  ) {
    var place = list.length;
    for (var i = 0; i < list.length; i++) {
      if (list[i].projectKey == arrival.projectKey) place = i + 1;
    }
    return place;
  }

  void _noteAttention(String sessionId, String? attention, String title) {
    final previous = _lastAttention[sessionId];
    if (previous == attention) return;
    _lastAttention[sessionId] = attention;
    final kind = _kindOf(attention);
    if (kind == null || _attention.isClosed) return;
    _attention.add(
      CompanionAttentionEvent(
        sessionId: sessionId,
        sessionTitle: title,
        kind: kind,
        at: _now().toUtc(),
        // Stamped from the host that is live right now. v1 keeps exactly one
        // link, so news can only come from the active desktop — carrying the
        // id is what lets a late event be checked against it after a switch.
        hostId: _record?.hostId.value,
      ),
    );
  }

  /// Marks one listed session as claiming attention — the coupling the
  /// host's own `session.changed` produces when its list already knows.
  void _stampAttention(String sessionId, CompanionAttentionKind kind) {
    final current = _sessions;
    if (current == null) return;
    var changed = false;
    final next = <CompanionSessionSummary>[];
    for (final session in current) {
      if (session.id != sessionId || session.attention?.kind == kind) {
        next.add(session);
        continue;
      }
      changed = true;
      next.add(
        session.copyWith(
          status: switch (kind) {
            CompanionAttentionKind.needsYou => CompanionSessionStatus.needsYou,
            CompanionAttentionKind.failed => CompanionSessionStatus.failed,
            CompanionAttentionKind.finished => session.status,
          },
          attention: CompanionAttention(kind: kind, at: _now().toUtc()),
        ),
      );
    }
    if (changed) _setSessions(next);
  }
}
