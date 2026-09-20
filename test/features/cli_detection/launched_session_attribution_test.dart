import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/launched_session_attribution_service.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// Learning which Codex conversation a session **we launched** is on.
///
/// The owner's report: a Codex session started from the app showed the
/// conversation's real name in the Explorer, "New session" in the tab strip,
/// and reported itself not active when its inbox notification was opened. One
/// cause behind all three — the row had no `external_session_id`, so nothing
/// could join it to the conversation it was running.
///
/// Codex takes no `--session-id`, so `SessionLauncher` records `null` and, in
/// its own words, the row "keep[s] a null id until something discovers it".
/// Nothing did: `SessionAdoptionService` only ever looks at panes the app did
/// *not* launch, and `AntigravitySessionAttributionService` is gated on `agy`'s
/// store. This service is the something.
void main() {
  late AppDatabase db;
  late SessionDao dao;

  const conversation = '01a05c73-912d-7bf3-84cc-a1bb591134aa';
  const other = '019a0c34-2cc6-7002-bc5b-3184f3b7332f';
  const repoPath = r'C:\src\demo\app';

  final launchedAt = testTime;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation(agentId: AgentIds.codex));
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(id: 'a2', agentId: AgentIds.claudeCode));
    dao = SessionDao(db);
    addTearDown(db.close);
  });

  void insert({
    String id = 's1',
    String installation = 'a1',
    String? externalId,
    String? directory = repoPath,
    SessionStatus status = SessionStatus.running,
    Duration launchOffset = Duration.zero,
  }) {
    dao.insert(
      Session(
        id: id,
        repositoryId: 'r1',
        agentInstallationId: installation,
        title: 'New session',
        useWorktree: false,
        workingDirectory: directory == null
            ? null
            : EnvironmentPath(environmentId: 'windows', path: directory),
        status: status,
        createdAt: launchedAt.add(launchOffset),
        externalSessionId: externalId,
        paneId: 'pane-$id',
      ),
    );
  }

  DetectedSession codexSession(
    String id, {
    String cwd = repoPath,
    Duration startOffset = const Duration(seconds: 5),
    bool dated = true,
    String cli = AgentIds.codex,
  }) => DetectedSession(
    cli: cli,
    sessionId: id,
    cwd: EnvironmentPath(environmentId: 'windows', path: cwd),
    filePath: r'C:\store\.codex\sessions\rollout.jsonl',
    storeHome: r'C:\store\.codex',
    title: 'a name Codex chose',
    startedAt: dated ? launchedAt.add(startOffset) : null,
  );

  LaunchedSessionAttributionService service(List<DetectedSession> detected) =>
      LaunchedSessionAttributionService(
        sessionDao: dao,
        installationDao: AgentInstallationDao(db),
        repositoryDao: RepositoryDao(db),
        environmentDao: ExecutionEnvironmentDao(db),
        agents: AgentRegistry.builtIn,
        scanStores: () async => detected,
      );

  test('a launched Codex row learns the conversation it started', () async {
    insert();
    final subject = service([codexSession(conversation)]);

    expect(subject.wantsStoreSweep, isTrue);
    expect(await subject.attribute(), 1);

    expect(dao.getById('s1')!.externalSessionId, conversation);
    // And having learned it, the row stops costing a scan.
    expect(subject.wantsStoreSweep, isFalse);
  });

  test('the row is handed to the caller so the workspace can redraw', () async {
    insert();
    final seen = <String, String>{};
    final subject = LaunchedSessionAttributionService(
      sessionDao: dao,
      installationDao: AgentInstallationDao(db),
      repositoryDao: RepositoryDao(db),
      environmentDao: ExecutionEnvironmentDao(db),
      agents: AgentRegistry.builtIn,
      scanStores: () async => [codexSession(conversation)],
      onAttributed: (session, id) => seen[session.id] = id,
    );

    await subject.attribute();

    expect(seen, {'s1': conversation});
  });

  test('a conversation already running when we launched is not ours', () async {
    // The whole defence against stealing a conversation somebody started in
    // their own terminal, in the same folder, before we ever ran.
    insert();
    final subject = service([
      codexSession(conversation, startOffset: const Duration(minutes: -30)),
    ]);

    expect(await subject.attribute(), 0);
    expect(dao.getById('s1')!.externalSessionId, isNull);
    expect(subject.reasonFor('s1'), isNotNull);
  });

  test(
    'a conversation that started long after the launch is not ours',
    () async {
      insert();
      final subject = service([
        codexSession(conversation, startOffset: const Duration(hours: 2)),
      ]);

      expect(await subject.attribute(), 0);
      expect(dao.getById('s1')!.externalSessionId, isNull);
    },
  );

  test('a conversation in another directory is not ours', () async {
    insert();
    final subject = service([
      codexSession(conversation, cwd: r'C:\src\demo\other'),
    ]);

    expect(await subject.attribute(), 0);
    expect(dao.getById('s1')!.externalSessionId, isNull);
  });

  test(
    'a conversation another row already holds is never taken twice',
    () async {
      insert(id: 's0', externalId: conversation);
      insert(id: 's1');
      final subject = service([codexSession(conversation)]);

      expect(await subject.attribute(), 0);
      expect(dao.getById('s1')!.externalSessionId, isNull);
    },
  );

  test(
    'two conversations in the window is a refusal, not a coin toss',
    () async {
      insert();
      final subject = service([
        codexSession(conversation),
        codexSession(other, startOffset: const Duration(seconds: 20)),
      ]);

      expect(await subject.attribute(), 0);
      expect(dao.getById('s1')!.externalSessionId, isNull);
      expect(subject.reasonFor('s1'), contains('2'));
    },
  );

  test('two sessions waiting in one directory refuse together', () async {
    // The store records a *directory* and a time, not a process. Two rows
    // launched into the same folder within the window cannot be told apart, and
    // guessing loses one user's conversation to the other's session.
    insert(id: 's1');
    insert(id: 's2', launchOffset: const Duration(seconds: 2));
    final subject = service([codexSession(conversation)]);

    expect(await subject.attribute(), 0);
    expect(dao.getById('s1')!.externalSessionId, isNull);
    expect(dao.getById('s2')!.externalSessionId, isNull);
    expect(subject.reasonFor('s1'), isNotNull);
    expect(subject.reasonFor('s2'), isNotNull);
  });

  test('an agent that takes --session-id is never a candidate', () async {
    // Claude Code was told its id at launch. A row of its with none is a fork
    // or a failure, and inferring one from a directory would be inventing it.
    insert(installation: 'a2');
    final subject = service([
      codexSession(conversation, cli: AgentIds.claudeCode),
    ]);

    expect(subject.wantsStoreSweep, isFalse);
    expect(await subject.attribute(), 0);
    expect(subject.scans, 0);
  });

  test(
    'a store that cannot say when a conversation began is not matched',
    () async {
      // Antigravity's store yields identity without a start time, and this rule
      // is nothing without one. Its own attributor owns those rows.
      insert();
      final subject = service([codexSession(conversation, dated: false)]);

      expect(await subject.attribute(), 0);
      expect(dao.getById('s1')!.externalSessionId, isNull);
    },
  );

  test('a stopped session buys no scan', () async {
    insert(status: SessionStatus.completed);
    final subject = service([codexSession(conversation)]);

    expect(subject.wantsStoreSweep, isFalse);
    expect(await subject.attribute(), 0);
    expect(subject.scans, 0);
  });

  test('a row that already has an id buys no scan', () async {
    insert(externalId: conversation);
    final subject = service([codexSession(other)]);

    expect(subject.wantsStoreSweep, isFalse);
    expect(await subject.attribute(), 0);
    expect(subject.scans, 0);
  });

  test('a store we cannot read changes nothing', () async {
    insert();
    final subject = LaunchedSessionAttributionService(
      sessionDao: dao,
      installationDao: AgentInstallationDao(db),
      repositoryDao: RepositoryDao(db),
      environmentDao: ExecutionEnvironmentDao(db),
      agents: AgentRegistry.builtIn,
      scanStores: () async => throw const FileSystemException$('unreadable'),
    );

    expect(await subject.attribute(), 0);
    expect(dao.getById('s1')!.externalSessionId, isNull);
  });

  test(
    'a row with no directory of its own falls back to its repository',
    () async {
      // Every row written before schema v22 has a null working directory, and the
      // repository root is where it would have run.
      insert(directory: null);
      final subject = service([codexSession(conversation)]);

      expect(await subject.attribute(), 1);
      expect(dao.getById('s1')!.externalSessionId, conversation);
    },
  );
}

/// A failure a store scan can throw, without depending on `dart:io` here.
class FileSystemException$ implements Exception {
  const FileSystemException$(this.message);
  final String message;
}
