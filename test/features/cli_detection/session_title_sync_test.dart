import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/session_title_sync_service.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// The rename the owner reported, and the hole it came out of.
///
/// the design note: the owner ran `/rename test me
/// now` **inside `agy`**, the CLI recorded it correctly, and the sidebar went on
/// saying "New session". Karmashala's own rename works — it was never asked.
/// Nothing in the app read a CLI's title *back* into an already-launched native
/// session row, for any agent: app-launched rows are titled at creation and only
/// `SessionActions.renameNative` ever changed them, and `SessionAdoptionService`
/// carries a title only for the session it adopts, only at the moment it adopts
/// it.
///
/// So these tests are deliberately not about Antigravity. They are about the
/// missing sync, and Antigravity is one of the agents that exercises it.
void main() {
  late AppDatabase db;
  late SessionDao dao;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(
      agentInstallation(agentId: AgentIds.antigravity),
    );
    dao = SessionDao(db);
  });
  tearDown(() => db.close());

  Session row({
    String id = 's1',
    String title = 'New session',
    String? externalId = 'c1',
    SessionStatus status = SessionStatus.running,
    bool titleByUser = false,
  }) => Session(
    id: id,
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: title,
    useWorktree: false,
    status: status,
    createdAt: testTime,
    externalSessionId: externalId,
    titleByUser: titleByUser,
  );

  DetectedSession found({
    String cli = AgentIds.antigravity,
    String id = 'c1',
    String? title,
    String preview = '',
  }) => DetectedSession(
    cli: cli,
    sessionId: id,
    cwd: const EnvironmentPath(
      environmentId: 'wsl:Ubuntu',
      path: '/home/me/proj',
    ),
    filePath: '/store/conversations/$id.db',
    storeHome: '/store',
    title: title,
    preview: preview,
  );

  SessionTitleSyncService service(
    List<DetectedSession> Function() detected, {
    void Function(String, String)? onRenamed,
  }) => SessionTitleSyncService(
    sessionDao: dao,
    agents: AgentRegistry.builtIn,
    scanStores: () async => detected(),
    onRenamed: onRenamed,
  );

  group('a name the user typed into the CLI reaches the sidebar', () {
    test('the reported case: /rename in agy, "New session" in the app', () async {
      dao.insert(row());
      final renamed = <String, String>{};
      final sync = service(
        () => [found(title: 'test me now')],
        onRenamed: (id, title) => renamed[id] = title,
      );

      expect(await sync.sync(), 1);
      expect(dao.getById('s1')!.title, 'test me now');
      expect(renamed, {'s1': 'test me now'});
    });

    test('it is not an Antigravity rule — Claude Code syncs the same way', () async {
      dao.insert(row());
      final sync = service(
        () => [found(cli: AgentIds.claudeCode, title: 'Fix the crash')],
      );

      expect(await sync.sync(), 1);
      expect(dao.getById('s1')!.title, 'Fix the crash');
    });

    test('the placeholder adoption writes is a placeholder too', () async {
      // `SessionAdoptionService._titleFor` falls back to the agent's display
      // name when the store had nothing to offer at the moment of adoption.
      dao.insert(row(title: 'Antigravity'));
      final sync = service(() => [found(title: 'test me now')]);

      expect(await sync.sync(), 1);
      expect(dao.getById('s1')!.title, 'test me now');
    });

    test('so is a row with no title at all', () async {
      dao.insert(row(title: ''));
      final sync = service(() => [found(title: 'test me now')]);

      expect(await sync.sync(), 1);
      expect(dao.getById('s1')!.title, 'test me now');
    });
  });

  group('what it refuses to overwrite', () {
    test('a title the user typed in the app', () async {
      // `titleByUser` is what `SessionActions.renameNative` records, and it is
      // what stops file-based CLI sync. It is on the row rather than in memory
      // precisely so it survives a restart — see the test below.
      dao.insert(row(title: 'Ledger rewrite', titleByUser: true));
      final sync = service(() => [found(title: 'test me now')]);

      expect(await sync.sync(), 0);
      expect(dao.getById('s1')!.title, 'Ledger rewrite');
      // And it costs nothing: with no row waiting for a name there is no
      // reason to read the disk at all.
      expect(sync.scans, 0);
      expect(sync.wantsStoreSweep, isFalse);
    });

    test('a title the user typed here survives a Codex rename', () async {
      // Codex is not an exception to the `byUser` rule. A name typed into the
      // app the user is looking at is the answer to that conflict, and the row
      // stops waiting permanently — for Codex exactly as for a file-based CLI.
      dao.insert(row(title: 'Old app title', titleByUser: true));
      final sync = service(
        () => [found(cli: AgentIds.codex, title: 'Renamed in Codex')],
      );

      expect(await sync.sync(), 0);
      final updated = dao.getById('s1')!;
      expect(updated.title, 'Old app title');
      expect(updated.titleByUser, isTrue);
    });

    test('a preview, which is a summary and not a name', () async {
      // `DetectedSession.displayTitle` falls back to the first user message.
      // That is a fine label for a card and a lie in a rename: the user did not
      // choose it, and writing it would settle the row against the real name
      // arriving later.
      dao.insert(row());
      final sync = service(() => [found(preview: 'wHAT ?')]);

      expect(await sync.sync(), 0);
      expect(dao.getById('s1')!.title, 'New session');
    });

    test('a row whose conversation the stores do not hold', () async {
      dao.insert(row());
      final sync = service(() => [found(id: 'somebody-else')]);

      expect(await sync.sync(), 0);
      expect(dao.getById('s1')!.title, 'New session');
    });

    test('a row with no CLI id, which nothing can be matched to', () async {
      dao.insert(row(externalId: null));
      final sync = service(() => [found(title: 'test me now')]);

      expect(sync.wantsStoreSweep, isFalse);
      expect(await sync.sync(), 0);
      expect(dao.getById('s1')!.title, 'New session');
    });

    test('a store that threw is not a rename', () async {
      dao.insert(row());
      final sync = SessionTitleSyncService(
        sessionDao: dao,
        agents: AgentRegistry.builtIn,
        scanStores: () async => throw const FormatException('half-written'),
      );

      expect(await sync.sync(), 0);
      expect(dao.getById('s1')!.title, 'New session');
    });
  });

  group('after the first sync', () {
    test('a second CLI rename still lands while the session runs', () async {
      dao.insert(row());
      var title = 'test me now';
      final sync = service(() => [found(title: title)]);

      expect(await sync.sync(), 1);
      title = 'final answer';
      expect(await sync.sync(), 1);
      expect(dao.getById('s1')!.title, 'final answer');
    });

    test('but an in-app rename settles the row for good', () async {
      dao.insert(row());
      var title = 'test me now';
      final sync = service(() => [found(title: title)]);

      expect(await sync.sync(), 1);
      // What `SessionActions.renameNative` does — including recording that the
      // name is the user's, which is what settles the row rather than the
      // in-memory note the service used to keep.
      dao.updateTitle('s1', 'Ledger rewrite', byUser: true);
      title = 'final answer';

      expect(sync.wantsStoreSweep, isFalse);
      expect(await sync.sync(), 0);
      expect(dao.getById('s1')!.title, 'Ledger rewrite');
    });

    test('and a session that has stopped is no longer watched', () async {
      // A row still carrying a CLI title would otherwise buy a store scan on
      // every slow slot for the rest of the app's run. A stopped session has no
      // CLI to be renamed in; one resumed goes back to running and is watched
      // again.
      dao.insert(row());
      var title = 'test me now';
      final sync = service(() => [found(title: title)]);

      expect(await sync.sync(), 1);
      dao.updateStatus('s1', SessionStatus.completed);
      title = 'final answer';

      expect(sync.wantsStoreSweep, isFalse);
      expect(await sync.sync(), 0);
      expect(dao.getById('s1')!.title, 'test me now');
    });
  });

  test('an archived row is left alone', () async {
    dao.insert(row());
    dao.markArchived('s1', testTime);
    final sync = service(() => [found(title: 'test me now')]);

    expect(sync.wantsStoreSweep, isFalse);
    expect(await sync.sync(), 0);
  });

  group('and a rename in the CLI still lands after the app restarts', () {
    test('the reported case: a second /rename, on a new run of the app',
        () async {
      // The bug: which titles the app had written was remembered **in memory**,
      // so on the next start every row's title looked like the user's and no
      // further `/rename` was ever copied in. The owner renamed in the CLI, the
      // store recorded it, and the sidebar went on showing the old name.
      //
      // A fresh service with a row already carrying a CLI name is exactly what
      // a restart looks like: nothing in memory, everything on the row.
      dao.insert(row(title: 'chitragupta'));
      final sync = service(() => [found(title: 'karmashala')]);

      expect(sync.wantsStoreSweep, isTrue, reason: 'the row is still the CLIs');
      expect(await sync.sync(), 1);
      expect(dao.getById('s1')!.title, 'karmashala');
    });

    test('but not once the user has renamed it in the app', () async {
      dao.insert(row(title: 'chitragupta', titleByUser: true));
      final sync = service(() => [found(title: 'karmashala')]);

      expect(await sync.sync(), 0);
      expect(dao.getById('s1')!.title, 'chitragupta');
      expect(sync.scans, 0, reason: 'and it does not even read the disk');
    });

    test('and a stopped session is left alone, restart or not', () async {
      // No CLI to be renamed in, and leaving it waiting would buy a store scan
      // on every slow slot for the rest of the run.
      dao.insert(row(title: 'chitragupta', status: SessionStatus.completed));
      final sync = service(() => [found(title: 'karmashala')]);

      expect(sync.wantsStoreSweep, isFalse);
      expect(await sync.sync(), 0);
    });
  });
}
