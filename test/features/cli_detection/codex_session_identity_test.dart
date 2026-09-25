import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_cli_store_locator.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// The owner's bug, end to end, on a real `.codex` store.
///
/// > "i started new session with codex, and started conversation. sessions
/// > explorer has the updated session with conv title, but the tabbar is still
/// > showing new session and when trying to open notification from inbox it
/// > show the session as not active weird"
///
/// One session, three disagreements — and one cause. Codex takes no
/// `--session-id`, so the launched row's `external_session_id` was null and
/// nothing ever filled it in. That single missing join is what left the
/// conversation visible only as the read-only imported record (the Explorer's
/// "updated session with conv title"), left the row wearing the launcher's
/// placeholder (the tab strip), and left `hostedLive` unable to see that the
/// conversation had a pane (the inbox's "not active").
void main() {
  late Directory tmp;
  late String storeHome;
  late AppDatabase db;

  const conversation = '01a05c73-912d-7bf3-84cc-a1bb591134aa';
  const threadName = "hey let's work on karmashala app, i";
  const repoPath = r'C:\src\demo\app';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_codex_identity_');
    storeHome = p.join(tmp.path, '.codex');
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation(agentId: AgentIds.codex));
  });
  tearDown(() {
    db.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle on a database a failing test left open.
    }
  });

  /// One rollout, in the shape Codex 0.151 writes it.
  ///
  /// The envelope timestamp is when the line was *flushed* and the payload's is
  /// when the conversation began — 30 seconds apart in the owner's own file, so
  /// which one is read is not a detail.
  void writeRollout({
    String id = conversation,
    String cwd = repoPath,
    Duration startedAfterLaunch = const Duration(seconds: 5),
    String? name = threadName,
  }) {
    final startedAt = testTime.add(startedAfterLaunch);
    final file = File(
      p.join(storeHome, 'sessions', '2026', '09', '01', 'rollout-$id.jsonl'),
    )..createSync(recursive: true);
    file.writeAsStringSync(
      '${jsonEncode({
        'timestamp': startedAt.add(const Duration(seconds: 30)).toIso8601String(),
        'type': 'session_meta',
        'payload': {'id': id, 'session_id': id, 'timestamp': startedAt.toIso8601String(), 'cwd': cwd, 'originator': 'codex-tui'},
      })}\n'
      '${jsonEncode({
        'timestamp': startedAt.toIso8601String(),
        'type': 'response_item',
        'payload': {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'hey lets work on karmashala app'},
          ],
        },
      })}\n',
    );
    if (name == null) return;
    File(p.join(storeHome, 'session_index.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('${jsonEncode({'id': id, 'thread_name': name})}\n');
  }

  ProviderContainer container() => ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      cliStoreLocatorProvider.overrideWithValue(
        FixedLocator([
          CliStore(
            environmentId: 'windows',
            homesByAgentId: {AgentIds.codex: storeHome},
          ),
        ]),
      ),
    ],
  );

  /// The row `SessionLauncher` writes for a Codex session started from a `+`:
  /// a title nobody chose, a pane, and no CLI id, because Codex will not take
  /// one.
  Session launchedRow({String id = 's1', String? paneId = 'pane-1'}) => Session(
    id: id,
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: 'New session',
    useWorktree: false,
    workingDirectory: const EnvironmentPath(
      environmentId: 'windows',
      path: repoPath,
    ),
    status: SessionStatus.running,
    createdAt: testTime,
    paneId: paneId,
  );

  /// The same conversation as the auto-import files it: read-only history.
  void importRecord() {
    ImportedSessionDao(db).insertIfAbsent(
      ImportedSession(
        id: 'i1',
        repositoryId: 'r1',
        cli: AgentIds.codex,
        externalId: conversation,
        environmentId: 'windows',
        title: threadName,
        preview: 'hey lets work on karmashala app',
        filePath: p.join(
          storeHome,
          'sessions',
          '2026',
          '09',
          '01',
          'rollout-$conversation.jsonl',
        ),
        storeHome: storeHome,
        isSubagent: false,
        createdAt: testTime,
      ),
    );
  }

  test('a launched Codex row learns its conversation and its name', () async {
    writeRollout();
    SessionDao(db).insert(launchedRow());
    final ref = container();
    addTearDown(ref.dispose);

    await ref.read(cliStoreSyncRunnerProvider)();

    final row = SessionDao(db).getById('s1')!;
    expect(row.externalSessionId, conversation);
    // The tab strip reads the row at display time, so this *is* the tab strip.
    expect(row.title, threadName);
  });

  test('the tab strip and the tree end up saying the same thing', () async {
    writeRollout();
    final ref = container();
    addTearDown(ref.dispose);
    final controller = ref.read(terminalSessionsControllerProvider.notifier);
    final opened = controller.openAgentTab(
      const AgentPaneLaunch(
        agentId: AgentIds.codex,
        executable: 'codex',
        sessionId: 's1',
        title: 'New session',
      ),
    );
    ref.read(sessionDaoProvider).insert(launchedRow(paneId: opened.paneId));
    expect(controller.titleForTab(opened.tabId), 'New session');

    await ref.read(cliStoreSyncRunnerProvider)();

    expect(controller.titleForTab(opened.tabId), threadName);
  });

  test('the Explorer stops drawing the same session twice', () async {
    // The imported record is what the owner saw wearing the conversation's
    // name. Once the native row holds the conversation id it supersedes that
    // record, and one conversation is one card again.
    writeRollout();
    importRecord();
    SessionDao(db).insert(launchedRow());
    final ref = container();
    addTearDown(ref.dispose);
    expect(ImportedSessionDao(db).getAll(), hasLength(1));

    await ref.read(cliStoreSyncRunnerProvider)();

    expect(ImportedSessionDao(db).getAll(), isEmpty);
  });

  test(
    'the inbox opens a session that has a live pane, and finds it active',
    () async {
      writeRollout();
      importRecord();
      final ref = container();
      addTearDown(ref.dispose);
      // A real pane, so liveness is a fact rather than a fixture.
      final controller = ref.read(terminalSessionsControllerProvider.notifier);
      final opened = controller.openAgentTab(
        const AgentPaneLaunch(
          agentId: AgentIds.codex,
          executable: 'codex',
          sessionId: 's1',
        ),
      );
      ref.read(sessionDaoProvider).insert(launchedRow(paneId: opened.paneId));

      await ref.read(cliStoreSyncRunnerProvider)();

      // What the inbox is offered: one watched session, and it is the row with
      // the pane — not the read-only history the notification used to open.
      // The app's own loader, so the pane's liveness is read the way the app
      // reads it: a row is watched because its pane runs.
      final watched = ref.read(watchedSessionLoaderProvider).load();
      expect(watched, hasLength(1));
      expect(watched.single.imported, isFalse);
      expect(watched.single.openId, 's1');
      expect(watched.single.key.sessionId, conversation);

      // And the question the "not active" message came from.
      expect(
        ref
            .read(sessionLauncherProvider)
            .hostedLive(sessionId: 's1', externalSessionId: conversation),
        isTrue,
      );
    },
  );

  test(
    'a selection sitting on the superseded history follows the row',
    () async {
      // The other half of the inbox symptom. Opening the notification put the
      // read-only transcript on screen, because that was the only record of the
      // conversation at the time; the id landing a slot later hides that record
      // from the tree but would leave the user looking at it, with no sign that
      // the session they are reading is running in a pane behind them.
      writeRollout();
      importRecord();
      SessionDao(db).insert(launchedRow());
      final ref = container();
      addTearDown(ref.dispose);
      ref.read(selectedImportedSessionIdProvider.notifier).select('i1');

      await ref.read(cliStoreSyncRunnerProvider)();

      expect(ref.read(selectedImportedSessionIdProvider), isNull);
      expect(ref.read(selectedSessionIdProvider), 's1');
    },
  );

  test('a selection on some other history is left where it is', () async {
    writeRollout();
    importRecord();
    ImportedSessionDao(db).insertIfAbsent(
      ImportedSession(
        id: 'i2',
        repositoryId: 'r1',
        cli: AgentIds.codex,
        externalId: '019a0c34-2cc6-7002-bc5b-3184f3b7332f',
        environmentId: 'windows',
        preview: 'something else entirely',
        filePath: p.join(storeHome, 'sessions', 'other.jsonl'),
        storeHome: storeHome,
        isSubagent: false,
        createdAt: testTime,
      ),
    );
    SessionDao(db).insert(launchedRow());
    final ref = container();
    addTearDown(ref.dispose);
    ref.read(selectedImportedSessionIdProvider.notifier).select('i2');

    await ref.read(cliStoreSyncRunnerProvider)();

    expect(ref.read(selectedImportedSessionIdProvider), 'i2');
    expect(ref.read(selectedSessionIdProvider), isNull);
  });

  test('a conversation nobody named leaves the row its placeholder', () async {
    // Codex writes `session_index.jsonl` only once a thread has a name. The id
    // still lands — that is what the inbox and a resume need — and the title
    // sync says nothing, which is the honest answer.
    writeRollout(name: null);
    SessionDao(db).insert(launchedRow());
    final ref = container();
    addTearDown(ref.dispose);

    await ref.read(cliStoreSyncRunnerProvider)();

    final row = SessionDao(db).getById('s1')!;
    expect(row.externalSessionId, conversation);
    expect(row.title, 'New session');
  });

  test('a conversation from before the launch is left where it was', () async {
    writeRollout(startedAfterLaunch: const Duration(hours: -1));
    SessionDao(db).insert(launchedRow());
    final ref = container();
    addTearDown(ref.dispose);

    await ref.read(cliStoreSyncRunnerProvider)();

    expect(SessionDao(db).getById('s1')!.externalSessionId, isNull);
  });
}
