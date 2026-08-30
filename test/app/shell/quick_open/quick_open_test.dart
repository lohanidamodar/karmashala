import 'package:chitragupta/src/app/shell/quick_open/quick_open.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/git/application/changes_providers.dart';
import 'package:chitragupta/src/features/github/application/github_providers.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/application/session_ui_providers.dart';
import 'package:chitragupta/src/features/projects/application/projects_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../features/terminal/fake_instance.dart';
import '../../../support/fakes.dart';
import '../../../support/fixtures.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project(name: 'Chitragupta'));
    RepositoryDao(db).insert(repository(name: 'app'));
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db)
      ..insert(session(id: 's1', title: 'Fix login redirect'))
      ..insert(session(id: 's2', title: 'Write the release notes'));
  });
  tearDown(() => db.close());

  Future<ProviderContainer> open(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: fakeTerminalOverrides(database: db),
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => QuickOpen.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    // A repository has to be selected for the file/branch sources to have a
    // subject; the shell selects one as soon as a project is picked.
    container.read(selectedProjectIdProvider.notifier).select('p1');
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  testWidgets('opens grouped, with sessions and commands under headers', (
    tester,
  ) async {
    await open(tester);

    // Sessions lead an empty query: the recent work is what a workspace
    // launcher is usually opened to reach.
    expect(find.text('SESSIONS'), findsOneWidget);
    expect(find.text('Fix login redirect'), findsOneWidget);
    // Every session names where it lives, so two sessions called "Fix" in
    // different repositories are still told apart.
    expect(find.textContaining('Chitragupta · app'), findsWidgets);
    // Projects and repositories are their own group, not sessions.
    expect(find.text('PROJECTS & REPOSITORIES'), findsOneWidget);
  });

  testWidgets('a command is found by name, under its own header', (
    tester,
  ) async {
    await open(tester);

    await type(tester, 'settings');

    expect(find.text('COMMANDS'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
  });

  testWidgets('Enter opens the session the query ranked first', (tester) async {
    final container = await open(tester);

    await type(tester, 'login');
    await press(tester, LogicalKeyboardKey.enter);

    expect(container.read(selectedSessionIdProvider), 's1');
    expect(container.read(selectedRepositoryIdProvider), 'r1');
    // It closed behind itself.
    expect(find.byType(QuickOpen), findsNothing);
  });

  testWidgets('the arrows move the selection before Enter takes it', (
    tester,
  ) async {
    final container = await open(tester);

    // Both sessions match; the first is whichever ranks higher.
    await type(tester, 'the');
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.enter);

    expect(container.read(selectedSessionIdProvider), isNotNull);
  });

  testWidgets('a > query lists commands and nothing else', (tester) async {
    await open(tester);

    await type(tester, '>settings');

    expect(find.text('COMMANDS'), findsOneWidget);
    expect(find.text('SESSIONS'), findsNothing);
    expect(find.text('Open Settings'), findsOneWidget);
  });

  testWidgets('a query that matches nothing says so', (tester) async {
    await open(tester);

    await type(tester, 'zzzzqqqq');

    expect(find.text('Nothing matches.'), findsOneWidget);
  });

  testWidgets('opening it never starts a network or git call', (tester) async {
    final container = await open(tester);
    await type(tester, 'login');

    // The GitHub and git providers run `gh` and `git`; quick open reads them
    // only when something else has already brought them to life.
    expect(container.exists(githubPullRequestsProvider), isFalse);
    expect(container.exists(githubIssuesProvider), isFalse);
    expect(container.exists(repositoryChangesProvider), isFalse);
    expect(container.exists(repoWorktreesProvider), isFalse);
  });
}
