import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/core/database/row_mapping.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
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
}
