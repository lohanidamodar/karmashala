part of 'remote_companion_gateway.dart';

// The saved desktops: loading them at launch, publishing the list, and making
// one of them the active host — which clears everything the last one left.

extension _GatewayConnections on RemoteCompanionGateway {
  Future<void> _loadStoredPairing() async {
    // Migrates a pre-multi-host store transparently: the single record it
    // holds becomes the sole saved connection, active.
    stored.CompanionConnections all;
    try {
      all = await stored.CompanionConnections.load(store);
    } on Object catch (error) {
      // Every public method awaits `_ready`, so a throw here would not merely
      // leave the phone unpaired — it would leave it *unusable*, silently,
      // for the rest of the launch. Start empty and say what happened.
      onLog?.call('reading the saved pairings failed: $error');
      all = stored.CompanionConnections();
    }
    if (_closed) return;
    _all = all;
    final record = all.active;
    _record = record;
    _pairing.value = record == null ? null : _publicPairing(record);
    _publishConnections();
    if (record != null) _startLoop();
  }

  void _publishConnections() => _connections.value = List.unmodifiable([
    for (final record in _all.records)
      CompanionConnection(
        hostId: record.hostId.value,
        name: record.hostName.isEmpty ? 'Desktop' : record.hostName,
        active: record.hostId.value == _all.activeHostId?.value,
        lastConnectedAt: record.lastConnectedAt,
      ),
  ]);

  /// Stamps "last connected" on the host that just came up, so the
  /// Connections list can order and label it. Best-effort: a store that
  /// refuses the write must never break a working link.
  Future<void> _noteConnected(stored.CompanionPairing record) async {
    try {
      _all = await stored.CompanionConnections.mutate(store, (all) {
        final saved = all.byHost(record.hostId.value);
        if (saved != null) all.upsert(saved.withLastConnected(_now()));
        return all;
      });
      if (_all.activeHostId?.value == record.hostId.value) {
        _record = _all.active ?? _record;
      }
      _publishConnections();
    } on Object catch (error) {
      onLog?.call('last-connected stamp failed: $error');
    }
  }

  CompanionPairing _publicPairing(stored.CompanionPairing record) =>
      CompanionPairing(
        capabilities: record.capabilities,
        hostName: record.hostName.isEmpty ? null : record.hostName,
        hostId: record.hostId,
      );

  /// Drops the current link and rebuilds every derived state for [record] —
  /// or for no host at all when it is null. Nothing from the old desktop may
  /// bleed into the new one, so the session list, subscriptions, transcripts,
  /// approvals and attention baselines are all cleared before the dial.
  Future<void> _becomeActive(stored.CompanionPairing? record) async {
    _record = record;
    _pairing.value = record == null ? null : _publicPairing(record);
    _publishConnections();
    // Connecting, not disconnected: the user asked for this desktop, and a
    // "host unreachable" banner before anything was tried would be a lie.
    _switching = record != null;
    if (_switching) _link.value = CompanionLinkState.connecting;
    await _dropLink(keepState: _switching);
    _resetHostState();
    if (record == null) {
      _switching = false;
      _link.value = CompanionLinkState.disconnected;
      return;
    }
    _resetBackoff();
    _startLoop();
  }

  /// Everything the gateway holds that belongs to ONE host.
  void _resetHostState() {
    // A verdict about reaching THAT desktop says nothing about this one.
    _lanUpgradeRefused.clear();
    _unanswered = 0;
    _sessions = null;
    _hostOrder.clear();
    if (!_sessionChanges.isClosed) _sessionChanges.add(const []);
    _subscribed.clear();
    _lastAttention.clear();
    for (final approval in _approvals.values) {
      approval.value = null;
    }
    _approvals.clear();
    // A reading of another desktop is not a reading of this one, and an empty
    // list here would be the confident nothing the whole feature refuses.
    for (final activity in _activity.values) {
      activity.value = CompanionActivity.unknown;
    }
    _activity.clear();
    for (final state in _transcripts.values) {
      state.loaded = false;
      state.stale = false;
      state.cursor = 0;
      state.messages = const [];
      // A screen still watching an old host's transcript must not keep
      // showing its rows against the new one.
      _pushTranscript(state);
    }
    _transcripts.removeWhere((_, state) => state.listeners.isEmpty);
  }
}
