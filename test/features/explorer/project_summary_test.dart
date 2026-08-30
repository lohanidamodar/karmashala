import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:chitragupta/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:chitragupta/src/features/cli_detection/application/project_import_service.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/explorer/presentation/explorer_panel.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/session_status_providers.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:chitragupta/src/features/terminal/application/system_terminal_providers.dart';
import 'package:chitragupta/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The project header's aggregate, and the card's diff stat under it.
///
/// The rule worth pinning is the *cost* one: however many sessions a repository
/// has, its working tree is asked about **once**. A tree that ran `git status`
/// per row would be unusable on a project with thirty sessions, and nothing in
/// a widget test would notice — the answers would all be right.
void main() {
  late AppDatabase db;
  late FakeCommandRunner git;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    git = FakeCommandRunner(
      responder: (request) {
        final args = request.arguments;
        if (args.contains('status')) {
          return const CommandResult(
            exitCode: 0,
            stdout: ' M lib/a.dart\n?? lib/b.dart\n M lib/c.dart\n',
            stderr: '',
          );
        }
        if (args.contains('--abbrev-ref')) {
          return const CommandResult(
            exitCode: 0,
            stdout: 'feature/cards\n',
            stderr: '',
          );
        }
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      },
    );
  });
  tearDown(() => db.close());

  void addSession(String id, String title) => SessionDao(db).insert(
    Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: title,
      useWorktree: false,
      status: SessionStatus.running,
      createdAt: testTime,
    ),
  );

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(360, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: git),
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
        child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the project header carries sessions and changed files', (
    tester,
  ) async {
    addSession('s1', 'First');
    addSession('s2', 'Second');
    await pump(tester);

    // Collapsed: the header still summarises what is inside, which is the
    // point of putting it there rather than on the rows.
    expect(find.text('2 sessions · 3 changed'), findsOneWidget);
  });

  testWidgets('one session reads in the singular', (tester) async {
    addSession('s1', 'Only');
    await pump(tester);
    expect(find.text('1 session · 3 changed'), findsOneWidget);
  });

  testWidgets('every card in a repository shares one git status', (
    tester,
  ) async {
    for (var i = 0; i < 6; i++) {
      addSession('s$i', 'Session $i');
    }
    await pump(tester);
    await tester.tap(find.text('Demo'));
    await tester.pumpAndSettle();

    // Six cards are showing…
    expect(find.text('Session 0'), findsOneWidget);
    expect(find.text('Session 5'), findsOneWidget);
    // …and they all describe the same checkout, so it was asked once.
    final statuses = git.requests
        .where((r) => r.arguments.contains('status'))
        .length;
    expect(statuses, 1, reason: 'one working tree, one `git status`');
  });

  testWidgets('the card shows the checkout branch and its change count', (
    tester,
  ) async {
    addSession('s1', 'Wired');
    await pump(tester);
    await tester.tap(find.text('Demo'));
    await tester.pumpAndSettle();

    expect(find.textContaining('feature/cards'), findsOneWidget);
    expect(find.text('3 changed'), findsOneWidget);
  });

  testWidgets('a repository git cannot answer for simply says nothing', (
    tester,
  ) async {
    git.responder = (_) => const CommandResult(
      exitCode: 128,
      stdout: '',
      stderr: 'not a git repo',
    );
    addSession('s1', 'Unversioned');
    await pump(tester);
    await tester.tap(find.text('Demo'));
    await tester.pumpAndSettle();

    // No error banner, no zero: a tree is not the place to report that git is
    // unhappy about a folder.
    expect(find.text('Unversioned'), findsOneWidget);
    expect(find.textContaining('changed'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pane header fits its own minimum width', (tester) async {
    // The Explorer clamps to 200px and its header carries three buttons: with
    // a Spacer between title and actions the row overflowed by 71px, which is
    // a yellow-striped bar in the real app the moment anyone drags the pane in.
    await pump(tester, size: const Size(200, 700));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the card survives the narrow breakpoint', (tester) async {
    addSession('s1', 'A title long enough to need the whole card width');
    await pump(tester, size: const Size(200, 700));
    await tester.tap(find.text('Demo'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.text('A title long enough to need the whole card width'),
      findsOneWidget,
    );
    // At the Explorer's own minimum width the header's buttons already fill the
    // row, so the aggregate is dropped rather than squeezed into an ellipsis.
    expect(find.textContaining('1 session'), findsNothing);
  });
}
