import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/core/database/row_mapping.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late AgentInstallationDao dao;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    dao = AgentInstallationDao(db);
  });
  tearDown(() => db.close());

  test('insert then read round-trips an installation', () {
    final a = agentInstallation();
    dao.insert(a);
    expect(dao.getById('a1'), a);
  });

  test('the same agent in Windows and WSL are independent installations', () {
    dao.insert(agentInstallation(id: 'win', environmentId: 'windows'));
    dao.insert(
      agentInstallation(
        id: 'wsl',
        environmentId: 'wsl:Ubuntu',
        path: '/home/me/.local/bin/claude',
      ),
    );
    expect(dao.getAll().length, 2);
    expect(dao.getByEnvironment('windows').single.id, 'win');
    expect(dao.getByEnvironment('wsl:Ubuntu').single.id, 'wsl');
  });

  test('duplicate (agent, environment, executable) is rejected', () {
    dao.insert(agentInstallation(id: 'a1'));
    expect(
      () => dao.insert(agentInstallation(id: 'a2')),
      throwsA(isA<SqliteException>()),
    );
  });

  test('a null version is preserved', () {
    dao.insert(agentInstallation(agentId: AgentIds.codex, version: null));
    expect(dao.getById('a1')!.version, isNull);
  });

  test('reads back a row written before the agent-id migration', () {
    db.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, version, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      [
        'legacy',
        'claudeCode',
        'windows',
        r'C:\bin\claude.exe',
        '1.0.0',
        isoFromDate(testTime),
      ],
    );
    expect(dao.getById('legacy')!.agentId, AgentIds.claudeCode);
  });

  test('an agent with no AgentKind member persists and round-trips', () {
    dao.insert(agentInstallation(id: 'rover', agentId: 'roverCli'));
    expect(dao.getById('rover')!.agentId, 'roverCli');
    expect(
      dao
          .getByIdentity('roverCli', 'windows', r'C:\Users\me\.bin\claude.exe')!
          .id,
      'rover',
    );
  });

  /// A session row, which is what makes an installation undeletable: the
  /// schema declares `sessions.agent_installation_id ... ON DELETE RESTRICT`.
  void giveItASession({String sessionId = 's1', String installationId = 'a1'}) {
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    SessionDao(
      db,
    ).insert(session(id: sessionId, agentInstallationId: installationId));
  }

  test('an installation nothing points at is deleted', () {
    dao.insert(agentInstallation());
    expect(dao.deleteIfUnreferenced('a1'), isTrue);
    expect(dao.getById('a1'), isNull);
  });

  test('one that ran a session is kept, and says so rather than raising', () {
    dao.insert(agentInstallation());
    giveItASession();

    // The bug this exists for: this call used to be a bare DELETE, which
    // raised SqliteException(1811) from the middle of a re-detection sweep and
    // left the whole app reporting no agents at all.
    expect(dao.deleteIfUnreferenced('a1'), isFalse);
    expect(dao.getById('a1'), isNotNull);
  });

  test('repointed sessions follow the installation they moved to', () {
    dao.insert(agentInstallation(id: 'shim', path: '/tmp/shim/claude'));
    dao.insert(agentInstallation(id: 'real', path: '/home/me/.local/bin/claude'));
    giveItASession(installationId: 'shim');

    dao.repointSessions(from: 'shim', to: 'real');

    expect(
      db.query('SELECT agent_installation_id FROM sessions;').single.values,
      ['real'],
    );
    // And with nothing pointing at it any more, the old row can now go.
    expect(dao.deleteIfUnreferenced('shim'), isTrue);
  });
}
