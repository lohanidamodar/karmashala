import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:chitragupta/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:chitragupta/src/features/cli_detection/application/project_import_service.dart';
import 'package:chitragupta/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:chitragupta/src/features/cli_detection/domain/imported_session.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/explorer/presentation/explorer_panel.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/session_status_providers.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session.dart';
import 'package:chitragupta/src/features/sessions/domain/session_launch.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:chitragupta/src/features/terminal/application/system_terminal_providers.dart';
import 'package:chitragupta/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// What a session row is allowed to say before the user clicks it.
///
/// The rule these tests exist to hold: a row may state a **fact** (this one was
/// opened in a terminal we do not own) and it may **date** an observation, but
/// it may never assert that something is active. A badge that is confidently
/// wrong once is a badge nobody reads again.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
  });
  tearDown(() => db.close());

  AgentStatusReport reportAged(Duration age) => AgentStatusReport(
    agentId: AgentIds.claudeCode,
    sessionId: 'ext-1',
    status: AgentActivityStatus.idle,
    source: AgentStatusSource.stateFile,
    observedAt: testTime,
    sourceModifiedAt: testTime.subtract(age),
  );

  Future<void> pump(WidgetTester tester, {AgentStatusReport? report}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          // Every session row offers "Open in <terminal>", and detecting them
          // shells out to `where.exe` — a real process, which a widget test's
          // fake clock outruns.
          availableSystemTerminalsProvider.overrideWith(
            (ref) async => const <SystemTerminal>[],
          ),
          // Expanding a project re-scans the CLI stores, whose spinner would
          // never stop turning in a test's fake time.
          autoImportRunnerProvider.overrideWithValue(
            (_) async => const ImportSummary(),
          ),
          // A fixed observation instead of the polling stream: the row's job is
          // to render what a report says, and a real poll would leave a pending
          // timer behind.
          agentSessionStatusProvider.overrideWith(
            (ref, id) => report == null
                ? const Stream<AgentStatusReport>.empty()
                : Stream.value(report),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
      ),
    );
    await tester.pumpAndSettle();
    // The project's single repository puts its sessions one tap away.
    await tester.tap(find.text('Demo'));
    await tester.pumpAndSettle();
  }

  testWidgets('a session opened in someone else\'s terminal says so', (
    tester,
  ) async {
    SessionDao(db).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Handed off',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        surface: SessionSurface.external,
      ),
    );

    await pump(tester, report: reportAged(const Duration(hours: 2)));

    // The fact comes from the persisted surface, so it survives a restart and
    // costs nothing to know.
    expect(
      find.textContaining('opened in an external terminal'),
      findsOneWidget,
    );
    // …and it is dated, not asserted. "running" is the row's own lifecycle;
    // nothing here claims the process is alive.
    expect(find.textContaining('last seen 2h ago'), findsOneWidget);
  });

  testWidgets('a session with no evidence is given no age', (tester) async {
    SessionDao(db).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Nothing known',
        useWorktree: false,
        status: SessionStatus.completed,
        createdAt: testTime,
        surface: SessionSurface.external,
      ),
    );

    await pump(tester);

    expect(
      find.textContaining('opened in an external terminal'),
      findsOneWidget,
    );
    // No source could tell us anything, so there is no age to show — and a "0m"
    // would have been a lie.
    expect(find.textContaining('last seen'), findsNothing);
  });

  testWidgets('an imported row is dated from the agent\'s own file', (
    tester,
  ) async {
    ImportedSessionDao(db).insertIfAbsent(
      ImportedSession(
        id: 'i1',
        repositoryId: 'r1',
        cli: AgentIds.claudeCode,
        externalId: 'ext-9',
        environmentId: 'windows',
        filePath: r'C:\store\ext-9.jsonl',
        storeHome: r'C:\store',
        isSubagent: false,
        preview: 'earlier work',
        title: 'Yesterday',
        updatedAt: testTime.subtract(const Duration(days: 1)),
        createdAt: testTime,
      ),
    );

    await pump(tester);

    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.textContaining('last seen 1d ago'), findsOneWidget);
  });

  testWidgets('an imported row with no timestamp shows no age', (tester) async {
    ImportedSessionDao(db).insertIfAbsent(
      ImportedSession(
        id: 'i1',
        repositoryId: 'r1',
        cli: AgentIds.claudeCode,
        externalId: 'ext-9',
        environmentId: 'windows',
        filePath: r'C:\store\ext-9.jsonl',
        storeHome: r'C:\store',
        isSubagent: false,
        preview: 'earlier work',
        title: 'Undated',
        createdAt: testTime,
      ),
    );

    await pump(tester);

    expect(find.text('Undated'), findsOneWidget);
    expect(find.textContaining('last seen'), findsNothing);
  });
}
