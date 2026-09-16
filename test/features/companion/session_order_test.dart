/// The session list's ordering and identity rules — the bug the user
/// re-reported. The host's order IS the order; a session that arrives late
/// lands beside its own project rather than on the end; two checkouts that
/// share a folder name stay two projects; archived rows are listed and
/// labelled instead of quietly dropped.
library;

import 'package:karmashala_store/database.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala/src/features/companion/client/secure_companion_store.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala/src/features/remote/application/remote_host_service.dart';
import 'package:karmashala_store/devices.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';
import 'companion_test_support.dart';

void main() {
  group('through the real gateway, against a real host', () {
    late AppDatabase db;
    late PairedDeviceDao dao;
    late FakeRemoteBindings fake;
    late RelayServer relay;
    late Uri relayUri;
    RemoteHostService? service;
    late SecureCompanionStore store;
    final gateways = <RemoteCompanionGateway>[];

    setUp(() async {
      db = AppDatabase.memory();
      dao = PairedDeviceDao(db);
      fake = FakeRemoteBindings();
      relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
      relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
      // Loop 83's last-resort relay is the phone's configured one, which
      // defaults to the public PopupBits relay — point it here instead.
      final disk = <String, String>{
        RemoteCompanionGateway.kPairingRelayStoreKey: relayUri.toString(),
      };
      store = SecureCompanionStore.withBackend(
        read: (key) async => disk[key],
        write: (key, value) async => disk[key] = value,
        delete: (key) async => disk.remove(key),
      );
    });

    tearDown(() async {
      for (final gateway in gateways.reversed.toList()) {
        await gateway.close();
      }
      gateways.clear();
      await service?.stop();
      service = null;
      await relay.close();
      db.close();
    });

    Future<RemoteCompanionGateway> pairedGateway() async {
      final started = service = RemoteHostService(
        devices: dao,
        hostId: DeviceId.parse('11111111222222223333333344444444'),
        bindings: fake.bindings,
        relay: relayUri,
        lanPort: 0,
        advertise: false,
        transcriptPollInterval: Duration.zero,
        relayFactory: (relay, rendezvous) => RelayTransport(
          endpoint: RelayTransport.endpointFor(relay, rendezvous),
          backoff: fastBackoff(),
          heartbeat: const Duration(milliseconds: 500),
        )..start(),
      );
      await started.start();
      final gateway = RemoteCompanionGateway(
        store: store,
        deviceModel: 'Test phone',
        relayFactory: (relay, rendezvous) => RelayTransport(
          endpoint: RelayTransport.endpointFor(relay, rendezvous),
          backoff: fastBackoff(),
          heartbeat: const Duration(milliseconds: 500),
        )..start(),
        requestTimeout: const Duration(seconds: 2),
        helloTimeout: const Duration(seconds: 2),
        reconnectBackoff: fastBackoff(),
      );
      gateways.add(gateway);
      final session = await started.beginPairing(
        capabilities: CapabilitySet.all,
      );
      await gateway.pairWithQr(session.payload.encode());
      await session.done;
      await gateway.linkStates
          .firstWhere((state) => state == CompanionLinkState.connected)
          .timeout(const Duration(seconds: 15));
      return gateway;
    }

    /// A row exactly as the host would put it on the wire, with the extra
    /// checkout fields a newer host sends.
    void addRow(
      String id, {
      required String title,
      String? repositoryId,
      String? repositoryName,
      String? projectId,
      String? projectName,
      String? projectPath,
      bool folderMissing = false,
      bool archived = false,
    }) {
      fake.sessions[id] = RemoteSessionSnapshot(
        sessionId: id,
        title: title,
        status: 'running',
        archived: archived,
        repositoryId: repositoryId,
        repositoryName: repositoryName,
        projectId: projectId,
        projectName: projectName,
        projectPath: projectPath,
        folderMissing: folderMissing,
      );
    }

    test("the host's own order is what the phone lists — not a re-sort", () async {
      // Deliberately interleaved projects and non-alphabetical titles: any
      // re-sort on the phone would change this sequence.
      addRow('z', title: 'Zebra', repositoryId: 'r1', repositoryName: 'alpha');
      addRow('a', title: 'Apple', repositoryId: 'r2', repositoryName: 'beta');
      addRow('m', title: 'Mango', repositoryId: 'r1', repositoryName: 'alpha');
      final gateway = await pairedGateway();

      final list = await gateway.listSessions();

      expect([for (final s in list) s.id], ['z', 'a', 'm']);
    });

    test('two repositories in one project make one header, not two', () async {
      // The Explorer groups by project; the phone must agree, or a project
      // holding several checkouts splits into a header per checkout.
      addRow('a', title: 'A', repositoryId: 'r1', repositoryName: 'api',
          projectId: 'p1', projectName: 'Shop', projectPath: '/w/shop');
      addRow('b', title: 'B', repositoryId: 'r2', repositoryName: 'web',
          projectId: 'p1', projectName: 'Shop', projectPath: '/w/shop');
      final gateway = await pairedGateway();

      final list = await gateway.listSessions();

      expect({for (final s in list) s.projectKey}, hasLength(1));
      expect(list.first.projectName, 'Shop');
      expect(list.first.projectPath, '/w/shop');
    });

    test('an older host without projects still groups by repository', () async {
      addRow('a', title: 'A', repositoryId: 'r1', repositoryName: 'api');
      addRow('b', title: 'B', repositoryId: 'r2', repositoryName: 'web');
      final gateway = await pairedGateway();

      final list = await gateway.listSessions();

      expect({for (final s in list) s.projectKey}, hasLength(2));
      expect(list.first.projectName, 'api');
    });

    test('a missing folder is marked, not silently normal', () async {
      addRow('a', title: 'A', projectId: 'p1', projectName: 'Gone',
          folderMissing: true);
      final gateway = await pairedGateway();

      expect((await gateway.listSessions()).single.folderMissing, isTrue);
    });

    test('archived sessions are listed and flagged, not dropped', () async {
      addRow('live', title: 'Live one', repositoryName: 'alpha');
      addRow('old', title: 'Archived one', repositoryName: 'alpha',
          archived: true);
      final gateway = await pairedGateway();

      final list = await gateway.listSessions();

      expect([for (final s in list) s.id], ['live', 'old']);
      expect(list.singleWhere((s) => s.id == 'old').archived, isTrue);
      expect(list.singleWhere((s) => s.id == 'live').archived, isFalse);
    });

    test('the repository id travels, so same-named folders stay apart',
        () async {
      addRow('one', title: 'One', repositoryId: 'r1', repositoryName: 'app');
      addRow('two', title: 'Two', repositoryId: 'r2', repositoryName: 'app');
      final gateway = await pairedGateway();

      final list = await gateway.listSessions();

      expect(list.map((s) => s.projectId), ['r1', 'r2']);
      expect(
        list.map((s) => s.projectKey).toSet(),
        hasLength(2),
        reason: 'two checkouts named "app" are two projects',
      );
    });

    test('a host that sends no repository id still groups by name', () async {
      addRow('one', title: 'One', repositoryName: 'app');
      addRow('two', title: 'Two', repositoryName: 'app');
      final gateway = await pairedGateway();

      final list = await gateway.listSessions();

      expect(list.map((s) => s.projectId), [isNull, isNull]);
      expect(
        list.map((s) => s.projectKey).toSet(),
        hasLength(1),
        reason: 'the old-host fallback keeps them together',
      );
    });

    test('a session that arrives late is never shown on the end of the list '
        'and then shuffled — it lands beside its own project at once',
        () async {
      addRow('a1', title: 'A one', repositoryId: 'r1', repositoryName: 'alpha');
      addRow('b1', title: 'B one', repositoryId: 'r2', repositoryName: 'beta');
      final gateway = await pairedGateway();
      await gateway.listSessions();

      // Every list the phone renders from here on.
      final seen = <List<String>>[];
      final sub = gateway
          .watchSessions()
          .listen((list) => seen.add([for (final s in list) s.id]));
      addTearDown(sub.cancel);

      // A new session appears on the FIRST project while the phone watches.
      // The desktop groups its own list, so its order is a1, a2, b1.
      final rows = {...fake.sessions};
      fake.sessions.clear();
      fake.sessions['a1'] = rows['a1']!;
      addRow('a2', title: 'A two', repositoryId: 'r1', repositoryName: 'alpha');
      fake.sessions['b1'] = rows['b1']!;
      // Opening it subscribes the phone, which is what makes the host push
      // this session's `session.changed` — a row the cached list never held.
      await gateway.transcript('a2').first.timeout(const Duration(seconds: 5));
      await service!.notifySessionsChanged();

      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (seen.isEmpty || seen.last.length != 3) {
        if (DateTime.now().isAfter(deadline)) fail('the newcomer never landed');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(seen.last, ['a1', 'a2', 'b1'], reason: "the host's own order");
      for (final list in seen) {
        if (!list.contains('a2')) continue;
        expect(
          list,
          ['a1', 'a2', 'b1'],
          reason: 'no frame ever put the arrival after another project — that '
              'is the jump the user reported',
        );
      }
    });
  });

  group('on screen', () {
    testWidgets('two projects sharing a folder name get two headers', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: const [
          CompanionSessionSummary(
            id: 's1',
            title: 'First checkout',
            agentLabel: 'Claude Code  ·  running',
            projectName: 'app',
            projectId: 'r1',
          ),
          CompanionSessionSummary(
            id: 's2',
            title: 'Second checkout',
            agentLabel: 'Claude Code  ·  running',
            projectName: 'app',
            projectId: 'r2',
          ),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      expect(find.text('app'), findsNWidgets(2));
      expect(find.text('1 session'), findsNWidgets(2));
    });

    testWidgets("the host's order survives grouping", (tester) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: const [
          CompanionSessionSummary(
            id: 'z',
            title: 'Zebra',
            agentLabel: 'a',
            projectName: 'alpha',
            projectId: 'r1',
          ),
          CompanionSessionSummary(
            id: 'a',
            title: 'Apple',
            agentLabel: 'a',
            projectName: 'beta',
            projectId: 'r2',
          ),
          CompanionSessionSummary(
            id: 'm',
            title: 'Mango',
            agentLabel: 'a',
            projectName: 'alpha',
            projectId: 'r1',
          ),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      // Loop 82 put the two levels on two screens, so the whole order is read
      // by walking it: the projects in the order the index lists them, and
      // inside each, the sessions in the order that project's screen lists
      // them. The assertion below is the one this file has always made.
      final titles = <String>[];
      for (final project in ['alpha', 'beta']) {
        await tester.tap(find.text(project));
        await tester.pumpAndSettle();
        titles.addAll(
          tester
              .widgetList<SessionCard>(find.byType(SessionCard))
              .map((card) => card.title),
        );
        expect(find.byType(ProjectSessionsScreen), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }

      // alpha first (it held the first row), with its two rows in host order,
      // then beta — and never an alphabetical re-sort.
      expect(titles, ['Zebra', 'Mango', 'Apple']);
      expect(find.text('2 sessions'), findsOneWidget);
    });

    testWidgets('an archived session is shown, and says it is archived', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: const [
          CompanionSessionSummary(
            id: 's1',
            title: 'Old work',
            agentLabel: 'Claude Code  ·  idle',
            projectName: 'app',
            archived: true,
          ),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      expect(find.text('Old work'), findsOneWidget);
      expect(find.textContaining('archived'), findsOneWidget);
    });

    testWidgets('a folder the host can no longer find is marked, alongside '
        'the whereabouts clause', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: const [
          CompanionSessionSummary(
            id: 's1',
            title: 'Gone',
            agentLabel: 'Claude Code  ·  idle',
            projectName: 'app',
            whereabouts: 'last seen 2h ago',
            folderMissing: true,
          ),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      expect(
        find.text('folder missing  ·  last seen 2h ago'),
        findsOneWidget,
      );
    });

    testWidgets('branch and sub-path render on the card when the host sends '
        'them', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: const [
          CompanionSessionSummary(
            id: 's1',
            title: 'Fix login',
            agentLabel: 'Claude Code  ·  running',
            projectName: 'app',
            branch: 'fix/login',
            subPath: 'packages/api',
            worktree: true,
            whereabouts: 'running here',
          ),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      final card = tester.widget<SessionCard>(find.byType(SessionCard));
      expect(card.branch, 'fix/login');
      expect(card.subPath, 'packages/api');
      expect(card.worktree, isTrue);
    });
  });
}
