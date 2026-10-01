/// A desktop app as the client of a server on another machine (slice 5e):
/// the server's companion as `serve` builds it, its host server behind the
/// sealed channel, and a desktop client dialling it over the LAN listener
/// and over the server's own relay — one link carrying the data API, the
/// lifecycle feed and several panes. No network beyond loopback.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_companion_server/store.dart' show hostDeviceIdFor;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart' show DataService, HostDataLink;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/lifecycle_client.dart' show HostLifecycleWatch;
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart' hide kProtocolVersion;
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

void main() {
  final deviceId = DeviceId.parse('e' * 32);
  final deviceKey = Uint8List.fromList(List.generate(32, (i) => i + 9));

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher launcher;
  late HostServer server;
  late DaemonCompanion companion;
  late StreamController<LifecycleEvent> events;

  setUp(() async {
    database = AppDatabase.memory();
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher);
    events = StreamController<LifecycleEvent>.broadcast();
    server = HostServer(registry: registry, ptyLibrary: 'libc.so.6')
      ..data = DataService(database);
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
    // What `serve` wires: a switched link is one more connection.
    companion.onHostLink = (link) {
      final connection = SealedHostConnection(link);
      unawaited(server.serveConnection(connection, trust: connection.trust));
    };
    await companion.start(sessionEvents: events.stream);
  });

  tearDown(() async {
    for (final pty in launcher.handles) {
      pty.finish(0);
    }
    await companion.close();
    await events.close();
    await registry.shutdown();
    database.close();
  });

  /// A row as a pairing writes it; the live service picks it up as it does
  /// a device written by another process.
  Future<void> pairDesktop(List<Capability> grants) async {
    PairedDeviceDao(database).insert(_desktop(deviceId, deviceKey, grants));
    await companion.service!.reconcileDevices();
  }


  CompanionPairing record({String? direct, Uri? relay}) => CompanionPairing(
    hostId: hostDeviceIdFor(database),
    deviceId: deviceId,
    deviceKey: deviceKey,
    capabilities: CapabilitySet.of([Capability.desktopClient]),
    relay: relay ?? Uri.parse('https://invalid.local'),
    generation: 0,
    hostName: 'droplet',
    directEndpoint: direct,
  );

  Future<HostClientLink> dial(CompanionPairing pairing) async {
    final sealed = await DesktopServerDialer(
      store: InMemoryCompanionStore(),
    ).dial(pairing);
    final link = await HostClientLink.open(
      SealedHostChannel(sealed),
      clientId: 'studio-mac',
    );
    addTearDown(link.close);
    return link;
  }

  String lan() => '127.0.0.1:${companion.service!.lanPortBound}';

  test('over the LAN: one link carries data, the lifecycle feed and two '
      'panes, each pane\'s output by its own ref', () async {
    await pairDesktop([Capability.desktopClient]);
    registry.open('a', const PtySpawnRequest(argv: ['sh']));
    registry.open('b', const PtySpawnRequest(argv: ['sh']));
    final link = await dial(record(direct: lan()));
    expect(link.welcome.protocolVersion, kProtocolVersion);

    final data = HostDataLink.onLink(link);
    final notes = await data.send(const NotesList());
    expect(notes.value, isEmpty);
    final watch = await HostLifecycleWatch.onLink(link);
    expect(watch.snapshot.map((s) => s.sessionId), containsAll(['a', 'b']));

    final a = await link.request<AttachedMessage>(
      (id) => AttachMessage(
        requestId: id,
        sessionId: 'a',
        sinceOffset: 0,
        claimWrite: true,
      ),
      const Duration(seconds: 10),
    );
    final b = await link.request<AttachedMessage>(
      (id) => AttachMessage(
        requestId: id,
        sessionId: 'b',
        sinceOffset: 0,
        claimWrite: true,
      ),
      const Duration(seconds: 10),
    );
    expect(a.sessionRef, isNot(b.sessionRef));
    final fromA = link.framesFor(a.sessionRef).where((m) => m is OutputMessage).cast<OutputMessage>();
    final fromB = link.framesFor(b.sessionRef).where((m) => m is OutputMessage).cast<OutputMessage>();
    launcher.handles[0].emit('alpha'.codeUnits);
    launcher.handles[1].emit('beta'.codeUnits);
    expect(String.fromCharCodes((await fromA.first).bytes), 'alpha');
    expect(String.fromCharCodes((await fromB.first).bytes), 'beta');

    link.send(InputMessage(a.sessionRef, Uint8List.fromList('ls\r'.codeUnits)));
    await _until(() => launcher.handles[0].writes.isNotEmpty);
    expect(String.fromCharCodes(launcher.handles[0].writes.single), 'ls\r');
    await watch.close();
    await data.close();
  });

  test('over the server\'s relay, when no address was typed', () async {
    await pairDesktop([Capability.desktopClient]);
    final relay = companion.localRelayStatus.primaryUrl!;
    final link = await dial(record(relay: relay));
    final data = HostDataLink.onLink(link);
    expect((await data.send(const NotesList())).value, isEmpty);
    await data.close();
  });

  test('the link refuses admin and pairing without the grant, and its data '
      'link may not change paired devices', () async {
    await pairDesktop([Capability.desktopClient]);
    final link = await dial(record(direct: lan()));
    final call = await link.request<ServerResultMessage>(
      (id) => ServerCallMessage(requestId: id, method: 'server.info'),
      const Duration(seconds: 10),
    );
    expect(call.ok, isFalse);
    await expectLater(
      link.request<PairedMessage>(
        (id) => PairMessage(requestId: id, capabilities: 1),
        const Duration(seconds: 10),
      ),
      throwsA(isA<HostLinkException>()),
    );
    final data = HostDataLink.onLink(link);
    await expectLater(
      data.send(DeviceRevoke(deviceId.value)),
      throwsA(
        isA<DataRefused>().having(
          (e) => e.code,
          'code',
          DataRefusalCode.denied,
        ),
      ),
    );
    await data.close();
  });

  test('a pairing with neither client grant is refused the switch', () async {
    await pairDesktop([
      for (final grant in CapabilitySet.all.granted)
        if (grant != Capability.phoneClient) grant,
    ]);
    await expectLater(
      dial(record(direct: lan())),
      throwsA(isA<DesktopConnectException>()),
    );
  });

  test('a phone\'s pairing ("all", so phone_client) is switched at the phone '
      'tier, never as admin even with the bit', () async {
    await pairDesktop([...CapabilitySet.all.granted, Capability.serverAdmin]);
    final link = await dial(record(direct: lan()));
    final call = await link.request<ServerResultMessage>(
      (id) => ServerCallMessage(requestId: id, method: 'server.info'),
      const Duration(seconds: 10),
    );
    expect(call.ok, isFalse);
  });
}

PairedDevice _desktop(
  DeviceId id,
  Uint8List key,
  List<Capability> grants,
) => PairedDevice(
  id: id.value,
  name: 'studio-mac',
  deviceKey: key,
  capabilities: CapabilitySet.of(grants),
  generation: 0,
  createdAt: DateTime.utc(2026, 9, 27),
  relayUrl: kLocalRelayMarker,
);

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('never became true');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
