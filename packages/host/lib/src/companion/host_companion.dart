import 'dart:async';

import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';

import 'companion_listener.dart';
import 'host_pairing_service.dart';
import 'relay_listener.dart';

/// The companion half of a serving host: the pairing ceremony, the listener a
/// phone dials, and the relay listeners for the phones that cannot dial.
///
/// **A phone reaches a box one of two ways, chosen when it pairs.** Straight to
/// the box's own address, which is what an empty relay means and costs no
/// outbound connection; or through the relay the pairing request named, which
/// is for a box behind something the phone cannot get through. The choice is
/// written on the row and nothing here switches between them.
class HostCompanion {
  HostCompanion({
    required this.pairing,
    required this.listener,
    HostRelayFactory? relayFactory,
    this.onLog,
  }) : _relayFactory = relayFactory,
       relays = RelayListener(
         links: listener.links,
         relayFactory: relayFactory,
         onLog: onLog,
       );

  final HostPairingService pairing;
  final CompanionListener listener;
  final RelayListener relays;
  final HostRelayFactory? _relayFactory;
  final void Function(String message)? onLog;

  HostPairingSession? _session;
  RemoteTransport? _pairingTransport;

  int paired() => pairing.paired().length;

  /// Starts waiting at the relay for every phone already paired through one.
  Future<void> start() => relays.sync();

  /// Opens a window and answers what to type. [relay] empty is the direct
  /// route; anything else must be a relay this host can dial, and is refused in
  /// words rather than quietly paired the other way.
  Future<({String code, DateTime expiresAt})> openPairing(
    int capabilities,
    String relay,
  ) async {
    final via = relay.trim().isEmpty ? null : usableRelay(relay.trim());
    if (relay.trim().isNotEmpty && via == null) {
      throw FormatException('"$relay" is not a relay this host can dial');
    }
    final session = await pairing.open(
      // The payload carries a relay either way; a direct pairing names nowhere.
      relay: via ?? Uri.parse('https://invalid.local'),
      grant: CapabilitySet(capabilities),
      relayUrl: via?.toString(),
    );
    // One window at a time: the code a person is looking at is the newest one,
    // and an older window left open is a secret nobody is watching.
    await _closeWindow();
    listener.acceptPairing(session);
    _session = session;

    RemoteTransport? transport;
    if (via != null) {
      transport = (_relayFactory ?? _dial)(via, session.payload.rendezvous);
      _pairingTransport = transport;
      session.attach(transport);
      onLog?.call('pairing window open here and at the relay');
    }
    unawaited(
      session.done
          .then<void>((_) => relays.sync(), onError: (Object _) {})
          .whenComplete(() async {
            // Only this window's own things: a newer one may already be open.
            if (identical(_session, session)) await _closeWindow();
          }),
    );
    return (
      code: PairingCode.encode(session.payload.typedSecret!),
      expiresAt: session.deadline,
    );
  }

  static RemoteTransport _dial(Uri relay, RendezvousId rendezvous) =>
      RelayTransport.connect(relay: relay, rendezvous: rendezvous);

  Future<void> _closeWindow() async {
    final session = _session;
    final transport = _pairingTransport;
    _session = null;
    _pairingTransport = null;
    if (session != null) {
      listener.endPairing(session);
      await session.close();
    }
    try {
      await transport?.close();
    } on Object catch (error) {
      onLog?.call('closing the pairing relay link failed: $error');
    }
  }

  Future<void> close() async {
    await _closeWindow();
    await relays.stop();
    await listener.stop();
  }
}
