/// Retiring a relay listener must not wait for the relay to say goodbye.
///
/// Closing a [RelayTransport] is a WebSocket close handshake, and it used to be
/// awaited on the path that serves a phone's **hello**: `listenFrom` retires
/// every generation below the arriving one, and a phone probes forward, so it
/// ran on essentially every hello. The phone's whole budget for a hello is
/// eight seconds.
///
/// The owner's desktop log showed what that costs when the relay is slow to
/// answer — which is the usual reason the phone is re-dialling at all:
///
/// ```txt
/// 10:05:30.407 remote: paired (3 held)
/// 10:05:38.943 remote: a socket is waiting (3 held)   <- 8.54s later, gone
/// 10:05:46.966 remote: a socket is waiting (4 held)
/// 10:05:54.968 remote: a socket is waiting (4 held)
/// ...
/// 10:06:27.152 remote: accepted a link                <- gives up, takes LAN
/// ```
///
/// A cadence of 8.002s, 8.126s, 8.018s — the phone's `helloTimeout` expiring,
/// for ninety seconds, while the phone sat on "connecting".
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_store/database.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_store/devices.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bindings.dart';
import 'transport_harness.dart';

final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _phone = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');
final _secret = Uint8List.fromList(List<int>.generate(32, (i) => 0x51 + i));

/// A relay transport that never finishes saying goodbye.
///
/// Everything else is the real thing, so the listeners are genuinely open on a
/// real relay; only [close] hangs — a relay that accepted the socket and then
/// stopped answering, which is exactly the state that makes a phone re-dial.
class _SlowGoodbye implements RemoteTransport {
  _SlowGoodbye(this._inner);

  final RemoteTransport _inner;
  static int closesStarted = 0;
  static final _never = Completer<void>();

  @override
  Stream<Uint8List> get frames => _inner.frames;
  @override
  Stream<TransportState> get states => _inner.states;
  @override
  TransportState get state => _inner.state;
  @override
  bool get isConnected => _inner.isConnected;
  @override
  void send(List<int> frame) => _inner.send(frame);

  @override
  Future<void> close() async {
    closesStarted++;
    // Started, never finished. Whoever retired this listener must not be
    // waiting on it.
    await _never.future;
  }
}

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;
  late RelayServer localRelay;
  late RelayServer hostedRelay;
  late RemoteHostService service;

  setUp(() async {
    _SlowGoodbye.closesStarted = 0;
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    localRelay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    hostedRelay = await RelayServer.bind(address: '127.0.0.1', port: 0);
  });

  tearDown(() async {
    await service.stop();
    await localRelay.close();
    await hostedRelay.close();
    db.close();
  });

  test(
    'a relay that never finishes closing does not hold the service',
    () async {
      final localUri = Uri.parse('http://127.0.0.1:${localRelay.port}');
      final hostedUri = Uri.parse('http://127.0.0.1:${hostedRelay.port}');

      dao.insert(
        PairedDevice(
          id: _phone.value,
          name: 'phone',
          deviceKey: Uint8List.fromList(
            (await deriveDeviceKey(
              pairingSecret: _secret,
              hostId: _hostId,
              deviceId: _phone,
            )).bytes,
          ),
          capabilities: CapabilitySet.all,
          generation: kFirstSessionGeneration,
          createdAt: DateTime.utc(2026, 9, 16),
          relayUrl: hostedUri.toString(),
        ),
      );

      service = RemoteHostService(
        devices: dao,
        hostId: _hostId,
        bindings: fake.bindings,
        relay: hostedUri,
        localRelayUrl: localUri,
        lanPort: 0,
        advertise: false,
        transcriptPollInterval: Duration.zero,
        relayFactory: (relay, rendezvous) => _SlowGoodbye(
          RelayTransport(
            endpoint: RelayTransport.endpointFor(relay, rendezvous),
            backoff: fastBackoff(),
            heartbeat: const Duration(milliseconds: 500),
          )..start(),
        ),
      );
      await service.start();

      // Switching the local relay off retires every listener that was open on
      // it — the same retirement a phone's hello performs for the generations
      // below the one it arrives at.
      await service
          .updateRelays(localRelayUrl: null, hostedEnabled: true)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail(
              'retiring a listener waited for the relay to say goodbye; a '
              "phone's hello does this and has eight seconds for all of it",
            ),
          );

      // The goodbye was genuinely attempted — the listener is not merely
      // dropped on the floor — it simply was not waited for.
      expect(_SlowGoodbye.closesStarted, greaterThan(0));
    },
  );
}
