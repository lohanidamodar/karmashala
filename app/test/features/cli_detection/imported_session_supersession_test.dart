import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';
import 'package:karmashala/src/features/sessions/data/sessions_data.dart';

/// One CLI session, one row in the workspace.
///
/// The owner's report: resuming a session that had been imported left the
/// Explorer showing it twice while the CLI still reported a single session.
/// `imported_sessions` and `sessions` can each hold a record of one
/// conversation, and `sessions.external_session_id` is the tie — resolved once,
/// by the shared rule (`visibleImported`) the server's store and this app's
/// copy (`ImportedSessionsData`) both follow, rather than filtered in each
/// view. The rule against the store itself is
/// `packages/karmashala_session_engine/test/session_reads_test.dart`.

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
  late FakeDataServer server;
  late DataClient client;
  late TestMachine db;
  late ImportedSessionsData dao;
  late SessionsData sessions;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    client = await server.connect();
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    sessions = SessionsData(client);
    dao = ImportedSessionsData(client, sessions);
  });

  group('a conversation with a native row', () {
    test('is listed once, not twice', () {
      dao.insertIfAbsent(imported());
      expect(dao.getAll(), hasLength(1));

      server.sessionRows.insert(native());

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
      server.sessionRows.insert(native());

      expect(dao.getById('imp-1'), isNotNull);
      expect(dao.getByExternal(AgentIds.claudeCode, 'cli-abc'), isNotNull);
      // And it comes back if the live row that superseded it goes away.
      server.sessionRows.delete('n1');
      expect(dao.getAll(), hasLength(1));
    });

    test('is not re-imported by a later store scan', () {
      server.sessionRows.insert(native());

      expect(dao.insertIfAbsent(imported()), isFalse);
      expect(dao.getAll(), isEmpty);
    });

    test('a native row with no CLI id supersedes nothing', () {
      dao.insertIfAbsent(imported());
      server.sessionRows.insert(native(externalId: null));

      expect(dao.getAll(), hasLength(1));
    });

    test('two different conversations stay two rows', () {
      dao
        ..insertIfAbsent(imported(id: 'imp-1', externalId: 'cli-abc'))
        ..insertIfAbsent(imported(id: 'imp-2', externalId: 'cli-def'));
      server.sessionRows.insert(native(externalId: 'cli-abc'));

      final rows = dao.getAll();
      expect(rows, hasLength(1));
      expect(rows.single.externalId, 'cli-def');
    });

    test('and is not counted twice under the project header either', () {
      // `countByRepositories` is the header's read, and it has to apply the
      // same rule the list does — a header that counted the hidden record
      // would disagree with the rows drawn under it, which is worse than a
      // slow header.
      dao
        ..insertIfAbsent(imported(id: 'imp-1', externalId: 'cli-abc'))
        ..insertIfAbsent(imported(id: 'imp-2', externalId: 'cli-def'));
      expect(dao.countByRepositories(['r1']), 2);

      server.sessionRows.insert(native(externalId: 'cli-abc'));

      expect(dao.countByRepositories(['r1']), dao.getByRepository('r1').length);
      expect(dao.countByRepositories(['r1']), 1);
      expect(dao.countByRepositories(['rX']), 0);
      expect(
        dao.countByRepositories(const []),
        0,
        reason: 'a project with no checkouts counts nothing, not everything',
      );
    });

    test('and is placed once, by the row that took it over', () {
      // `repositoryIdsById` is the Explorer's placement map, narrowed to two
      // columns. It has to apply the same rule the list does, or a superseded
      // conversation would be filed under a project while nothing drew it.
      dao
        ..insertIfAbsent(imported(id: 'imp-1', externalId: 'cli-abc'))
        ..insertIfAbsent(imported(id: 'imp-2', externalId: 'cli-def'));
      expect(dao.repositoryIdsById(), {'imp-1': 'r1', 'imp-2': 'r1'});

      server.sessionRows.insert(native(externalId: 'cli-abc'));

      expect(dao.repositoryIdsById(), {'imp-2': 'r1'});
      expect(dao.repositoryIdsById(), {
        for (final row in dao.getAll()) row.id: row.repositoryId,
      });
    });
  });

  group('what the Explorer draws', () {
    testWidgets('one card, not two, for a resumed conversation', (
      tester,
    ) async {
      dao.insertIfAbsent(imported(title: 'Earlier work'));
      server.sessionRows.insert(native(title: 'Earlier work'));
      tester.view.physicalSize = const Size(460, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...fakeTerminalOverrides(machine: db),
            dataClientProvider.overrideWithValue(client),
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
          ...fakeTerminalOverrides(machine: db),
          dataClientProvider.overrideWithValue(client),
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

      final id = await c
          .read(sessionActionsProvider)
          .resumeImported(dao.getById('imp-1')!);

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
