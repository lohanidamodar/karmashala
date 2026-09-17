import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';

import 'device_links.dart';

/// Builds the transport waiting at one rendezvous of one relay — a seam, so a
/// test needs no relay and no network.
typedef HostRelayFactory =
    RemoteTransport Function(Uri relay, RendezvousId rendezvous);

/// The relay a row names, or null when it names none this host can dial.
/// [kLocalRelayMarker] is a desktop's word for its own embedded relay and
/// means nothing on a box.
Uri? usableRelay(String? url) {
  if (url == null || url.isEmpty || url == kLocalRelayMarker) return null;
  final parsed = Uri.tryParse(url);
  if (parsed == null || parsed.host.isEmpty) return null;
  return switch (parsed.scheme) {
    'ws' || 'wss' || 'http' || 'https' => parsed,
    _ => null,
  };
}

/// Waits at a relay for the phones that were paired through one.
///
/// A box the phone cannot dial — behind NAT, or a port nobody could open — is
/// reached the way a desktop is: both ends dial out to the same rendezvous.
/// **Only for rows that name a relay.** A phone paired straight to this
/// machine's address costs no outbound connection at all, and nothing here
/// falls back from one route to the other.
///
/// One listener per generation in the window, because the phone dials a new
/// rendezvous after every link that answered. The relay sees a rendezvous id,
/// sizes and timing, and both addresses; never a frame it can open.
class RelayListener {
  RelayListener({
    required this.links,
    HostRelayFactory? relayFactory,
    this.onLog,
  }) : _relayFactory = relayFactory ?? _dial;

  static RemoteTransport _dial(Uri relay, RendezvousId rendezvous) =>
      RelayTransport.connect(relay: relay, rendezvous: rendezvous);

  final DeviceLinks links;
  final HostRelayFactory _relayFactory;

  /// Lifecycle only — never a rendezvous id, a key or a code.
  final void Function(String message)? onLog;

  final Map<String, _DeviceWindow> _windows = {};
  Future<void> _chain = Future<void>.value();
  bool _stopped = false;

  /// Listeners open right now, waiting or serving.
  int get listenerCount =>
      _windows.values.fold(0, (n, window) => n + window.open.length);

  /// Brings the listeners in line with the rows: called at start, when a
  /// pairing completes, when a row is revoked, and after every link served —
  /// which is what moves a window forward. Serialised; never throws.
  Future<void> sync() {
    _chain = _chain.then((_) => _sync()).catchError((Object error) {
      onLog?.call('relay listeners could not be brought in line: $error');
    });
    return _chain;
  }

  Future<void> _sync() async {
    if (_stopped) return;
    final wanted = <String, (PairedDevice, Uri)>{};
    for (final device in links.devices()) {
      // A revoked row has no key, and a row with no key is nobody.
      if (device.revoked || device.deviceKey.isEmpty) continue;
      final relay = usableRelay(device.relayUrl);
      if (relay != null) wanted[device.id] = (device, relay);
    }

    for (final id in _windows.keys.toList()) {
      final window = _windows[id]!;
      final still = wanted[id];
      if (still != null && window.sameRoute(still.$1, still.$2)) {
        // The same phone, read again: its grant and its generation are the
        // row's, not what they were when the window opened.
        window.device = still.$1;
        continue;
      }
      _windows.remove(id);
      window.closeAll();
      onLog?.call('stopped waiting at a relay for a phone');
    }

    for (final (device, relay) in wanted.values) {
      final window = _windows.putIfAbsent(device.id, () {
        onLog?.call('waiting at a relay for a paired phone');
        return _DeviceWindow(device, relay);
      });
      final key = SecretKeyData(device.deviceKey);
      final from = links.floorOf(device);
      for (final g in window.open.keys.toList()) {
        // A served generation below the floor closes itself when its phone
        // leaves; closing it here would hang up on a working link.
        if (g < from && !window.open[g]!.serving) window.close(g);
      }
      for (var g = from; g < from + kHostGenerationWindow; g++) {
        if (window.open.containsKey(g)) continue;
        final rendezvous = await rendezvousFor(key, g);
        if (_stopped || !identical(_windows[device.id], window)) break;
        window.open[g] = _listen(window, key, g, rendezvous);
      }
    }
  }

  _Listening _listen(
    _DeviceWindow window,
    SecretKeyData key,
    int generation,
    RendezvousId rendezvous,
  ) {
    final transport = _relayFactory(window.relay, rendezvous);
    final listening = _Listening(transport);

    void gone() {
      if (!listening.serving) return;
      listening.served?.end();
      if (identical(window.open[generation], listening)) {
        window.close(generation);
      }
    }

    listening.frames = transport.frames.listen((frame) {
      final served = listening.served;
      if (served != null) {
        served.deliver(frame);
        return;
      }
      // Until a hello names this very rendezvous nothing is owed to whoever
      // is at the far end, and a frame is not routed on a guess.
      final hello = LinkHello.tryDecode(frame);
      if (hello == null || hello.rendezvous.value != rendezvous.value) return;
      final link = links.serve(
        transport,
        DeviceMatch(window.device, key, generation),
      );
      if (link == null) return;
      listening.served = link;
      onLog?.call('a phone arrived through the relay');
      // The relay redials for ever and its stream never ends, so the phone
      // leaving is read off the state instead.
      listening.states = transport.states.listen((state) {
        if (state == TransportState.disconnected ||
            state == TransportState.closed) {
          gone();
        }
      });
      // The row moved on; open the generation the phone will dial next.
      unawaited(sync());
    }, onDone: gone);
    return listening;
  }

  Future<void> stop() async {
    _stopped = true;
    await _chain;
    for (final window in _windows.values.toList()) {
      window.closeAll();
    }
    _windows.clear();
  }
}

/// One phone's listeners, by generation.
class _DeviceWindow {
  _DeviceWindow(this.device, this.relay);

  PairedDevice device;
  final Uri relay;
  final Map<int, _Listening> open = {};

  /// A re-pair mints a new key and may name another relay; either makes every
  /// open rendezvous somebody else's.
  bool sameRoute(PairedDevice other, Uri otherRelay) =>
      otherRelay == relay &&
      DeviceLinks.sameBytes(other.deviceKey, device.deviceKey);

  void close(int generation) => open.remove(generation)?.close();

  void closeAll() {
    for (final generation in open.keys.toList()) {
      close(generation);
    }
  }
}

class _Listening {
  _Listening(this.transport);

  final RemoteTransport transport;
  StreamSubscription<Uint8List>? frames;
  StreamSubscription<TransportState>? states;
  ServedLink? served;

  bool get serving => served != null;

  /// Detached: closing a relay transport is a goodbye handshake with a machine
  /// that may be slow, and nothing here is waiting for the answer.
  void close() {
    served?.end();
    unawaited(frames?.cancel());
    unawaited(states?.cancel());
    unawaited(
      transport.close().catchError((Object _) {}),
    );
  }
}
