import 'package:karmashala/src/core/process/command_runner_factory.dart';
import 'package:karmashala/src/core/process/ssh_command_runner.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:karmashala/src/features/ssh/data/known_host_dao.dart';
import 'package:karmashala/src/features/ssh/data/ssh_connection_pool.dart';
import 'package:karmashala/src/features/ssh/data/ssh_host_dao.dart';
import 'package:karmashala/src/features/ssh/domain/ssh_host.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;

  final remote = ExecutionEnvironment(
    id: 'ssh:h1',
    kind: EnvironmentKind.ssh,
    name: 'build-box',
    sshHostId: 'h1',
    createdAt: testTime,
  );

  final saved = SshHost(
    id: 'h1',
    name: 'build-box',
    host: '127.0.0.1',
    port: 2222,
    username: 'dev',
    authMethod: SshAuthMethod.privateKey,
    createdAt: testTime,
  );

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  SshConnectionPool pool() =>
      SshConnectionPool(hosts: SshHostDao(db), knownHosts: KnownHostDao(db));

  test('the factory builds an SshCommandRunner for an ssh environment', () {
    SshHostDao(db).upsert(saved);
    final runner = CommandRunnerFactory(
      sshConnections: pool,
    ).forEnvironment(remote);
    expect(runner, isA<SshCommandRunner>());
    expect(runner.environmentId, 'ssh:h1');
  });

  test('an ssh environment without a connection pool fails loudly', () {
    expect(
      () => const CommandRunnerFactory().forEnvironment(remote),
      throwsA(isA<StateError>()),
    );
  });

  test('an ssh environment without a saved host fails loudly', () {
    expect(
      () => CommandRunnerFactory(sshConnections: pool).forEnvironment(remote),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('an ssh environment with no host id is rejected', () {
    SshHostDao(db).upsert(saved);
    final orphan = ExecutionEnvironment(
      id: 'ssh:orphan',
      kind: EnvironmentKind.ssh,
      name: 'orphan',
      createdAt: testTime,
    );
    expect(
      () => CommandRunnerFactory(sshConnections: pool).forEnvironment(orphan),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('the pool hands the same connection to every runner for a host', () {
    SshHostDao(db).upsert(saved);
    final shared = pool();
    expect(
      identical(shared.forHostId('h1'), shared.forHostId('h1')),
      isTrue,
      reason: 'a connection per command would make remote work unusable',
    );
  });
}
