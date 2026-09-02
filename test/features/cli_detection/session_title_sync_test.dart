import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/cli_detection/application/session_title_sync_service.dart';
import 'package:karmashala/src/features/cli_detection/domain/detected_session.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
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
  }) => Session(
    id: id,
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: title,
    useWorktree: false,
    status: status,
    createdAt: testTime,
    externalSessionId: externalId,
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
      dao.insert(row(title: 'Ledger rewrite'));
      final sync = service(() => [found(title: 'test me now')]);

      expect(await sync.sync(), 0);
      expect(dao.getById('s1')!.title, 'Ledger rewrite');
      // And it costs nothing: with no row waiting for a name there is no
      // reason to read the disk at all.
      expect(sync.scans, 0);
      expect(sync.wantsStoreSweep, isFalse);
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
      // What `SessionActions.renameNative` does.
      dao.updateTitle('s1', 'Ledger rewrite');
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
}
