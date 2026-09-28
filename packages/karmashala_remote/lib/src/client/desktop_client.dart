/// A desktop app as the client of a server on another machine (slice 5e):
/// the phone's pairing record and sealed channel, switched to the host
/// protocol with `host.attach`, over the server's LAN listener or a relay.
library;

import 'dart:async';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:karmashala_host_protocol/host_access.dart' show RemoteChannel;

import '../pairing/pairing_wire.dart';
import '../protocol.dart';
import '../transport/key_schedule.dart';
import '../transport/lan_transport.dart';
import '../transport/relay_transport.dart';
import '../transport/remote_transport.dart';
import '../transport/sealed_channel.dart';
import '../transport/sealed_host_link.dart';
import 'companion_client.dart' show RelayTransportFactoryFn, kCompanionProbeWindow;
import 'companion_store.dart';
import 'lan_path.dart' show LanDialerFn;

/// Why a desktop could not reach its server; [message] is safe to show.
class DesktopConnectException implements Exception {
  const DesktopConnectException(this.message, {this.refused = false});

  final String message;

  /// The server answered and said no (the pairing grants no desktop): no
  /// other route or generation will say otherwise.
  final bool refused;

  @override
  String toString() => message;
}

/// Opens one sealed host link over [transport] at [generation]: the link
/// hello, the server's `host.status`, then `host.attach`. The transport is
/// closed with the link, and a transport that drops ends the link.
Future<SealedHostLink> connectDesktopLink({
  required CompanionPairing pairing,
  required RemoteTransport transport,
  required int generation,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final key = SecretKeyData(pairing.deviceKey);
  final channel = await SealedChannel.forDevice(
    deviceKey: key,
    role: ChannelRole.companion,
    generation: generation,
  );
  SealedHostLink? link;
  final greeted = Completer<void>();
  final attached = Completer<void>();
  var chain = Future<void>.value();
  var connected = false;

  final frames = transport.frames.listen((frame) {
    chain = chain.then((_) async {
      final SealedFrame opened;
      try {
        opened = await channel.unseal(frame);
      } on SealedChannelException catch (error) {
        link?.close('a frame would not open: $error');
        return;
      }
      final current = link;
      if (current != null) {
        current.receive(opened);
        return;
      }
      final Envelope envelope;
      try {
        envelope = Envelope.fromBytes(
          opened.plaintext,
          accept: VersionRange.any,
        );
      } on ProtocolException {
        return;
      }
      switch (envelope.knownType) {
        case FrameType.hostStatus when !greeted.isCompleted:
          greeted.complete();
        case FrameType.result when envelope.id == _attachId:
          link = SealedHostLink(
            channel: channel,
            sendSealed: transport.send,
            nextReceiveSequence: opened.sequence + 1,
          );
          if (!attached.isCompleted) attached.complete();
        case FrameType.error when envelope.id == _attachId:
          final message = envelope.payload['message'];
          if (!attached.isCompleted) {
            attached.completeError(
              DesktopConnectException(
                message is String ? message : 'the server refused',
                refused: true,
              ),
            );
          }
        default:
          break;
      }
    });
  });
  final states = transport.states.listen((state) {
    if (state == TransportState.connected) {
      connected = true;
      return;
    }
    if (connected &&
        (state == TransportState.disconnected ||
            state == TransportState.closed)) {
      link?.close('the connection dropped');
    }
  });

  Future<SealedHostLink> give(Object error) async {
    await frames.cancel();
    await states.cancel();
    await transport.close();
    throw error;
  }

  try {
    transport.send(LinkHello(await rendezvousFor(key, generation)).encode());
    await greeted.future.timeout(timeout);
    final envelope = Envelope.of(
      FrameType.hostAttach,
      seq: channel.nextSendSequence,
      id: _attachId,
    );
    transport.send(await channel.seal(envelope.toBytes()));
    await attached.future.timeout(timeout);
  } on TimeoutException {
    return give(
      DesktopConnectException(
        connected
            ? 'the server did not answer there'
            : 'nothing could be reached there',
      ),
    );
  } on DesktopConnectException catch (error) {
    return give(error);
  } on TransportException catch (error) {
    return give(DesktopConnectException(error.message));
  }
  final opened = link!;
  unawaited(
    opened.done.then((_) async {
      await frames.cancel();
      await states.cancel();
      await transport.close();
    }),
  );
  return opened;
}

const String _attachId = 'attach';

/// Dials a paired server the way the phone does, minus the beacon: the
/// address typed at pairing first (the server's LAN listener), then each
/// relay it is known at, probing a few generations forward when this
/// record's counter fell behind. The counter moves on after each link, so
/// the next one starts on a fresh generation.
class DesktopServerDialer {
  DesktopServerDialer({
    required this.store,
    LanDialerFn? lanDialer,
    RelayTransportFactoryFn? relayFactory,
    this.timeout = const Duration(seconds: 6),
  }) : _lanDialer = lanDialer ?? _dialLan,
       _relayFactory = relayFactory ?? _dialRelay;

  final CompanionStore store;
  final Duration timeout;
  final LanDialerFn _lanDialer;
  final RelayTransportFactoryFn _relayFactory;

  static RemoteTransport _dialLan(String host, int port) =>
      LanTransport.dial(host: host, port: port);

  static RemoteTransport _dialRelay(Uri relay, RendezvousId rendezvous) =>
      RelayTransport.connect(relay: relay, rendezvous: rendezvous);

  /// Throws [DesktopConnectException] naming what each route answered.
  Future<SealedHostLink> dial(CompanionPairing pairing) async {
    final key = SecretKeyData(pairing.deviceKey);
    final notes = <String>[];
    for (var probe = 0; probe < kCompanionProbeWindow; probe++) {
      final generation = pairing.generation + probe;
      for (final route in _routes(pairing)) {
        final relay = route.relay;
        final transport = relay == null
            ? _lanDialer(route.host, route.port)
            : _relayFactory(relay, await rendezvousFor(key, generation));
        try {
          final link = await connectDesktopLink(
            pairing: pairing,
            transport: transport,
            generation: generation,
            timeout: timeout,
          );
          await _advance(pairing, generation);
          return link;
        } on DesktopConnectException catch (error) {
          if (error.refused) rethrow;
          notes.add('${route.label}: ${error.message}');
        }
      }
    }
    throw DesktopConnectException(
      'Could not reach ${pairing.hostName.isEmpty ? 'the server' : pairing.hostName} '
      '(${notes.toSet().join('; ')}).',
    );
  }

  List<({String host, int port, Uri? relay, String label})> _routes(
    CompanionPairing pairing,
  ) {
    final routes = <({String host, int port, Uri? relay, String label})>[];
    final direct = parseEndpoint(pairing.directEndpoint);
    if (direct != null) {
      routes.add((
        host: direct.$1,
        port: direct.$2,
        relay: null,
        label: '${direct.$1}:${direct.$2}',
      ));
    }
    for (final candidate in pairing.candidates) {
      final url = candidate.url;
      if (url.host == 'invalid.local') continue;
      routes.add((host: '', port: 0, relay: url, label: 'relay ${url.host}'));
    }
    return routes;
  }

  Future<void> _advance(CompanionPairing pairing, int used) async {
    try {
      await pairing
          .withGeneration(used + 1)
          .withLastConnected(DateTime.now())
          .save(store);
    } on Object {
      // A counter that did not stick costs a probe forward next time.
    }
  }
}

/// `host:port` as a pair, or null when [text] is not one.
(String, int)? parseEndpoint(String? text) {
  if (text == null || text.isEmpty) return null;
  final colon = text.lastIndexOf(':');
  if (colon <= 0) return null;
  final port = int.tryParse(text.substring(colon + 1));
  if (port == null || port <= 0 || port > 65535) return null;
  return (text.substring(0, colon), port);
}

/// A sealed host link as the byte channel a host-protocol link runs over.
class SealedHostChannel implements RemoteChannel {
  SealedHostChannel(this.link);

  final SealedHostLink link;

  @override
  Stream<Uint8List> get stdout => link.incoming;

  @override
  Stream<Uint8List> get stderr => const Stream<Uint8List>.empty();

  @override
  void add(Uint8List bytes) => link.add(bytes);

  @override
  Future<int> get exitCode => link.done.then((_) => 0);

  @override
  Future<void> close() async => link.close('the client hung up');
}
