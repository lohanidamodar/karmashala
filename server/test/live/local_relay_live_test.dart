@Tags(['live'])
library;

import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart'
    show HostClient, ServerMethod;
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

import 'companion_live_harness.dart';
import 'local_host_harness.dart';

/// The LAN relay in the server (slice 5c follow-up), end to end on this
/// machine with no desktop app anywhere: a real `karmashala_host serve`
/// started with `--local-relay`, a pairing opened at its local relay by a
/// link that is not the app (`pair` over SSH), a phone's own pairing and
/// session clients reaching it through that relay — the route a phone paired
/// through "Local network" has saved. Found live: with the relay inside the
/// app, closing the app left such a phone "Host unreachable".
///
/// Loopback and ephemeral ports only: the owner's own server may hold 8787.
void main() {
  late Directory home;
  late LocalHost host;
  late Uri relay;

  setUpAll(() async {
    home = temporaryHome('karmashala-local-relay-live');
    final dataDir = Directory('${home.path}/data');
    seedStore(dataDir);
    host = await LocalHost.start(
      home,
      serveArguments: [
        '--companion-port=0',
        '--mcp-port=0',
        '--data-dir=${dataDir.path}',
        '--local-relay',
        '--local-relay-port=0',
      ],
    );
    addTearDown(host.kill);
    final said = RegExp(
      r'local relay on (ws://127\.0\.0\.1:\d+)',
    ).firstMatch(host.greeting);
    expect(said, isNotNull, reason: host.greeting);
    relay = Uri.parse(said!.group(1)!);
    expect(relay.port, isNot(8787));
  });

  test('the server says where its relay listens', () async {
    final admin = (await HostClient.connect(host.socketPath))!;
    addTearDown(admin.close);
    final info = await admin.call(ServerMethod.serverInfo);
    final local = (info['companion']! as Map)['localRelay']! as Map;
    expect(local['state'], 'running');
    expect(local['url'], relay.toString());

    final config = await admin.call(ServerMethod.configGet);
    expect((config['localRelay']! as Map)['url'], relay.toString());
  });

  test('a phone pairs at the server\'s relay and is served through it, no '
      'app anywhere', () async {
    // `pair` over SSH: a link that never says it is the app.
    final pairer = await AppLink.connect(host.socketPath);
    final payload = await pairer.pair(CapabilitySet.all, atLocalRelay: true);
    expect(payload.relay, relay);

    final store = InMemoryCompanionStore();
    // No transport: the phone dials the payload's relay, as it does.
    final paired = await CompanionPairingClient(
      store: store,
      deviceName: 'Relay phone',
    ).pair(payload);
    await pairer.close();

    final database = AppDatabase.open(Directory('${home.path}/data'));
    final row = PairedDeviceDao(
      database,
    ).getActive().singleWhere((device) => device.name == 'Relay phone');
    database.close();
    expect(row.relayUrl, kLocalRelayMarker);

    final client = CompanionClient(pairing: paired, store: store);
    addTearDown(client.close);
    final status = await client.connect(
      helloTimeout: const Duration(seconds: 10),
    );
    expect(status.relays, contains(relay));
    final sessions = await client.listSessions();
    expect(sessions.map((s) => s.sessionId), contains(seededSessionId));
  });
}
