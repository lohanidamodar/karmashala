import 'dart:io';

import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';

/// The owner's bug, the app's half: what this app does once the server has
/// learned which conversation a launched Codex row is on (slice 2b — the
/// store reading and the writes are the server's, in its `test/sessions/`).
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
  late FakeDataServer server;
  late DataClient client;
  late Directory tmp;
  late String storeHome;
  late TestMachine db;

  const conversation = '01a05c73-912d-7bf3-84cc-a1bb591134aa';
  const threadName = "hey let's work on karmashala app, i";
  const repoPath = r'C:\src\demo\app';

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_codex_identity_');
    storeHome = p.join(tmp.path, '.codex');
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    client = await server.connect();
    server.installationRows.insert(agentInstallation(agentId: AgentIds.codex));
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle on a database a failing test left open.
    }
  });

  ProviderContainer container() => ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(machine: db),
      dataClientProvider.overrideWithValue(client),
      clockProvider.overrideWithValue(FixedClock(testTime)),
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

  /// What the server's session sync writes once it has read the store
  /// (`LaunchedAttribution`, then `TitleSync`, tested in the server's
  /// `test/sessions/`): the conversation, then its name — told to this app
  /// as the row.
  Future<void> serverLearnsTheConversation(ProviderContainer ref) async {
    await ref.read(dataClientProvider).settled();
    db.server.sessionRows
      ..updateExternalSessionId('s1', conversation)
      ..updateTitle('s1', threadName);
    await pumpEventQueue();
    await ref.read(dataClientProvider).settled();
  }

  /// The same conversation as the auto-import files it: read-only history.
  void importRecord() {
    db.server.importedRows.insertIfAbsent(
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

  test('the tab strip and the tree end up saying the same thing', () async {
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
    ref.read(sessionsDataProvider).insert(launchedRow(paneId: opened.paneId));
    expect(controller.titleForTab(opened.tabId), 'New session');

    await serverLearnsTheConversation(ref);

    expect(controller.titleForTab(opened.tabId), threadName);
  });

  test('the Explorer stops drawing the same session twice', () async {
    // The imported record is what the owner saw wearing the conversation's
    // name. Once the native row holds the conversation id it supersedes that
    // record, and one conversation is one card again.
    importRecord();
    db.server.sessionRows.insert(launchedRow());
    final ref = container();
    addTearDown(ref.dispose);
    expect(db.server.importedRows.getAll(), hasLength(1));

    await serverLearnsTheConversation(ref);

    expect(db.server.importedRows.getAll(), isEmpty);
  });

  test(
    'the inbox opens a session that has a live pane, and finds it active',
    () async {
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
      ref.read(sessionsDataProvider).insert(launchedRow(paneId: opened.paneId));

      await serverLearnsTheConversation(ref);

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
      importRecord();
      db.server.sessionRows.insert(launchedRow());
      final ref = container();
      addTearDown(ref.dispose);
      ref.read(selectedImportedSessionIdProvider.notifier).select('i1');
      // The app's sessions copy is live, as it always is in the app: it is
      // what hears the server's word on the row.
      ref.read(sessionsDataProvider);

      await serverLearnsTheConversation(ref);

      expect(ref.read(selectedImportedSessionIdProvider), isNull);
      expect(ref.read(selectedSessionIdProvider), 's1');
    },
  );

  test('a selection on some other history is left where it is', () async {
    importRecord();
    db.server.importedRows.insertIfAbsent(
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
    db.server.sessionRows.insert(launchedRow());
    final ref = container();
    addTearDown(ref.dispose);
    ref.read(selectedImportedSessionIdProvider.notifier).select('i2');

    await serverLearnsTheConversation(ref);

    expect(ref.read(selectedImportedSessionIdProvider), 'i2');
    expect(ref.read(selectedSessionIdProvider), isNull);
  });
}
