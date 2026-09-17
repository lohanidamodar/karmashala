import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:karmashala_remote/remote.dart';

import '../domain/session_registry.dart';
import 'companion_server.dart';
import 'sealed_link.dart';

/// How many generations ahead of a row's own a phone is still recognised at.
/// The desktop's listen window and the phone's probe window are both 3, and
/// the phone's says it "must stay within the host's own" — so this is that
/// number rather than the key schedule's wider 8, which nothing dials across.
const int kHostGenerationWindow = 3;

/// A rendezvous that turned out to be one paired phone's, and at which
/// generation.
class DeviceMatch {
  const DeviceMatch(this.device, this.key, this.generation);

  final PairedDevice device;
  final SecretKeyData key;
  final int generation;
}

/// Recognises a paired phone by the rendezvous it asked for, and serves it —
/// the one copy of both, whichever way the link arrived.
///
/// **A generation is answered once.** The phone bumps its counter after every
/// link that answered and dials the new number, so the row moves with it: the
/// row holds the *next* generation this host expects, exactly as the phone's
/// record does. A rendezvous at or below one already served gets no answer —
/// a fresh link opens a fresh replay window, so answering an old rendezvous
/// would let anybody who watched a session go by play it back.
class DeviceLinks {
  DeviceLinks({
    required this.registry,
    required this.hostName,
    required this.devices,
    this.onGeneration,
    this.onLog,
  });

  final SessionRegistry registry;
  final String hostName;

  /// Read each time, so a pairing made while this is running is routable on
  /// the next link without a restart.
  final List<PairedDevice> Function() devices;

  /// Persists the next generation a device will be recognised from. Null keeps
  /// it in memory only, which holds until the process ends.
  final void Function(String deviceId, int generation)? onGeneration;

  final void Function(String message)? onLog;

  /// device id → the highest generation already served. What makes the claim
  /// atomic: matching is async, so two hellos for one rendezvous can both get
  /// past a row that has not been written yet.
  ///
  /// Held with the key it was served under: a phone that pairs again has a new
  /// key and starts its count over, and must not be held to the old one's.
  final Map<String, ({Uint8List key, int generation})> _served = {};

  /// The first generation [device] may still use.
  int floorOf(PairedDevice device) {
    final served = _served[device.id];
    if (served == null ||
        served.generation < device.generation ||
        !sameBytes(served.key, device.deviceKey)) {
      return device.generation;
    }
    return served.generation + 1;
  }

  static bool sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Whose rendezvous [wanted] is, or null for nobody's.
  Future<DeviceMatch?> match(String wanted) async {
    for (final device in devices()) {
      if (device.deviceKey.isEmpty) continue;
      final key = SecretKeyData(device.deviceKey);
      final from = floorOf(device);
      for (var g = from; g < from + kHostGenerationWindow; g++) {
        if ((await rendezvousFor(key, g)).value == wanted) {
          return DeviceMatch(device, key, g);
        }
      }
    }
    return null;
  }

  /// Serves [match] over [link], or answers null when that generation was
  /// claimed while this one was still being matched. Frames go in through
  /// [ServedLink.deliver]; [ServedLink.end] is how the caller says the peer
  /// went away.
  ServedLink? serve(RemoteTransport link, DeviceMatch match) {
    final device = match.device;
    if (match.generation < floorOf(device)) return null;
    _served[device.id] = (key: device.deviceKey, generation: match.generation);
    onGeneration?.call(device.id, match.generation + 1);

    final served = ServedLink(link);
    unawaited(() async {
      final channel = await SealedChannel.forDevice(
        deviceKey: match.key,
        role: ChannelRole.host,
        generation: match.generation,
      );
      final plain = SealedLink(served, channel, onLog: onLog);
      try {
        await CompanionServer(
          registry: registry,
          hostName: hostName,
          clientId: device.id,
          capabilities: device.capabilities,
        ).serve(plain);
      } on Object catch (error) {
        onLog?.call('a companion link ended badly: $error');
      } finally {
        await plain.close();
      }
    }());
    return served;
  }
}

/// A link whose first frame somebody else already read, re-exposed as a
/// transport the sealed layer can listen to.
///
/// The hello is off the wire by the time anybody knows who the link is for, and
/// a second `listen` on a single-subscription stream is an error — so frames
/// arrive through [deliver]. [end] closes them, which is what lets
/// `CompanionServer.serve` finish: a relay transport redials for ever and its
/// own stream never ends when the phone leaves.
class ServedLink implements RemoteTransport {
  ServedLink(this._link);

  final RemoteTransport _link;
  final _frames = StreamController<Uint8List>();

  void deliver(Uint8List frame) {
    if (!_frames.isClosed) _frames.add(frame);
  }

  /// The peer is gone. Idempotent.
  void end() {
    if (!_frames.isClosed) unawaited(_frames.close());
  }

  bool get ended => _frames.isClosed;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  void send(List<int> frame) {
    try {
      _link.send(frame);
    } on TransportException {
      // An answer to a phone that has already gone. Nothing is owed to it.
    }
  }

  @override
  Stream<TransportState> get states => _link.states;

  @override
  TransportState get state => _link.state;

  @override
  bool get isConnected => _link.isConnected;

  @override
  Future<void> close() async {
    end();
    await _link.close();
  }
}
