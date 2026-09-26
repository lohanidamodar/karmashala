import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';

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

  test('a data-only agent persists and round-trips', () {
    dao.insert(agentInstallation(id: 'rover', agentId: 'roverCli'));
    expect(dao.getById('rover')!.agentId, 'roverCli');
    expect(
      dao
          .getByIdentity('roverCli', 'windows', r'C:\Users\me\.bin\claude.exe')!
          .id,
      'rover',
    );
  });

  /// A session row at the server, mirrored into the store beside it — what
  /// makes an installation undeletable there: the schema declares
  /// `sessions.agent_installation_id ... ON DELETE RESTRICT`, the backstop
  /// behind the controller asking the sessions first.
  void giveItASession({String sessionId = 's1', String installationId = 'a1'}) {
    (FakeDataServer()..mirrorInto(db))
      ..projectRows.insert(project())
      ..repositoryRows.insert(repository())
      ..sessionRows.insert(
        session(id: sessionId, agentInstallationId: installationId),
      );
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

  group('moving an installation to a new path', () {
    test('keeps the row and its id, so nothing pinned to it is unpicked', () {
      dao.insert(agentInstallation(path: r'C:\stale\codex.exe'));
      giveItASession();

      expect(dao.updatePath('a1', r'C:\real\codex.exe', byUser: false), isTrue);

      final moved = dao.getById('a1')!;
      expect(moved.executable.path, r'C:\real\codex.exe');
      expect(moved.id, 'a1');
      // The session still names the same installation, because it is the same
      // installation. A delete-and-reinsert would have stranded it.
      expect(
        db.query('SELECT agent_installation_id FROM sessions;').single.values,
        ['a1'],
      );
    });

    test('records who chose the path', () {
      dao.insert(agentInstallation());
      expect(dao.getById('a1')!.executableByUser, isFalse);

      dao.updatePath('a1', r'C:\chosen\codex.exe', byUser: true);
      expect(dao.getById('a1')!.executableByUser, isTrue);

      // And a later repair that moves it takes ownership back: at that point
      // discovery is what chose the path, so a sweep may move it again.
      dao.updatePath('a1', r'C:\found\codex.exe', byUser: false);
      expect(dao.getById('a1')!.executableByUser, isFalse);
    });

    test('refuses a path another row for the same agent already holds', () {
      // UNIQUE (agent_kind, environment_id, executable_path). Merging two rows
      // is the caller's decision, not a setter's, so this reports rather than
      // raising out of the middle of a sweep.
      dao.insert(agentInstallation(id: 'a1', path: r'C:\one\codex.exe'));
      dao.insert(agentInstallation(id: 'a2', path: r'C:\two\codex.exe'));

      expect(dao.updatePath('a2', r'C:\one\codex.exe', byUser: true), isFalse);
      expect(dao.getById('a2')!.executable.path, r'C:\two\codex.exe');
    });

    test('a row written before v39 reads as detected, not hand-set', () {
      // The column arrived with a DEFAULT 0, and every row that predates it is
      // in fact what that says: found by discovery, and free to be moved by it.
      db.execute(
        'INSERT INTO agent_installations '
        '(id, agent_kind, environment_id, executable_path, version, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?);',
        [
          'legacy',
          AgentIds.codex,
          'windows',
          r'C:\old\codex.exe',
          '1.0.0',
          isoFromDate(testTime),
        ],
      );
      expect(dao.getById('legacy')!.executableByUser, isFalse);
    });
  });
}
