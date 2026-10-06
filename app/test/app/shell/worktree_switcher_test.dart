import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/side_panel_context.dart';
import 'package:karmashala/src/app/shell/worktree_switcher.dart';
import 'package:karmashala/src/features/explorer/application/checkout_picker.dart';
import 'package:karmashala/src/features/explorer/application/project_head.dart';
import 'package:karmashala/src/features/explorer/application/worktree_choices.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// The worktree switcher that replaced the side panel's wall of chips: one
/// compact control, however many worktrees a repository has.
void main() {
  EnvironmentPath at(String path) =>
      EnvironmentPath(environmentId: 'windows', path: path);

  const root = r'C:\src\demo';
  const wtRoot = r'C:\src\.demo-worktrees\wt-';
  String wt(int n) => '$wtRoot${'$n'.padLeft(2, '0')}';
  String branchOf(int n) => 'feature/task-${'$n'.padLeft(2, '0')}';

  group('arranging', () {
    WorktreeChoice choice(
      String branch, {
      bool current = false,
      bool active = false,
      DateTime? last,
      bool merged = false,
      int sessions = 0,
      int? dirty = 0,
    }) => WorktreeChoice(
      path: at('C:\\src\\wt-${branch.replaceAll('/', '-')}'),
      branch: branch,
      current: current,
      active: active,
      lastActivity: last,
      merged: merged,
      sessions: sessions,
      dirtyFiles: dirty,
    );

    test('current, then live, then by last activity, then by name', () {
      final arranged = arrangeWorktreeChoices([
        choice('b-idle'),
        choice('a-idle'),
        choice('old', last: DateTime.utc(2026, 1, 1)),
        choice('live', active: true),
        choice('new', last: DateTime.utc(2026, 3, 1)),
        choice('here', current: true),
      ]);

      expect(
        [for (final c in arranged.open) c.label],
        ['here', 'live', 'new', 'old', 'a-idle', 'b-idle'],
      );
      expect(arranged.merged, isEmpty);
    });

    test('only a merged, clean, unused worktree is stale', () {
      final arranged = arrangeWorktreeChoices([
        choice('stale', merged: true),
        choice('dirty', merged: true, dirty: 2),
        choice('unread', merged: true, dirty: null),
        choice('used', merged: true, sessions: 1),
        choice('here', merged: true, current: true),
      ]);

      expect([for (final c in arranged.merged) c.label], ['stale']);
      expect(arranged.open, hasLength(4));
    });

    test('search is blind to case and separators, by branch or folder', () {
      final choices = [
        choice('session/fix-the-login-form'),
        choice('feature/inbox'),
      ];

      expect(
        filterWorktreeChoices(choices, 'fix login').single.label,
        'session/fix-the-login-form',
      );
      expect(filterWorktreeChoices(choices, 'Feature_Inbox'), hasLength(1));
      expect(
        filterWorktreeChoices(choices, 'wt'),
        hasLength(2),
        reason: 'the folder is searched too',
      );
      expect(filterWorktreeChoices(choices, 'nothing'), isEmpty);
    });
  });

  group('with fifteen worktrees', () {
    late FakeDataServer server;
    late Override data;

    /// The listing `git worktree list` gives: the main checkout and 14 more.
    final listing = [
      GitWorktree(path: at('C:/src/demo'), branch: 'main'),
      for (var n = 1; n <= 14; n++)
        GitWorktree(path: at(wt(n).replaceAll(r'\', '/')), branch: branchOf(n)),
    ];

    /// Readings the delivery cache already holds: three merged and clean,
    /// one with changes.
    final readings = <Checkout, SessionDelivery>{
      for (final n in [10, 11, 12])
        Checkout(at(wt(n))): const SessionDelivery(
          aheadOfBase: 0,
          behindBase: 3,
          dirtyFiles: 0,
        ),
      Checkout(at(wt(4))): const SessionDelivery(
        aheadOfBase: 2,
        behindBase: 1,
        dirtyFiles: 5,
      ),
    };

    setUp(() async {
      server = FakeDataServer();
      data = await server.override();
      server.environmentRows.upsert(windowsEnv());
      server.projectRows.insert(project(id: 'p1', path: root));
      server.installationRows.insert(agentInstallation());
      server.repositoryRows.insert(
        repository(id: 'main', projectId: 'p1', name: 'demo', path: root),
      );
      // wt-14 is on disk but not recorded yet.
      for (var n = 1; n <= 13; n++) {
        server.repositoryRows.insert(
          repository(
            id: 'wt$n',
            projectId: 'p1',
            name: 'wt-${'$n'.padLeft(2, '0')}',
            path: wt(n),
          ),
        );
      }
      server.sessionRows
        ..insert(
          session(
            id: 's-live',
            repositoryId: 'wt5',
            status: SessionStatus.running,
          ),
        )
        ..insert(
          session(
            id: 's-new',
            repositoryId: 'wt3',
          ).copyWith(createdAt: DateTime.utc(2026, 5, 1)),
        )
        ..insert(
          session(
            id: 's-old',
            repositoryId: 'wt7',
          ).copyWith(createdAt: DateTime.utc(2026, 4, 1)),
        );
    });

    ProviderContainer makeContainer() {
      final container = ProviderContainer(
        overrides: [
          data,
          repoWorktreesProvider.overrideWith((ref) async => listing),
          checkoutHeadBranchProvider.overrideWith(
            (ref, checkout) async =>
                {for (final w in listing) Checkout(w.path): w.branch}[checkout],
          ),
          checkoutDeliveryProvider.overrideWith(
            (ref, checkout) async =>
                readings[checkout] ?? SessionDelivery.unknown,
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(selectedRepositoryIdProvider.notifier).select('wt2');
      return container;
    }

    /// Warms the delivery cache the way the Explorer's rows would have.
    Future<void> warm(ProviderContainer container) async {
      for (final checkout in readings.keys) {
        container.listen(checkoutDeliveryProvider(checkout), (_, _) {});
        await container.read(checkoutDeliveryProvider(checkout).future);
      }
    }

    Future<void> pumpLine(
      WidgetTester tester,
      ProviderContainer container, {
      double width = 320,
      Size window = const Size(1440, 900),
    }) async {
      tester.view.physicalSize = window;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: SizedBox(
                  width: width,
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [SidePanelContextLine()],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('worktree-switcher')));
      await tester.pumpAndSettle();
    }

    List<String> labels(WidgetTester tester) => [
      for (final text in tester.widgetList<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('worktree-switcher-list')),
          matching: find.byType(Text),
        ),
      ))
        if (text.data case final data?
            when data == 'main' || data.startsWith('feature/'))
          data,
    ];

    test('orders current, live, recent, then the rest; merged apart', () async {
      final container = makeContainer();
      container.listen(worktreeChoicesProvider, (_, _) {});
      await container.read(repoWorktreesProvider.future);
      await warm(container);

      final choices = container.read(worktreeChoicesProvider)!;

      expect(
        [for (final c in choices.open) c.label],
        [
          branchOf(2),
          branchOf(5),
          branchOf(3),
          branchOf(7),
          'main',
          for (final n in [1, 4, 6, 8, 9, 13, 14]) branchOf(n),
        ],
      );
      expect(
        [for (final c in choices.merged) c.label],
        [
          for (final n in [10, 11, 12]) branchOf(n),
        ],
      );
      final four = choices.open.firstWhere((c) => c.label == branchOf(4));
      expect((four.dirtyFiles, four.ahead, four.behind), (5, 2, 1));
      expect(
        choices.open.firstWhere((c) => c.label == branchOf(14)).repository,
        isNull,
      );
    });

    testWidgets('the line stays one line high, and names the branch', (
      tester,
    ) async {
      final container = makeContainer();
      await pumpLine(tester, container);

      expect(find.text('wt-02'), findsOneWidget);
      expect(find.text(branchOf(2)), findsOneWidget);
      expect(
        tester.getSize(find.byType(SidePanelContextLine)).height,
        Chrome.statusBar,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('opens on a list that scrolls at its maximum height', (
      tester,
    ) async {
      final container = makeContainer();
      await warm(container);
      await pumpLine(tester, container);
      await open(tester);

      final list = find.byKey(const ValueKey('worktree-switcher-list'));
      expect(list, findsOneWidget);
      expect(
        tester.getSize(list).height,
        lessThanOrEqualTo(kWorktreeSwitcherListMaxHeight),
      );
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)),
          )
          .position;
      expect(position.maxScrollExtent, greaterThan(0));
      expect(labels(tester).first, branchOf(2));
      expect(find.text('Merged (3)'), findsOneWidget);
      expect(find.text(branchOf(10)), findsNothing, reason: 'folded');
      expect(find.text('Clean up…'), findsOneWidget);
      expect(find.text('1 session'), findsNWidgets(3));
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('worktree-switcher-merged')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(branchOf(12)),
        50,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text(branchOf(12)), findsOneWidget);
    });

    testWidgets('typing searches, and Enter picks the first match', (
      tester,
    ) async {
      final container = makeContainer();
      await pumpLine(tester, container);
      await open(tester);

      await tester.enterText(find.byType(TextField), 'task 09');
      await tester.pumpAndSettle();
      expect(labels(tester), [branchOf(9)]);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(container.read(selectedCheckoutProvider)?.id, 'wt9');
      expect(
        find.byKey(const ValueKey('worktree-switcher-panel')),
        findsNothing,
      );
    });

    testWidgets('a search finds merged worktrees without unfolding them', (
      tester,
    ) async {
      final container = makeContainer();
      await warm(container);
      await pumpLine(tester, container);
      await open(tester);

      await tester.enterText(find.byType(TextField), 'task 11');
      await tester.pumpAndSettle();

      expect(labels(tester), [branchOf(11)]);
      expect(find.text('Merged (1)'), findsOneWidget);
    });

    testWidgets('arrows move the highlight, Enter picks, Esc closes', (
      tester,
    ) async {
      final container = makeContainer();
      await pumpLine(tester, container);
      await open(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      // Second below the current one: the most recent session's.
      expect(container.read(selectedCheckoutProvider)?.id, 'wt3');

      await open(tester);
      expect(
        find.byKey(const ValueKey('worktree-switcher-panel')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('worktree-switcher-panel')),
        findsNothing,
      );
      expect(container.read(selectedCheckoutProvider)?.id, 'wt3');
    });

    testWidgets('a tap outside closes it', (tester) async {
      final container = makeContainer();
      await pumpLine(tester, container);
      await open(tester);

      await tester.tapAt(const Offset(20, 800));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('worktree-switcher-panel')),
        findsNothing,
      );
    });

    for (final (name, window, width) in [
      ('desktop', const Size(1440, 900), 320.0),
      ('phone', const Size(390, 844), 390.0),
    ]) {
      testWidgets('fits the $name window', (tester) async {
        final container = makeContainer();
        await warm(container);
        await pumpLine(tester, container, width: width, window: window);
        await open(tester);

        final panel = find.byKey(const ValueKey('worktree-switcher-panel'));
        final rect = tester.getRect(panel);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(window.width));
        expect(rect.bottom, lessThanOrEqualTo(window.height));
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('one worktree is still the same single control', (tester) async {
    final server = FakeDataServer();
    final data = await server.override();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project(id: 'p1', path: root));
    server.repositoryRows.insert(
      repository(id: 'main', projectId: 'p1', name: 'demo', path: root),
    );
    final container = ProviderContainer(
      overrides: [
        data,
        repoWorktreesProvider.overrideWith(
          (ref) async => [GitWorktree(path: at(root), branch: 'main')],
        ),
        checkoutHeadBranchProvider.overrideWith(
          (ref, checkout) async => 'main',
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedRepositoryIdProvider.notifier).select('main');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SidePanelContextLine())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('worktree-switcher')), findsOneWidget);
    expect(find.text('main'), findsOneWidget);
    expect(find.byType(Wrap), findsNothing);
  });
}
