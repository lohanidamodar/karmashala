import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:karmashala/src/features/cli_detection/domain/imported_session.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/session_selection.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/explorer/presentation/session_card.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/application/repository_discovery_provider.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';

/// **Selection mode: the checkboxes, and what a click means while they are on
/// screen.**
///
/// The Explorer had exactly one selected session — the transcript on the right
/// — and no way to say "these four". The owner chose a mode with checkboxes
/// over Ctrl-click, and accepted its one real cost: while the mode is on, a
/// plain click ticks a row rather than opening it. Everything here is about
/// keeping that trade honest — the mode is entered from a visible button, it is
/// left from two of them, and leaving takes the selection with it.
///
/// The other half is what the selection is *keyed by*. The tree refreshes on a
/// poll and re-sorts whenever a session is touched, so a set held by row index
/// would follow the wrong rows across a refresh; a set held by id survives one,
/// and a row that has genuinely gone drops out rather than waiting to fail a
/// delete.
void main() {
  late AppDatabase db;
  late FakeRepositoryDiscoveryService discovery;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project(id: 'p1', name: 'Hub', path: r'C:\hub'));
    RepositoryDao(
      db,
    ).insert(repository(id: 'r1', name: 'hub', path: r'C:\hub'));
    AgentInstallationDao(db).insert(agentInstallation());
    discovery = FakeRepositoryDiscoveryService();
  });
  tearDown(() => db.close());

  void addNative(String id, {required String title, int minutes = 0}) =>
      SessionDao(db).insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: title,
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: testTime.add(Duration(minutes: minutes)),
          externalSessionId: 'ext-$id',
        ),
      );

  void addImported(String id, {required String title, int minutes = 0}) =>
      ImportedSessionDao(db).insertIfAbsent(
        ImportedSession(
          id: id,
          repositoryId: 'r1',
          cli: AgentIds.claudeCode,
          externalId: 'cli-$id',
          environmentId: 'windows',
          filePath: 'C:\\store\\$id.jsonl',
          storeHome: r'C:\store',
          isSubagent: false,
          preview: title,
          title: title,
          updatedAt: testTime.add(Duration(minutes: minutes)),
          createdAt: testTime,
        ),
      );

  Widget host() {
    final container = _container(db, discovery);
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
    );
  }

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(460, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = _container(db, discovery);
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
    return container;
  }

  Future<void> enterSelection(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Select sessions'));
    await tester.pumpAndSettle();
  }

  /// The card carrying [title], so a test can ask whether *that row* is ticked
  /// rather than trusting a position in a list that re-sorts.
  SessionCard cardFor(WidgetTester tester, String title) => tester.widget(
    find.ancestor(of: find.text(title), matching: find.byType(SessionCard)),
  );

  group('entering and leaving', () {
    testWidgets('no checkboxes until the toolbar asks for them', (
      tester,
    ) async {
      addNative('n0', title: 'One');
      addNative('n1', title: 'Two', minutes: 1);
      final container = await pump(tester);

      expect(find.byType(SessionCard), findsNWidgets(2));
      expect(find.byType(Checkbox), findsNothing);
      expect(container.read(sessionSelectionProvider).active, isFalse);
    });

    testWidgets('entering shows one checkbox per row and the count strip', (
      tester,
    ) async {
      addNative('n0', title: 'One');
      addNative('n1', title: 'Two', minutes: 1);
      addImported('i0', title: 'Three', minutes: 2);
      await pump(tester);
      await enterSelection(tester);

      expect(find.byType(Checkbox), findsNWidgets(3));
      expect(find.text('0 selected'), findsOneWidget);
      // Both kinds are selectable — an imported conversation is as deletable as
      // a native row, and a mode that could only tick half of them would be a
      // trap the moment a project holds both.
      expect(cardFor(tester, 'Three').selecting, isTrue);
    });

    testWidgets('a plain click ticks the row instead of opening it', (
      tester,
    ) async {
      addNative('n0', title: 'One');
      addNative('n1', title: 'Two', minutes: 1);
      final container = await pump(tester);
      await enterSelection(tester);

      await tester.tap(find.text('Two'));
      await tester.pumpAndSettle();

      expect(container.read(sessionSelectionProvider).ids, {'n1'});
      expect(
        container.read(selectedSessionIdProvider),
        isNull,
        reason: 'a click in selection mode must not open the session',
      );
      expect(cardFor(tester, 'Two').ticked, isTrue);
      expect(cardFor(tester, 'One').ticked, isFalse);
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('the checkbox itself ticks the same row', (tester) async {
      addNative('n0', title: 'One');
      final container = await pump(tester);
      await enterSelection(tester);

      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();

      expect(container.read(sessionSelectionProvider).ids, {'n0'});
    });

    testWidgets('clicking a ticked row unticks it', (tester) async {
      addNative('n0', title: 'One');
      final container = await pump(tester);
      await enterSelection(tester);

      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();

      expect(container.read(sessionSelectionProvider).ids, isEmpty);
    });

    testWidgets('leaving from the toolbar clears the selection', (
      tester,
    ) async {
      addNative('n0', title: 'One');
      final container = await pump(tester);
      await enterSelection(tester);
      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();
      expect(container.read(sessionSelectionProvider).ids, {'n0'});

      await tester.tap(find.byTooltip('Leave selection'));
      await tester.pumpAndSettle();

      final selection = container.read(sessionSelectionProvider);
      expect(selection.active, isFalse);
      expect(
        selection.ids,
        isEmpty,
        reason: 'a ticked set must never outlive the checkboxes that made it',
      );
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('Done on the strip leaves too', (tester) async {
      addNative('n0', title: 'One');
      final container = await pump(tester);
      await enterSelection(tester);
      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(container.read(sessionSelectionProvider).active, isFalse);
      expect(container.read(sessionSelectionProvider).ids, isEmpty);
    });

    testWidgets('entering does not preselect the open session', (tester) async {
      // The singly-selected row is what the user is *reading*, not something
      // they chose to act on. Carrying it in would make the first thing a bulk
      // Delete offers to remove the transcript in front of them, and would make
      // their first tick a deselection.
      addNative('n0', title: 'One');
      final container = await pump(tester);
      container.read(selectedSessionIdProvider.notifier).select('n0');
      await tester.pumpAndSettle();

      await enterSelection(tester);

      expect(container.read(sessionSelectionProvider).ids, isEmpty);
      expect(cardFor(tester, 'One').selected, isTrue);
      expect(cardFor(tester, 'One').ticked, isFalse);
    });
  });

  group('across a refresh', () {
    testWidgets('the selection is keyed by id, not by position', (
      tester,
    ) async {
      addNative('n0', title: 'Oldest');
      addNative('n1', title: 'Middle', minutes: 1);
      addNative('n2', title: 'Newest', minutes: 2);
      final container = await pump(tester);
      await enterSelection(tester);

      await tester.tap(find.text('Middle'));
      await tester.pumpAndSettle();
      expect(container.read(sessionSelectionProvider).ids, {'n1'});

      // A newer session arrives and takes the top of the list, so every row
      // below it moves down one. A selection held by index would now be on
      // "Middle"'s neighbour.
      addNative('n3', title: 'Newer still', minutes: 3);
      container
          .read(sessionsRevisionProvider.notifier)
          .changed(const SessionChange.created('n3'));
      await tester.pumpAndSettle();

      expect(find.byType(SessionCard), findsNWidgets(4));
      expect(container.read(sessionSelectionProvider).ids, {'n1'});
      expect(cardFor(tester, 'Middle').ticked, isTrue);
      for (final other in ['Oldest', 'Newest', 'Newer still']) {
        expect(cardFor(tester, other).ticked, isFalse, reason: other);
      }
    });

    testWidgets('a plain poll leaves the selection exactly as it was', (
      tester,
    ) async {
      addNative('n0', title: 'One');
      addNative('n1', title: 'Two', minutes: 1);
      final container = await pump(tester);
      await enterSelection(tester);
      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();

      // The coarse bump the sweep publishes, three times over.
      for (var i = 0; i < 3; i++) {
        container.read(sessionsRevisionProvider.notifier).bump();
        await tester.pumpAndSettle();
      }

      expect(container.read(sessionSelectionProvider).ids, {'n0'});
      expect(container.read(sessionSelectionProvider).active, isTrue);
    });
  });

  group('a row that vanishes', () {
    testWidgets('drops out of the selection and takes nothing with it', (
      tester,
    ) async {
      addNative('n0', title: 'One');
      addNative('n1', title: 'Two', minutes: 1);
      addImported('i0', title: 'Three', minutes: 2);
      final container = await pump(tester);
      await enterSelection(tester);
      for (final title in ['One', 'Two', 'Three']) {
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
      }
      expect(container.read(sessionSelectionProvider).ids, {'n0', 'n1', 'i0'});

      // Deleted somewhere else entirely — another window, a project removal, a
      // sweep. The Explorer hears about it the only way it ever does.
      SessionDao(db).delete('n1');
      ImportedSessionDao(db).delete('i0');
      container
          .read(sessionsRevisionProvider.notifier)
          .changed(const SessionChange.removed('n1'));
      await tester.pumpAndSettle();

      expect(container.read(sessionSelectionProvider).ids, {
        'n0',
      }, reason: 'both gone rows drop; the survivor stays ticked');
      expect(find.text('1 selected'), findsOneWidget);
      expect(cardFor(tester, 'One').ticked, isTrue);
    });

    testWidgets('a row merely filtered out of sight stays selected', (
      tester,
    ) async {
      // The pinned rule: the selection tracks what still *exists*, not what is
      // currently drawn. A search box that silently emptied the selection would
      // be a destructive control, and the confirmation names every row anyway.
      addNative('n0', title: 'One');
      final container = await pump(tester);
      await enterSelection(tester);
      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField).first,
        'nothing matches this',
      );
      await tester.pumpAndSettle();

      expect(find.byType(SessionCard), findsNothing);
      expect(container.read(sessionSelectionProvider).ids, {'n0'});
      expect(find.text('1 selected'), findsOneWidget);
    });
  });

  group('layout', () {
    testWidgets('the selection strip survives the window matrix', (
      tester,
    ) async {
      addNative('n0', title: 'One');
      addImported('i0', title: 'Two', minutes: 1);

      await expectSurvivesWindowMatrix(
        tester,
        build: host,
        warmUp: (tester) async {
          await tester.tap(find.text('Hub'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Select sessions'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('One'));
          await tester.pumpAndSettle();
        },
        because:
            'the Explorer is already tight at 720x560, and the strip adds a '
            'count and two verbs above the tree',
      );
    });
  });
}

ProviderContainer _container(
  AppDatabase db,
  FakeRepositoryDiscoveryService discovery,
) => ProviderContainer(
  overrides: [
    ...fakeTerminalOverrides(database: db),
    clockProvider.overrideWithValue(FixedClock(testTime)),
    idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
    commandRunnerFactoryProvider.overrideWithValue(FakeCommandRunnerFactory()),
    availableSystemTerminalsProvider.overrideWith(
      (ref) async => const <SystemTerminal>[],
    ),
    autoImportRunnerProvider.overrideWithValue(
      (_) async => const ImportSummary(),
    ),
    agentSessionStatusProvider.overrideWith(
      (ref, id) => const Stream<AgentStatusReport>.empty(),
    ),
    repositoryDiscoveryServiceProvider.overrideWithValue(discovery),
  ],
);
