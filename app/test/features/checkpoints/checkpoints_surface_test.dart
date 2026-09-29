import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/side_panel.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_providers.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala/src/features/checkpoints/presentation/checkpoints_view.dart';
import 'package:agent_cli/process.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';

/// The checkpoint reads the panel costs, counted at the server: every
/// checkpoint the surface draws is asked for, so a closed panel that asked
/// nothing has subscribed to nothing.
int _checkpointReads(FakeDataServer server) =>
    server.requests.where((kind) => kind.startsWith('checkpoints.')).length;

/// **The Checkpoints surface, as the context panel actually offers it.**
///
/// The finding this closes: `CheckpointsView` existed and nothing built it, so
/// the only undo the app has for an agent's edits was reachable by an agent
/// through MCP and by nobody through the window.
void main() {
  const repo = EnvironmentPath(environmentId: 'local', path: '/src/demo');
  final captured = testTime.add(const Duration(hours: 1));
  late TestMachine db;
  late FakeDataServer server;
  late DataClient client;
  var readsBefore = 0;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    client = await server.connect();
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
  });

  void seed({int count = 2}) {
    for (var i = 1; i <= count; i++) {
      server.checkpointRows.insert(
        Checkpoint(
          id: 'ckpt$i',
          sessionId: 's1',
          repository: repo,
          sequence: 0,
          treeSha: 'tree$i',
          commitSha: 'commit$i',
          parentCommitSha: null,
          headSha: null,
          reason: CheckpointReason.turn,
          createdAt: captured,
        ),
      );
    }
    readsBefore = _checkpointReads(server);
  }

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        dataClientProvider.overrideWithValue(client),
        panelSessionIdProvider.overrideWithValue('s1'),
        // Two hours after the capture, so the age on each row is the test's
        // own arithmetic rather than the wall clock's.
        clockProvider.overrideWithValue(
          FixedClock(captured.add(const Duration(hours: 2))),
        ),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// Opens the panel straight on Checkpoints, for the tests whose point is
  /// what the surface shows rather than how it is reached.
  Future<void> openCheckpoints(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    container
        .read(sidePanelProvider.notifier)
        .show(SidePanelSurface.checkpoints);
    await tester.pumpAndSettle();
  }

  test('Checkpoints is the context panel\'s History tab', () {
    expect(
      SidePanelSurface.offered(debugMode: false),
      contains(SidePanelSurface.checkpoints),
    );
    expect(ContextTab.of(SidePanelSurface.checkpoints), ContextTab.history);
    expect(ContextTab.history.surfaces.first, SidePanelSurface.checkpoints);
    // It describes a *session*'s turns, not the selected checkout, so the
    // repository context line above the scoped surfaces would answer a
    // question nobody asked here.
    expect(SidePanelSurface.checkpoints.scopedToRepository, isFalse);
    expect(
      SidePanel.iconFor(SidePanelSurface.checkpoints).fontPackage,
      'picons',
    );
  });

  testWidgets('the History tab opens it and lists the session\'s checkpoints', (
    tester,
  ) async {
    seed();
    final container = await pumpApp(tester);

    container.read(sidePanelProvider.notifier).show(SidePanelSurface.changes);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel(ContextTab.history.label));
    await tester.pumpAndSettle();

    expect(container.read(sidePanelProvider), SidePanelSurface.checkpoints);
    expect(find.byType(CheckpointsView), findsOneWidget);
    expect(find.textContaining('Turn #2'), findsOneWidget);
    expect(find.textContaining('Turn #1'), findsOneWidget);
  });

  testWidgets('every row says how old its capture is (§19)', (tester) async {
    seed(count: 1);
    await openCheckpoints(tester, await pumpApp(tester));

    expect(find.textContaining('2h ago'), findsOneWidget);
    // Never a bare timestamp: a reading without its age is the confident
    // false statement §19 exists to delete.
    expect(find.textContaining(captured.toLocal().toString()), findsNothing);
  });

  testWidgets('a closed panel costs zero checkpoint reads', (tester) async {
    seed();
    final container = await pumpApp(tester);

    // The panel starts closed, so Checkpoints has never been built.
    expect((_checkpointReads(server) - readsBefore), 0);
    expect(container.exists(sessionCheckpointsProvider('s1')), isFalse);

    await openCheckpoints(tester, container);
    expect((_checkpointReads(server) - readsBefore), greaterThan(0));

    // Closing it disposes the subscription again — nothing keeps reading
    // behind a panel nobody is looking at.
    container.read(sidePanelProvider.notifier).collapse();
    await tester.pumpAndSettle();
    final settled = (_checkpointReads(server) - readsBefore);
    expect(container.exists(sessionCheckpointsProvider('s1')), isFalse);
    await tester.pump(const Duration(seconds: 30));
    expect(
      (_checkpointReads(server) - readsBefore),
      settled,
      reason: 'nothing polls',
    );
  });
}
