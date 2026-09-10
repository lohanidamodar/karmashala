import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// What a session row is allowed to say before the user clicks it.
///
/// The rule these tests exist to hold: a row may state a **fact** (this one was
/// opened in a terminal we do not own) and it may **date** an observation, but
/// it may never assert that something is active. A badge that is confidently
/// wrong once is a badge nobody reads again.
/// A [Tooltip] whose message contains [text] — where the card keeps the long
/// form of what its corner says in two characters.
Finder tooltipSaying(String text) => find.byWidgetPredicate(
  (widget) => widget is Tooltip && (widget.message?.contains(text) ?? false),
);

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
          // Every session card asks git what its checkout has changed. A
          // widget test must never spawn `git`, so the runner is a fake and
          // the cards render the "nothing changed" answer.
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(),
          ),
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
    // …and it is dated, not asserted. The card's corner carries the age as a
    // number and the tooltip carries what the number means, in `describeAge`'s
    // wording so it reads the same here, in Quick Open and on the phone.
    expect(find.text('2h'), findsOneWidget);
    expect(tooltipSaying('Active 2h ago'), findsOneWidget);
  });

  testWidgets('a session with no evidence never claims to have been seen', (
    tester,
  ) async {
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
    // No source could tell us anything. The corner still dates the row — from
    // when the session was *created*, which is a fact we own — but nothing
    // anywhere says "last seen", because we have not seen it.
    expect(find.textContaining('last seen'), findsNothing);
    expect(tooltipSaying('Created'), findsOneWidget);
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
    expect(find.text('1d'), findsOneWidget);
    // The file's own mtime is the strongest evidence anywhere in the app, and
    // the tooltip is where we admit what it cannot tell us.
    expect(tooltipSaying('last wrote to this conversation'), findsOneWidget);
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
    expect(tooltipSaying('last wrote to this conversation'), findsNothing);
  });
}
