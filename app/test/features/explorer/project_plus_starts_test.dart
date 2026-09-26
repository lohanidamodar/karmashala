import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala/src/features/sessions/presentation/new_session_dialog.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **The `+` on a project row starts a session. The menu beside it asks.**
///
/// The owner's words: *"the plus icon on a project in the Explorer should start
/// a new session with defaults, without dialogs. 'More' already has an option
/// to start a session with the dialog."* It did not — the `+` opened the same
/// dialog the menu did, so the row had two doors onto one question and no way
/// to simply start.
///
/// The one thing a one-click start must never do is guess. When the defaults
/// are not enough to start on — here, no agent installed where the session
/// would run — the button opens the dialog instead of starting something
/// nobody asked for.
void main() {
  const plus = 'Start a session here with the default agent';

  late AppDatabase db;

  AppDatabase seed({bool withAgent = true}) {
    final database = AppDatabase.memory();
    ExecutionEnvironmentDao(database).upsert(windowsEnv());
    ProjectDao(database).insert(project(name: 'Alpha', path: r'C:\src\alpha'));
    RepositoryDao(
      database,
    ).insert(repository(name: 'alpha-app', path: r'C:\src\alpha\app'));
    if (withAgent) AgentInstallationDao(database).insert(agentInstallation());
    return database;
  }

  tearDown(() => db.close());

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        // A session card asks git what its checkout has changed, and the
        // picker asks it which rows are worktrees. Neither may spawn one.
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        // Expanding a project scans the CLI stores for sessions started
        // outside the app. That is a real filesystem walk, and the header's
        // spinner runs for as long as it does — which no `pumpAndSettle` can
        // outlast.
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
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
    return container;
  }

  testWidgets('the + starts a session, and opens no dialog', (tester) async {
    db = seed();
    await pump(tester);

    // The + takes the count's place while a pointer is on the row.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(() => gesture.removePointer());
    await gesture.moveTo(tester.getCenter(find.byType(ProjectCard)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(plus));
    await tester.pumpAndSettle();

    expect(find.byType(NewSessionDialog), findsNothing);
    final started = SessionDao(db).getByRepository('r1');
    expect(started, hasLength(1));
    expect(
      started.single.agentInstallationId,
      'a1',
      reason: 'the default agent for the environment it runs in',
    );
    expect(
      find.text('Work'),
      findsNothing,
      reason: 'no other session was already here to be confused with it',
    );
  });

  testWidgets('the menu still asks, and starts nothing on its own', (
    tester,
  ) async {
    db = seed();
    await pump(tester);

    // The overflow is drawn on demand: a pointer on the row reveals it.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(() => gesture.removePointer());
    await gesture.moveTo(tester.getCenter(find.byType(ProjectCard)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Project actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New session…'));
    await tester.pumpAndSettle();

    expect(find.byType(NewSessionDialog), findsOneWidget);
    expect(
      SessionDao(db).getByRepository('r1'),
      isEmpty,
      reason: 'the dialog has not been told to start anything yet',
    );
  });

  testWidgets('with no agent to run, the + opens the dialog instead', (
    tester,
  ) async {
    db = seed(withAgent: false);
    await pump(tester);

    // The + takes the count's place while a pointer is on the row.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(() => gesture.removePointer());
    await gesture.moveTo(tester.getCenter(find.byType(ProjectCard)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(plus));
    await tester.pumpAndSettle();

    expect(
      find.byType(NewSessionDialog),
      findsOneWidget,
      reason:
          'the defaults could not answer "which agent", so the button asks '
          'rather than guessing',
    );
    expect(SessionDao(db).getByRepository('r1'), isEmpty);
    expect(find.textContaining('No agent is installed in'), findsOneWidget);
  });
}
