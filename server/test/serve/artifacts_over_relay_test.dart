/// A phone reads what an agent showed through the server's own relay: the
/// artifact list and its bytes travel the sealed channel as data requests,
/// with no host path and no file share. No network beyond loopback.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_companion_server/store.dart' show hostDeviceIdFor;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart' show DataService, HostDataLink;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/artifacts/server_artifacts.dart';
import 'package:karmashala_host/src/files/server_files.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart' hide kProtocolVersion;
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final deviceId = DeviceId.parse('f' * 32);
  final deviceKey = Uint8List.fromList(List.generate(32, (i) => i + 11));

  late AppDatabase database;
  late SessionRegistry registry;
  late HostServer server;
  late DaemonCompanion companion;
  late StreamController<LifecycleEvent> events;
  late ServerArtifacts artifacts;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('artifacts_relay');
    database = AppDatabase.memory();
    registry = SessionRegistry(launcher: FakePtyLauncher());
    events = StreamController<LifecycleEvent>.broadcast();
    final data = DataService(database);
    artifacts = ServerArtifacts.over(
      database: database,
      directory: p.join(tmp.path, 'artifacts'),
      spaceFor: ServerFiles(data: data).spaceFor,
      tell: data.announce,
    );
    data.artifactsWork = artifacts;
    server = HostServer(registry: registry, ptyLibrary: 'libc.so.6')
      ..data = data;
    companion = DaemonCompanion(
      database: database,
      registry: registry,
      hostName: 'droplet',
      lanPort: 0,
      config: const CompanionConfig(enabled: true),
      localRelayEnabled: true,
      localRelayPort: 0,
      transcriptPollInterval: Duration.zero,
    );
    companion.onHostLink = (link) {
      final connection = SealedHostConnection(link);
      unawaited(server.serveConnection(connection, trust: connection.trust));
    };
    await companion.start(sessionEvents: events.stream);
  });

  tearDown(() async {
    artifacts.close();
    await companion.close();
    await events.close();
    await registry.shutdown();
    database.close();
    await tmp.delete(recursive: true);
  });

  Future<HostDataLink> phoneOverRelay(List<Capability> grants) async {
    PairedDeviceDao(database).insert(
      PairedDevice(
        id: deviceId.value,
        name: 'phone',
        deviceKey: deviceKey,
        capabilities: CapabilitySet.of(grants),
        generation: 0,
        createdAt: DateTime.utc(2026, 10, 6),
        relayUrl: kLocalRelayMarker,
      ),
    );
    await companion.service!.reconcileDevices();
    final sealed = await DesktopServerDialer(
      store: InMemoryCompanionStore(),
    ).dial(
      CompanionPairing(
        hostId: hostDeviceIdFor(database),
        deviceId: deviceId,
        deviceKey: deviceKey,
        capabilities: CapabilitySet.of([Capability.phoneClient]),
        relay: companion.localRelayStatus.primaryUrl!,
        generation: 0,
        hostName: 'droplet',
      ),
    );
    final link = await HostClientLink.open(
      SealedHostChannel(sealed),
      clientId: 'phone',
    );
    addTearDown(link.close);
    final data = HostDataLink.onLink(link);
    addTearDown(data.close);
    return data;
  }

  Future<String> showChart() async {
    final file = File(p.join(tmp.path, 'chart.html'))
      ..writeAsStringSync('<h1>chart</h1>');
    final shown = await artifacts.library.show(
      sessionId: 's1',
      source: EnvironmentPath(
        environmentId: localHostEnvironmentId,
        path: file.path,
      ),
    );
    return shown.id;
  }

  test('a phone lists a session\'s artifacts and reads one over the relay',
      () async {
    final id = await showChart();
    final phone = await phoneOverRelay([
      Capability.phoneClient,
      Capability.readTranscript,
    ]);

    final listed = await phone.send(const SessionArtifactsRead('s1'));
    expect(listed.value.single.id, id);
    expect(listed.value.single.source, isNull);

    final chunk = await phone.send(ArtifactContentRead(id));
    expect(utf8.decode(chunk.value.bytes), '<h1>chart</h1>');
  });

  test('a phone not granted transcripts is refused in words', () async {
    final id = await showChart();
    final phone = await phoneOverRelay([Capability.phoneClient]);
    await expectLater(
      phone.send(ArtifactContentRead(id)),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.message,
          'message',
          contains('transcripts'),
        ),
      ),
    );
  });
}
