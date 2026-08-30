/// The relay client, used unchanged by both ends.
///
/// Each end opens an outbound WebSocket to `wss://<relay>/v1/<rendezvous>`;
/// the relay pairs them and forwards frames it cannot read.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../protocol.dart';
import 'remote_transport.dart';

/// How often the client pings the relay, so a dead link is noticed rather than
/// waiting on a TCP timeout. Also what keeps a mobile NAT binding alive.
const Duration kDefaultHeartbeat = Duration(seconds: 25);

/// How long one connection attempt may take before it counts as failed.
const Duration kDefaultConnectTimeout = Duration(seconds: 15);

/// An outbound WebSocket to a relay rendezvous, with reconnect and heartbeat.
class RelayTransport extends ReconnectingTransport {
  RelayTransport({
    required this.endpoint,
    this.heartbeat = kDefaultHeartbeat,
    this.connectTimeout = kDefaultConnectTimeout,
    super.backoff,
    super.maxQueuedFrames,
    super.onLog,
  });

  /// Builds the transport for [rendezvous] on [relay] and starts connecting.
  factory RelayTransport.connect({
    required Uri relay,
    required RendezvousId rendezvous,
    Duration heartbeat = kDefaultHeartbeat,
    Duration connectTimeout = kDefaultConnectTimeout,
    Backoff? backoff,
    int maxQueuedFrames = 256,
    void Function(String message)? onLog,
  }) => RelayTransport(
    endpoint: endpointFor(relay, rendezvous),
    heartbeat: heartbeat,
    connectTimeout: connectTimeout,
    backoff: backoff,
    maxQueuedFrames: maxQueuedFrames,
    onLog: onLog,
  )..start();

  /// The full `ws(s)://…/v1/<rendezvous>` URL both ends meet on.
  final Uri endpoint;
  final Duration heartbeat;
  final Duration connectTimeout;

  WebSocketChannel? _channel;

  /// Maps a relay base URL onto the rendezvous path, upgrading http(s) to ws(s).
  static Uri endpointFor(Uri relay, RendezvousId rendezvous) {
    final scheme = switch (relay.scheme) {
      'https' || 'wss' => 'wss',
      'http' || 'ws' => 'ws',
      final other => throw TransportException('unusable relay scheme: $other'),
    };
    final base = relay.path.endsWith('/')
        ? relay.path.substring(0, relay.path.length - 1)
        : relay.path;
    return relay.replace(scheme: scheme, path: '$base/v1/${rendezvous.value}');
  }

  @override
  Future<void> connectOnce() async {
    final channel = IOWebSocketChannel.connect(
      endpoint,
      pingInterval: heartbeat,
      connectTimeout: connectTimeout,
    );
    await channel.ready;
    _channel = channel;
    onConnected();

    final ended = Completer<void>();
    final subscription = channel.stream.listen(
      (Object? message) {
        if (message is List<int>) {
          onFrame(Uint8List.fromList(message));
        } else {
          // Sealed frames are always binary; anything else is not our peer.
          onLog?.call('ignored a non-binary relay message');
        }
      },
      onError: (Object error) {
        onLog?.call('relay stream failed: $error');
        if (!ended.isCompleted) ended.complete();
      },
      onDone: () {
        if (!ended.isCompleted) ended.complete();
      },
      cancelOnError: true,
    );

    await ended.future;
    await subscription.cancel();
    _channel = null;
    onLog?.call('relay closed the connection (${channel.closeCode})');
  }

  @override
  bool writeFrame(Uint8List frame) {
    final channel = _channel;
    if (channel == null) return false;
    channel.sink.add(frame);
    return true;
  }

  @override
  Future<void> abort() async {
    final channel = _channel;
    _channel = null;
    await channel?.sink.close();
  }
}
