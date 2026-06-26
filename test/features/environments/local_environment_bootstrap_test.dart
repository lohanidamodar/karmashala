import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_kind.dart';
import 'package:chitragupta/src/features/environments/domain/local_environment.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late ExecutionEnvironmentDao dao;
  final clock = FixedClock(testTime);

  setUp(() {
    db = AppDatabase.memory();
    dao = ExecutionEnvironmentDao(db);
  });
  tearDown(() => db.close());

  test('creates the local Windows environment on first run', () {
    final id = ensureLocalEnvironment(dao, clock);
    expect(id, localWindowsEnvironmentId);
    final env = dao.getById(localWindowsEnvironmentId)!;
    expect(env.kind, EnvironmentKind.windowsNative);
  });

  test('is idempotent — does not duplicate or overwrite', () {
    ensureLocalEnvironment(dao, clock);
    ensureLocalEnvironment(dao, clock);
    expect(dao.getAll().length, 1);
  });
}
