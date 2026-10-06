import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/explorer/application/bulk_session_delete.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_provider.dart';
import 'package:karmashala/src/features/explorer/application/session_selection.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **What one bulk delete costs, counted at the size the owner hit.**
///
/// "UI lags when selecting and deleting multiple sessions or a project with
/// sessions." The store work was batched before the data moved behind the
/// server; what was left per row is the server traffic. Counted, not timed:
///
/// * requests the deleting client sends — one act, one request;
/// * change events its copy fires — each wakes the listeners on that copy;
/// * session-list publishes on **another** client (the phone, or the desktop
///   when the phone deletes) — each one rebuilds that client's tree, inbox and
///   tabs, so N rows told one at a time are N full rebuilds there.
void main() {
  /// 120 rows, 80 ticked: half native, half imported history.
  const natives = 60;
  const imported = 60;
  const ticked = 80;

  late FakeDataServer server;

  void seed({int nativeCount = natives, int importedCount = imported}) {
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    for (var i = 0; i < nativeCount; i++) {
      server.sessionRows.insert(
        Session(
          id: 'n$i',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Native $i',
          useWorktree: false,
          status: SessionStatus.completed,
          createdAt: testTime.add(Duration(minutes: i)),
          externalSessionId: 'ext-n$i',
        ),
      );
    }
    for (var i = 0; i < importedCount; i++) {
      server.importedRows.insertIfAbsent(
        ImportedSession(
          id: 'i$i',
          repositoryId: 'r1',
          cli: AgentIds.claudeCode,
          externalId: 'cli-i$i',
          environmentId: 'windows',
          filePath: 'unused-$i.jsonl',
          storeHome: 'unused',
          isSubagent: false,
          preview: 'Imported $i',
          title: 'Imported $i',
          createdAt: testTime,
        ),
      );
    }
  }

  /// One client's container, with the sessions copy and its signals live.
  ProviderContainer clientOf(DataClient client) {
    final container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(client),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);
    container.read(sessionsDataProvider);
    container.read(importedSessionsProvider);
    return container;
  }

  /// Counts what one client heard: list publishes and copy change events.
  ({int Function() publishes, int Function() copyEvents}) watch(
    ProviderContainer container,
  ) {
    var publishes = 0;
    var events = 0;
    container.listen(sessionsRevisionProvider, (_, _) => publishes++);
    final client = container.read(dataClientProvider);
    final subscriptions = [
      client.sessions.changes.listen((_) => events++),
      client.sessionLinks.changes.listen((_) => events++),
      client.imported.changes.listen((_) => events++),
    ];
    addTearDown(() async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    });
    return (publishes: () => publishes, copyEvents: () => events);
  }

  List<String> tickedIds() => [
    for (var i = 0; i < ticked ~/ 2; i++) 'n$i',
    for (var i = 0; i < ticked ~/ 2; i++) 'i$i',
  ];

  int deletesSince(int asked) =>
      server.requests.skip(asked).where((k) => k.contains('delete')).length;

  group('deleting $ticked of ${natives + imported} sessions', () {
    setUp(() {
      server = FakeDataServer();
      seed();
    });

    test('is one request, one copy event per table, and one publish on '
        'every client', () async {
      final desktop = clientOf(await server.connect());
      final phone = clientOf(await server.connect(serverOnThisMachine: false));
      final onDesktop = watch(desktop);
      final onPhone = watch(phone);
      final asked = server.requests.length;

      final bulk = desktop.read(sessionBulkDeleteProvider);
      bulk.run(bulk.resolve(tickedIds()), deleteFromCli: false);
      await desktop.read(sessionsDataProvider).settled();
      await pumpEventQueue();

      final cost = (
        requests: deletesSince(asked),
        desktopPublishes: onDesktop.publishes(),
        desktopCopyEvents: onDesktop.copyEvents(),
        phonePublishes: onPhone.publishes(),
        phoneCopyEvents: onPhone.copyEvents(),
      );
      // ignore: avoid_print
      print('BULK-DELETE-COST desktop-initiated $cost');

      expect(desktop.read(sessionsDataProvider).getAll(), hasLength(20));
      expect(phone.read(sessionsDataProvider).getAll(), hasLength(20));
      expect(phone.read(importedSessionsProvider).getAll(), hasLength(20));
      expect(cost.requests, 1, reason: 'one request for the whole selection');
      expect(cost.desktopPublishes, 1);
      expect(
        cost.desktopCopyEvents,
        lessThanOrEqualTo(3),
        reason: 'one event per table — sessions, links, imported — not per row',
      );
      expect(
        cost.phonePublishes,
        1,
        reason: 'the other client is told once and rebuilds once',
      );
      expect(cost.phoneCopyEvents, lessThanOrEqualTo(3));
    });

    test('from the phone, the desktop rebuilds once', () async {
      final desktop = clientOf(await server.connect());
      final phone = clientOf(await server.connect(serverOnThisMachine: false));
      final onDesktop = watch(desktop);
      final asked = server.requests.length;

      final bulk = phone.read(sessionBulkDeleteProvider);
      bulk.run(bulk.resolve(tickedIds()), deleteFromCli: false);
      await phone.read(sessionsDataProvider).settled();
      await pumpEventQueue();

      final cost = (
        requests: deletesSince(asked),
        desktopPublishes: onDesktop.publishes(),
        desktopCopyEvents: onDesktop.copyEvents(),
      );
      // ignore: avoid_print
      print('BULK-DELETE-COST phone-initiated $cost');

      expect(desktop.read(sessionsDataProvider).getAll(), hasLength(20));
      expect(cost.requests, 1);
      expect(cost.desktopPublishes, 1);
      expect(cost.desktopCopyEvents, lessThanOrEqualTo(3));
    });

    test(
      'a row another client already deleted does not sink the rest',
      () async {
        final desktop = clientOf(await server.connect());
        final bulk = desktop.read(sessionBulkDeleteProvider);
        final targets = bulk.resolve(tickedIds());
        // Gone at the server between the tick and the delete.
        server.sessionRows.delete('n0');
        server.importedRows.delete('i0');

        bulk.run(targets, deleteFromCli: false);
        await desktop.read(sessionsDataProvider).settled();
        await pumpEventQueue();

        expect(server.sessionRows.getAll(), hasLength(20));
        expect(server.importedRows.getByRepository('r1'), hasLength(20));
        expect(desktop.read(sessionsDataProvider).getAll(), hasLength(20));
      },
    );
  });

  group('deleting a project of 50 sessions', () {
    setUp(() {
      server = FakeDataServer();
      seed(nativeCount: 50, importedCount: 10);
    });

    test('is one request and one publish on every client', () async {
      final desktop = clientOf(await server.connect());
      final phone = clientOf(await server.connect(serverOnThisMachine: false));
      final onDesktop = watch(desktop);
      final onPhone = watch(phone);
      desktop.read(projectsControllerProvider);
      final asked = server.requests.length;

      await desktop
          .read(projectsControllerProvider.notifier)
          .deleteProject('p1');
      await pumpEventQueue();

      final cost = (
        requests: deletesSince(asked),
        desktopPublishes: onDesktop.publishes(),
        desktopCopyEvents: onDesktop.copyEvents(),
        phonePublishes: onPhone.publishes(),
        phoneCopyEvents: onPhone.copyEvents(),
      );
      // ignore: avoid_print
      print('PROJECT-DELETE-COST $cost');

      expect(phone.read(sessionsDataProvider).getAll(), isEmpty);
      expect(cost.requests, 1);
      expect(cost.desktopPublishes, 1);
      expect(cost.phonePublishes, 1);
      expect(cost.desktopCopyEvents, lessThanOrEqualTo(3));
      expect(cost.phoneCopyEvents, lessThanOrEqualTo(3));
    });
  });

  group('the Explorer tree', () {
    late TestMachine db;

    setUp(() {
      db = TestMachine();
      server = FakeDataServer()..runsOn(db);
      server.environmentRows.upsert(windowsEnv());
      server.projectRows.insert(
        project(id: 'p1', name: 'Hub', path: r'C:\hub'),
      );
      server.repositoryRows.insert(
        repository(id: 'r1', name: 'hub', path: r'C:\hub'),
      );
      server.installationRows.insert(agentInstallation());
      for (var i = 0; i < natives; i++) {
        db.server.sessionRows.insert(
          Session(
            id: 'n$i',
            repositoryId: 'r1',
            agentInstallationId: 'a1',
            title: 'Session $i',
            useWorktree: false,
            status: SessionStatus.completed,
            createdAt: testTime.add(Duration(minutes: i)),
            externalSessionId: 'ext-n$i',
          ),
        );
      }
    });

    testWidgets('is rebuilt once for a bulk delete, and selecting costs '
        'nothing that grows with the selection', (tester) async {
      tester.view.physicalSize = const Size(460, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(machine: db),
          await server.override(),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(),
          ),
          availableSystemTerminalsProvider.overrideWith(
            (ref) async => const <SystemTerminal>[],
          ),
          autoImportRunnerProvider.overrideWithValue(
            (_) async => const ImportSummary(),
          ),
          agentSessionStatusProvider.overrideWith(
            (ref, id) => const Stream<AgentStatusReport>.empty(),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hub'));
      await tester.pumpAndSettle();

      var trees = 0;
      container.listen(explorerTreeProvider, (_, _) => trees++);
      final selection = container.read(sessionSelectionProvider.notifier)
        ..enter();
      await tester.pumpAndSettle();
      trees = 0;
      for (var i = 0; i < 40; i++) {
        selection.toggle('n$i');
        await tester.pump();
      }
      final treesWhileTicking = trees;

      final asked = server.requests.length;
      trees = 0;
      final bulk = container.read(sessionBulkDeleteProvider);
      bulk.run(
        bulk.resolve(container.read(sessionSelectionProvider).ids),
        deleteFromCli: false,
      );
      await tester.runAsync(
        () => container.read(sessionsDataProvider).settled(),
      );
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print(
        'EXPLORER-COST ticks=40 treeRebuildsWhileTicking=$treesWhileTicking '
        'treeRebuildsOnDelete=$trees requests=${deletesSince(asked)}',
      );
      expect(container.read(sessionsDataProvider).getAll(), hasLength(20));
      expect(treesWhileTicking, 0, reason: 'a tick never rebuilds the tree');
      expect(trees, 1, reason: 'one delete, one tree');
      expect(deletesSince(asked), 1);
    });
  });
}
