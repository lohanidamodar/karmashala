part of 'remote_companion_gateway.dart';

// Pairing: minting this phone's identity, the two-legged race that finds the
// desktop, and adopting the record the desktop confirmed.

extension _GatewayPairing on RemoteCompanionGateway {
  Future<DeviceId> _readOrMintDeviceId() async {
    try {
      final raw = await store.read(RemoteCompanionGateway.kDeviceIdStoreKey);
      if (raw != null) return DeviceId.parse(raw);
    } on Object catch (error) {
      onLog?.call('stored device id unreadable: $error');
    }
    // A phone that paired before this key existed already has an identity in
    // its active record — adopting it means the desktop sees the SAME phone
    // and refreshes its row, instead of one last duplicate.
    await _ready;
    final inherited = _all.active?.deviceId ?? _record?.deviceId;
    final id = inherited ?? DeviceId.generate();
    try {
      await store.write(RemoteCompanionGateway.kDeviceIdStoreKey, id.value);
    } on Object catch (error) {
      // Pairing still works; it is only the stability that is at risk, and
      // saying so beats a silent duplicate on the desktop next time.
      onLog?.call('could not persist this phone\'s device id: $error');
    }
    return id;
  }

  PairingException _refusedPairingInput() {
    const refusal = PairingException(
      'That is not a Karmashala pairing code. Scan the QR from the '
      "desktop's Remote access settings, type the code shown under it, or "
      'paste its full pairing payload here.',
    );
    _emitPairing(CompanionPairingStage.failed, message: refusal.message);
    return refusal;
  }

  void _onPairingConfirm(String hostName, CapabilitySet capabilities) =>
      _emitPairing(
        CompanionPairingStage.proving,
        hostName: hostName,
        capabilities: capabilities,
      );

  void _emitPairing(
    CompanionPairingStage stage, {
    String? detail,
    String? hostName,
    CapabilitySet? capabilities,
    String? message,
  }) {
    if (_progress.isClosed) return;
    _progress.add(
      CompanionPairingProgress(
        stage: stage,
        detail: detail,
        hostName: hostName,
        capabilities: capabilities,
        message: message,
      ),
    );
  }

  /// A freshly paired host becomes a saved connection AND the active one.
  /// Pairing a host this phone already holds replaces that record alone; the
  /// pairing client has already written it, so this re-reads the set.
  Future<CompanionPairing> _adoptPairing(stored.CompanionPairing record) async {
    try {
      _all = await stored.CompanionConnections.mutate(store, (all) {
        all
          ..upsert(record)
          ..activeHostId = record.hostId;
        return all;
      });
    } on Object catch (error) {
      // The desktop confirmed and the pairing client wrote its record; what
      // failed is making it the active one. Escaping from here would be an
      // unhandled async error with the progress stream still saying "proving".
      onLog?.call('adopting the new pairing failed: $error');
      const failure = PairingException(
        'Your desktop confirmed the pairing, but this phone could not save '
        'it to its secure storage. Try again.',
      );
      _emitPairing(CompanionPairingStage.failed, message: failure.message);
      throw failure;
    }
    _record = _all.active ?? record;
    final public = _publicPairing(_record!);
    _pairing.value = public;
    _publishConnections();
    _emitPairing(
      CompanionPairingStage.paired,
      hostName: public.hostName,
      capabilities: record.capabilities,
    );
    // The old host's connect loop may have re-dialled it while the pairing
    // race ran, so tear that link down again now that the new record is the
    // active one — otherwise the phone would sit on the previous desktop
    // while claiming to be on this one.
    _switching = true;
    await _dropLink(keepState: true);
    _resetHostState();
    _link.value = CompanionLinkState.connecting;
    _resetBackoff();
    _startLoop();
    return public;
  }

  /// Runs the race and rewrites every failure as a sentence, mirroring the
  /// old single-path error mapping.
  Future<stored.CompanionPairing> _runPairing({
    required Future<stored.CompanionPairing> Function(RemoteTransport link)
    attempt,
    required Uri relay,
    required RendezvousId rendezvous,
  }) async {
    try {
      return await _pairOverAnyPath(
        attempt: attempt,
        relay: relay,
        rendezvous: rendezvous,
      );
    } on PairingException catch (error) {
      _emitPairing(CompanionPairingStage.failed, message: error.message);
      rethrow;
    } on Object catch (error) {
      onLog?.call('pairing failed: $error');
      const failure = PairingException(
        'Pairing failed before the desktop could confirm it. Check the '
        'connection and scan a fresh code.',
      );
      _emitPairing(CompanionPairingStage.failed, message: failure.message);
      throw failure;
    }
  }

  /// Design §3 applied to pairing itself: every fresh LAN candidate races the
  /// relay, the first sealed round-trip wins and the loser's transport is
  /// closed under it. A dead relay must not sink pairing when the desktop is
  /// one Wi-Fi hop away — and a dark LAN must not sink it when the relay is
  /// fine. Only when BOTH legs fail does one combined sentence say which
  /// failed how.
  Future<stored.CompanionPairing> _pairOverAnyPath({
    required Future<stored.CompanionPairing> Function(RemoteTransport link)
    attempt,
    required Uri relay,
    required RendezvousId rendezvous,
  }) async {
    final scout = lan;
    _ensureLanScout();
    _emitPairing(
      CompanionPairingStage.searching,
      detail: scout == null
          ? 'over the relay'
          : 'on this network and over the relay',
    );
    final outcome = Completer<stored.CompanionPairing>();
    final open = <RemoteTransport>{};
    var cancelled = false;
    String? relayNote;
    String? lanNote;
    // A refusal with a story of its own (wrong protocol version, a desktop
    // too old for typed codes) beats the generic connectivity sentence.
    CompanionPairingException? sharp;

    bool isSharp(CompanionPairingException error) =>
        !error.message.contains('did not answer') &&
        !error.message.contains('connection closed');

    Future<void> closeTransport(RemoteTransport transport) async {
      if (!open.remove(transport)) return;
      try {
        await transport.close();
      } on Object catch (error) {
        onLog?.call('pairing transport close failed: $error');
      }
    }

    Future<void> relayLeg() async {
      final transport = _relayFactory(relay, rendezvous);
      open.add(transport);
      var everConnected = false;
      final states = transport.states.listen((state) {
        if (state == TransportState.connected) everConnected = true;
      });
      try {
        final record = await attempt(transport).timeout(pairingTimeout);
        if (!outcome.isCompleted) outcome.complete(record);
      } on CompanionPairingException catch (error) {
        onLog?.call('relay pairing leg failed: $error');
        if (isSharp(error)) sharp ??= error;
        relayNote = everConnected
            ? 'the relay was reached but the desktop never answered there'
            : 'no relay was reachable';
      } on Object catch (error) {
        onLog?.call('relay pairing leg failed: $error');
        relayNote = everConnected
            ? 'the relay was reached but the desktop never answered there'
            : 'no relay was reachable';
      } finally {
        await states.cancel();
        await closeTransport(transport);
      }
    }

    Future<void> lanLeg() async {
      if (scout == null) {
        lanNote = 'this phone cannot search this network for it';
        return;
      }
      final deadline = _now().add(pairingTimeout);
      final tried = <String>{};
      var sawBeacon = false;
      // A sharp refusal ends the search: the code itself is unusable.
      while (!cancelled &&
          !outcome.isCompleted &&
          sharp == null &&
          _now().isBefore(deadline)) {
        DiscoveredHost? candidate;
        for (final host in scout.candidates) {
          if (tried.contains(scout.keyOf(host))) continue;
          candidate = host;
          break;
        }
        if (candidate == null) {
          // No fresh candidate yet; the beacon repeats every two seconds.
          await Future<void>.delayed(const Duration(milliseconds: 150));
          continue;
        }
        sawBeacon = true;
        tried.add(scout.keyOf(candidate));
        final transport = scout.dial(candidate);
        open.add(transport);
        try {
          final record = await attempt(
            transport,
          ).timeout(scout.attemptTimeout * 4);
          scout.noteSuccess(candidate);
          if (!outcome.isCompleted) outcome.complete(record);
          return;
        } on CompanionPairingException catch (error) {
          onLog?.call('lan pairing attempt failed: $error');
          if (isSharp(error)) sharp ??= error;
          // Deliberately no scout cooldown: the user's Retry should be free
          // to dial the same desktop again right away.
        } on Object catch (error) {
          onLog?.call('lan pairing attempt failed: $error');
        } finally {
          await closeTransport(transport);
        }
      }
      if (!outcome.isCompleted) {
        lanNote = sawBeacon
            ? 'a desktop was seen on this network but did not accept the code'
            : 'no desktop was found on this network';
      }
    }

    unawaited(
      Future.wait([relayLeg(), lanLeg()]).then((_) {
        if (outcome.isCompleted) return;
        final specific = sharp;
        if (specific != null) {
          outcome.completeError(PairingException(specific.message));
          return;
        }
        outcome.completeError(
          PairingException(
            'Could not find your desktop — '
            '${relayNote ?? 'the relay was not tried'}, and '
            '${lanNote ?? 'this network was not searched'}. Make sure the '
            'pairing code is still on the desktop screen, then retry.',
          ),
        );
      }),
    );
    try {
      return await outcome.future;
    } finally {
      cancelled = true;
      for (final transport in open.toList()) {
        await closeTransport(transport);
      }
    }
  }
}
