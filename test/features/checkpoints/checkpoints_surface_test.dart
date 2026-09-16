import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/side_panel.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_providers.dart';
import 'package:karmashala/src/features/checkpoints/data/checkpoint_dao.dart';
import 'package:karmashala/src/features/checkpoints/domain/checkpoint.dart';
import 'package:karmashala/src/features/checkpoints/presentation/checkpoints_view.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// A DAO that counts the reads the panel costs.
///
/// The number, not a proxy for it: every checkpoint the surface draws comes
/// through one of these two calls, so a closed panel that reads zero has
/// subscribed to nothing.
class _CountingCheckpointDao extends CheckpointDao {
  _CountingCheckpointDao(super.db);

  int reads = 0;

  @override
  List<Checkpoint> forSession(String sessionId) {
    reads++;
    return super.forSession(sessionId);
  }

  @override
  List<Checkpoint> recent({int limit = 50}) {
    reads++;
    return super.recent(limit: limit);
  }
}

/// **The Checkpoints surface, as the rail actually offers it.**
///
/// The finding this closes: `CheckpointsView` existed and nothing built it, so
/// the only undo the app has for an agent's edits was reachable by an agent
/// through MCP and by nobody through the window.
void main() {
  const repo = EnvironmentPath(environmentId: 'local', path: '/src/demo');
  final captured = testTime.add(const Duration(hours: 1));
  late AppDatabase db;
  late _CountingCheckpointDao dao;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    dao = _CountingCheckpointDao(db);
  });
  tearDown(() => db.close());

  void seed({int count = 2}) {
    for (var i = 1; i <= count; i++) {
      dao.insert(
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
    dao.reads = 0;
  }

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        checkpointDaoProvider.overrideWithValue(dao),
        checkpointsPanelSessionIdProvider.overrideWithValue('s1'),
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

  /// The rail's own glyph for the surface. Once the panel is open its header
  /// carries the same label, so the button has to be named by the thing only
  /// the rail has: something to click.
  Finder railButton() => find.descendant(
    of: find.bySemanticsLabel(SidePanelSurface.checkpoints.label),
    matching: find.byType(InkWell),
  );

  test('Checkpoints is offered on the rail like any other surface', () {
    expect(
      SidePanelSurface.offered(debugMode: false),
      contains(SidePanelSurface.checkpoints),
    );
    // It describes a *session*'s turns, not the selected checkout, so the
    // repository context line above the scoped surfaces would answer a
    // question nobody asked here.
    expect(SidePanelSurface.checkpoints.scopedToRepository, isFalse);
    expect(
      SidePanel.iconFor(SidePanelSurface.checkpoints).fontPackage,
      'picons',
    );
  });

  testWidgets('the rail opens it and lists the session\'s checkpoints', (
    tester,
  ) async {
    seed();
    final container = await pumpApp(tester);

    await tester.tap(railButton());
    await tester.pumpAndSettle();

    expect(container.read(sidePanelProvider), SidePanelSurface.checkpoints);
    expect(find.byType(CheckpointsView), findsOneWidget);
    expect(find.textContaining('Turn #2'), findsOneWidget);
    expect(find.textContaining('Turn #1'), findsOneWidget);
  });

  testWidgets('every row says how old its capture is (§19)', (tester) async {
    seed(count: 1);
    await pumpApp(tester);

    await tester.tap(railButton());
    await tester.pumpAndSettle();

    expect(find.textContaining('2h ago'), findsOneWidget);
    // Never a bare timestamp: a reading without its age is the confident
    // false statement §19 exists to delete.
    expect(find.textContaining(captured.toLocal().toString()), findsNothing);
  });

  testWidgets('a closed panel costs zero checkpoint reads', (tester) async {
    seed();
    final container = await pumpApp(tester);

    // The panel opens on Changes, so Checkpoints has never been built.
    expect(dao.reads, 0);
    expect(container.exists(sessionCheckpointsProvider('s1')), isFalse);

    await tester.tap(railButton());
    await tester.pumpAndSettle();
    expect(dao.reads, greaterThan(0));

    // Closing it disposes the subscription again — nothing keeps reading
    // behind a panel nobody is looking at.
    await tester.tap(railButton());
    await tester.pumpAndSettle();
    final settled = dao.reads;
    expect(container.exists(sessionCheckpointsProvider('s1')), isFalse);
    await tester.pump(const Duration(seconds: 30));
    expect(dao.reads, settled, reason: 'nothing polls');
  });
}
