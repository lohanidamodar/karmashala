import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/checkout.dart';
import 'package:karmashala/src/features/explorer/application/explorer_view_mode.dart';
import 'package:karmashala/src/features/explorer/presentation/activity_by_day_view.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'explorer_default_view_test.dart' show explorerSemanticsDump;

/// **The by-day lens is a separate view.** It swaps the Explorer's body and
/// back; the project tree beneath it is the default, is not changed by the
/// lens existing (`explorer_default_view_test` freezes it), and comes back
/// exactly as it was left.
void main() {
  late AppDatabase db;
  final now = DateTime.utc(2026, 9, 21, 12);

  EnvironmentPath at(String path) =>
      EnvironmentPath(environmentId: 'windows', path: path);

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    AgentInstallationDao(db).insert(agentInstallation());
    // Enough projects that the tree scrolls.
    for (var i = 0; i < 40; i++) {
      final id = 'p$i';
      final name = switch (i) {
        0 => 'Alpha',
        1 => 'Beta',
        _ => 'Project $i',
      };
      final path = 'C:\\src\\${name.toLowerCase().replaceAll(' ', '')}';
      ProjectDao(db).insert(project(id: id, name: name, path: path));
      RepositoryDao(
        db,
      ).insert(repository(id: 'r$i', projectId: id, name: name, path: path));
    }
    void insert(String id, String repo, DateTime created, {String? worktree}) =>
        SessionDao(db).insert(
          Session(
            id: id,
            repositoryId: repo,
            agentInstallationId: 'a1',
            title: 'Fix the build',
            useWorktree: worktree != null,
            worktree: worktree == null ? null : at(worktree),
            status: SessionStatus.completed,
            createdAt: created,
          ),
        );
    // Two chats with one title, in two places, on two days.
    insert('today', 'r0', now.subtract(const Duration(hours: 1)));
    insert(
      'yesterday',
      'r1',
      now.subtract(const Duration(days: 1)),
      worktree: r'C:\wt\hotfix',
    );
  });
  tearDown(() => db.close());

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    List<Override> extra = const [],
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('w-')),
        clockProvider.overrideWithValue(FixedClock(now)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        ...extra,
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(
                  width: 320,
                  child: Semantics(
                    container: true,
                    explicitChildNodes: true,
                    child: const ExplorerPanel(),
                  ),
                ),
                const Expanded(child: SizedBox.shrink()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> openFromMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Filter sessions'));
    await tester.pumpAndSettle();
    // The menu is drawn last, over the lens bar that carries the same words.
    await tester.tap(find.text('Activity by day').last);
    await tester.pumpAndSettle();
  }

  ScrollableState treeScroll(WidgetTester tester) => tester.state(
    find
        .descendant(
          of: find.byType(ExplorerTreeView, skipOffstage: false),
          matching: find.byType(Scrollable, skipOffstage: false),
          skipOffstage: false,
        )
        .first,
  );

  testWidgets('the lens off is the default view, and a round trip through it '
      'restores the tree exactly — same state, same scroll, same semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final c = await pump(tester);
    expect(c.read(explorerLensProvider), ExplorerLens.projects);
    expect(find.byType(ActivityByDayView), findsNothing);

    await tester.drag(find.byType(ExplorerTreeView), const Offset(0, -400));
    await tester.pumpAndSettle();
    final offset = treeScroll(tester).position.pixels;
    expect(offset, greaterThan(0), reason: 'the tree must really scroll');
    final state = tester.state(find.byType(ExplorerTreeView));
    final before = explorerSemanticsDump(tester);

    await openFromMenu(tester);
    expect(c.read(explorerLensProvider), ExplorerLens.activity);
    expect(find.byType(ActivityByDayView), findsOneWidget);
    // Negative check: the dump does see the lens, so "equal" below is not
    // a dump that cannot tell views apart.
    final during = explorerSemanticsDump(tester);
    expect(during, isNot(before));
    expect(during, contains('Activity by day'));
    expect(during, isNot(contains('Project ')), reason: 'no tree row is heard');
    expect(find.byType(ExplorerTreeView), findsNothing);
    expect(
      find.byType(ExplorerTreeView, skipOffstage: false),
      findsOneWidget,
      reason: 'the tree is kept, offstage',
    );

    await tester.tap(find.byTooltip('Back to projects (Esc)'));
    await tester.pumpAndSettle();

    expect(c.read(explorerLensProvider), ExplorerLens.projects);
    expect(find.byType(ActivityByDayView), findsNothing);
    expect(
      tester.state(find.byType(ExplorerTreeView)),
      same(state),
      reason: 'the tree was kept, not rebuilt from nothing',
    );
    expect(treeScroll(tester).position.pixels, offset);
    expect(explorerSemanticsDump(tester), before);
    semantics.dispose();
  });

  testWidgets('every chat across projects, by day, told apart by project, '
      'folder and branch', (tester) async {
    await pump(tester);
    await openFromMenu(tester);

    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('YESTERDAY'), findsOneWidget);
    expect(find.text('Fix the build'), findsNWidgets(2));
    expect(top('TODAY'), lessThan(top('YESTERDAY')));
    // The folder is left out where it is only the project's name again.
    expect(find.text('Alpha  ·  alpha'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta  ·  hotfix'), findsOneWidget);
    expect(top('Alpha'), lessThan(top('YESTERDAY')));
    expect(top('Beta  ·  hotfix'), greaterThan(top('YESTERDAY')));
  });

  testWidgets('a branch is named only when a reading already exists, and the '
      'lens never asks for one', (tester) async {
    final hotfix = Checkout(at(r'C:\wt\hotfix'));
    var reads = 0;
    final c = await pump(
      tester,
      extra: [
        checkoutDeliveryProvider.overrideWith((ref, checkout) async {
          if (checkout == hotfix) reads++;
          return SessionDelivery(branch: 'hotfix-branch');
        }),
      ],
    );
    await openFromMenu(tester);
    expect(find.textContaining('hotfix-branch'), findsNothing);
    expect(reads, 0, reason: 'showing the lens runs no git');
    expect(c.exists(checkoutDeliveryProvider(hotfix)), isFalse);

    // Somebody else reads the checkout — a card, the Changes panel.
    final sub = c.listen(checkoutDeliveryProvider(hotfix), (_, _) {});
    await tester.pumpAndSettle();
    c.read(checkoutReadingsProvider.notifier).arrived(hotfix);
    await tester.pumpAndSettle();
    expect(find.text('Beta  ·  hotfix  ·  hotfix-branch'), findsOneWidget);
    expect(reads, 1);
    sub.close();
  });

  testWidgets('Escape goes back to the tree from a row', (tester) async {
    final c = await pump(tester);
    await openFromMenu(tester);
    Focus.of(tester.element(find.text('Fix the build').first)).requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(c.read(explorerLensProvider), ExplorerLens.projects);
    expect(find.text('Alpha').hitTestable(), findsOneWidget);
  });

  testWidgets('the menu item says when the lens is on, and picking it again '
      'goes back', (tester) async {
    final c = await pump(tester);
    await openFromMenu(tester);
    await openFromMenu(tester);
    expect(c.read(explorerLensProvider), ExplorerLens.projects);
  });
}
