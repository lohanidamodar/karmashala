import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/core/util/id_generator_provider.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:chitragupta/src/features/cli_detection/application/project_import_service.dart';
import 'package:chitragupta/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:chitragupta/src/features/cli_detection/domain/detected_project.dart';
import 'package:chitragupta/src/features/cli_detection/domain/detected_session.dart';
import 'package:chitragupta/src/features/cli_detection/domain/imported_session.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/session_actions.dart';
import 'package:chitragupta/src/features/sessions/application/session_status_providers.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/features/settings/application/settings_controller.dart';
import 'package:chitragupta/src/features/settings/domain/settings.dart';
import 'package:chitragupta/src/features/explorer/presentation/explorer_panel.dart';
import 'package:chitragupta/src/features/repositories/application/repository_discovery_provider.dart';
import 'package:chitragupta/src/features/terminal/application/system_terminal_providers.dart';
import 'package:chitragupta/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// One CLI session, one row in the workspace.
///
/// The owner's report: resuming a session that had been imported left the
/// Explorer showing it twice while the CLI still reported a single session.
/// `imported_sessions` and `sessions` can each hold a record of one
/// conversation, and `sessions.external_session_id` is the tie — resolved once,
/// in `ImportedSessionDao`, rather than filtered in each view.

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

ImportedSession imported({
  String id = 'imp-1',
  String externalId = 'cli-abc',
  String title = 'Earlier work',
  String repositoryId = 'r1',
}) => ImportedSession(
  id: id,
  repositoryId: repositoryId,
  cli: AgentIds.claudeCode,
  externalId: externalId,
  environmentId: 'windows',
  filePath: 'C:\\store\\$externalId.jsonl',
  storeHome: r'C:\store',
  isSubagent: false,
  preview: 'the first thing said',
  title: title,
  updatedAt: testTime,
  createdAt: testTime,
);

Session native({
  String id = 'n1',
  String? externalId = 'cli-abc',
  String title = 'Earlier work',
  SessionStatus status = SessionStatus.running,
  String? paneId,
}) => Session(
  id: id,
  repositoryId: 'r1',
  agentInstallationId: 'a1',
  title: title,
  useWorktree: false,
  status: status,
  createdAt: testTime,
  externalSessionId: externalId,
  paneId: paneId,
);

void main() {
  late AppDatabase db;
  late ImportedSessionDao dao;
  late SessionDao sessions;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    dao = ImportedSessionDao(db);
    sessions = SessionDao(db);
  });
  tearDown(() => db.close());

  group('a conversation with a native row', () {
    test('is listed once, not twice', () {
      dao.insertIfAbsent(imported());
      expect(dao.getAll(), hasLength(1));

      sessions.insert(native());

      expect(dao.getAll(), isEmpty);
      expect(dao.getByRepository('r1'), isEmpty);
      expect(sessions.getAll(), hasLength(1));
    });

    // A *user-initiated* resume still replaces the imported record outright
    // (`SessionActions.resumeImported`); an automatic adoption only supersedes
    // it, because automation that is wrong should not have deleted anything.
    // Both end at one row.
    test('is hidden, not deleted — the record survives for its history', () {
      dao.insertIfAbsent(imported());
      sessions.insert(native());

      expect(dao.getById('imp-1'), isNotNull);
      expect(dao.getByExternal(AgentIds.claudeCode, 'cli-abc'), isNotNull);
      // And it comes back if the live row that superseded it goes away.
      sessions.delete('n1');
      expect(dao.getAll(), hasLength(1));
    });

    test('is not re-imported by a later store scan', () {
      sessions.insert(native());

      expect(dao.insertIfAbsent(imported()), isFalse);
      expect(dao.getAll(), isEmpty);
    });

    test('a native row with no CLI id supersedes nothing', () {
      dao.insertIfAbsent(imported());
      sessions.insert(native(externalId: null));

      expect(dao.getAll(), hasLength(1));
    });

    test('two different conversations stay two rows', () {
      dao
        ..insertIfAbsent(imported(id: 'imp-1', externalId: 'cli-abc'))
        ..insertIfAbsent(imported(id: 'imp-2', externalId: 'cli-def'));
      sessions.insert(native(externalId: 'cli-abc'));

      final rows = dao.getAll();
      expect(rows, hasLength(1));
      expect(rows.single.externalId, 'cli-def');
    });

    test('a pair already in the database resolves with no migration', () {
      // Exactly the shape a user upgrading into this fix has: both rows
      // already written, by a resume that predates the resolution.
      dao.insertIfAbsent(imported());
      db.execute(
        'INSERT INTO sessions '
        '(id, repository_id, agent_installation_id, title, use_worktree, '
        'status, created_at, external_session_id, surface, view) '
        "VALUES ('n1','r1','a1','Earlier work',0,'running','2026-01-02', "
        "'cli-abc','pane','terminal');",
      );

      expect(dao.getAll(), isEmpty);
    });
  });

  group('the whole-store import', () {
    test('does not re-add a conversation that is already live', () {
      sessions.insert(native());
      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator('p-')),
        ],
      );
      addTearDown(container.dispose);

      final summary = container.read(projectImportServiceProvider).importAll([
        DetectedProject(
          canonicalKey: r'c:\src\demo\app',
          displayPath: r'C:\src\demo\app',
          sessions: [
            DetectedSession(
              cli: AgentIds.claudeCode,
              sessionId: 'cli-abc',
              cwd: const EnvironmentPath(
                environmentId: 'windows',
                path: r'C:\src\demo\app',
              ),
              filePath: r'C:\store\cli-abc.jsonl',
              storeHome: r'C:\store',
              modifiedAt: testTime,
            ),
          ],
          subagentSessions: const [],
        ),
      ]);

      expect(summary.sessions, 0);
      expect(dao.getAll(), isEmpty);
    });
  });

  group('what the Explorer draws', () {
    testWidgets('one card, not two, for a resumed conversation', (
      tester,
    ) async {
      dao.insertIfAbsent(imported(title: 'Earlier work'));
      sessions.insert(native(title: 'Earlier work'));
      tester.view.physicalSize = const Size(460, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...fakeTerminalOverrides(database: db),
            clockProvider.overrideWithValue(FixedClock(testTime)),
            idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
            commandRunnerFactoryProvider.overrideWithValue(
              FakeCommandRunnerFactory(),
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
            repositoryDiscoveryServiceProvider.overrideWithValue(
              FakeRepositoryDiscoveryService(),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo'));
      await tester.pumpAndSettle();

      expect(find.text('Earlier work'), findsOneWidget);
    });
  });

  group('resuming an imported session', () {
    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(),
          ),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
          settingsControllerProvider.overrideWith(_StaticSettings.new),
          agentSessionStatusProvider.overrideWith(
            (ref, id) => const Stream<AgentStatusReport>.empty(),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('leaves one row, which keeps the title and gains a pane', () async {
      dao.insertIfAbsent(imported());
      final c = container();

      final id = await c.read(sessionActionsProvider).resumeImported(
        dao.getById('imp-1')!,
      );

      expect(dao.getAll(), isEmpty);
      final rows = sessions.getAll();
      expect(rows, hasLength(1));
      expect(rows.single.id, id);
      expect(rows.single.title, 'Earlier work');
      expect(rows.single.externalSessionId, 'cli-abc');
      expect(rows.single.paneId, isNotNull);
      expect(rows.single.repositoryId, 'r1');
    });

    test('resuming twice still leaves one row', () async {
      dao.insertIfAbsent(imported());
      final c = container();
      final actions = c.read(sessionActionsProvider);

      final stale = dao.getById('imp-1')!;
      final first = await actions.resumeImported(stale);
      // The second click, from a card the tree had not redrawn yet. It reaches
      // the same conversation, and there is still one row for it afterwards.
      final again = await actions.resumeImported(stale);

      expect(again, first);
      expect(sessions.getAll(), hasLength(1));
      expect(dao.getAll(), isEmpty);
    });
  });
}
