import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner_factory.dart';
import 'package:karmashala/src/features/environments/application/environment_resolver.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late ExecutionEnvironmentDao dao;

  ExecutionEnvironmentResolver resolverWith(CommandRunnerFactory runners) =>
      ExecutionEnvironmentResolver(environments: dao, runners: runners);

  setUp(() {
    db = AppDatabase.memory();
    dao = ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv())
      ..upsert(sshEnvFixture());
  });
  tearDown(() => db.close());

  group('resolves', () {
    test('a checkout to the environment its row names', () {
      final resolved = resolverWith(
        FakeCommandRunnerFactory(),
      ).resolveFor(const EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '/x'));

      expect(resolved.isResolved, isTrue);
      expect(resolved.environment, wslEnv());
      expect(resolved.refusal, isNull);
      expect(resolved.reason, isEmpty);
      expect(resolved.require, wslEnv());
    });

    test('an SSH row when the factory can dial it', () {
      final resolved = resolverWith(FakeCommandRunnerFactory()).resolve('ssh:h1');
      expect(resolved.environment, sshEnvFixture());
    });
  });

  group('refuses', () {
    test('with no checkout at all, naming no id it does not have', () {
      final refused = resolverWith(FakeCommandRunnerFactory()).resolveFor(null);

      expect(refused.isResolved, isFalse);
      expect(refused.environment, isNull);
      expect(refused.refusal, EnvironmentRefusal.noCheckout);
      expect(refused.reason, 'No checkout, so nothing says where its commands would run');
      expect(() => refused.require, throwsStateError);
    });

    test('an environment row that is gone, in the words git already used', () {
      final refused = resolverWith(FakeCommandRunnerFactory()).resolve('wsl:Gone');

      expect(refused.refusal, EnvironmentRefusal.environmentUnknown);
      expect(refused.reason, 'Unknown environment: wsl:Gone');
    });

    test('a WSL row whose stored distribution is gone from it', () {
      dao.upsert(
        ExecutionEnvironment(
          id: 'wsl:Broken',
          kind: EnvironmentKind.wsl,
          name: 'Broken',
          createdAt: testTime,
        ),
      );

      final refused = resolverWith(FakeCommandRunnerFactory()).resolve('wsl:Broken');

      expect(refused.refusal, EnvironmentRefusal.wslDistributionUnknown);
      expect(refused.reason, 'WSL environment wsl:Broken has no distribution name');
    });

    test('an SSH row when nothing is composed to dial it', () {
      final refused = resolverWith(
        const CommandRunnerFactory(),
      ).resolve('ssh:h1');

      expect(refused.refusal, EnvironmentRefusal.sshUnavailable);
      expect(
        refused.reason,
        'No SSH connection pool is configured; cannot run commands in ssh:h1',
      );
    });

    test(
      'nothing about SSH when the caller only wants the environment shape',
      () {
        // A command line to copy, a path to spell: no process starts, so
        // whether this app could dial the host is not the question.
        final resolved = resolverWith(
          const CommandRunnerFactory(),
        ).resolve('ssh:h1', runnable: false);

        expect(resolved.environment, sshEnvFixture());
      },
    );

    test('a broken WSL row even when nothing will be run', () {
      dao.upsert(
        ExecutionEnvironment(
          id: 'wsl:Broken',
          kind: EnvironmentKind.wsl,
          name: 'Broken',
          createdAt: testTime,
        ),
      );

      final refused = resolverWith(
        FakeCommandRunnerFactory(),
      ).resolve('wsl:Broken', runnable: false);

      expect(refused.refusal, EnvironmentRefusal.wslDistributionUnknown);
    });
  });
}
