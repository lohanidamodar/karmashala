import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'dart:io';

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

  test('creates the local host environment on first run', () {
    final id = ensureLocalEnvironment(dao, clock);
    expect(id, localHostEnvironmentId);
    final env = dao.getById(localHostEnvironmentId)!;
    // The host this suite is running on, not Windows unconditionally: a Mac
    // that registered itself as `windowsNative` looked its agent CLIs up with
    // `where` and found none of them.
    expect(env.kind, localHostEnvironmentKind);
    expect(
      env.kind,
      Platform.isWindows
          ? EnvironmentKind.windowsNative
          : EnvironmentKind.localPosix,
    );
  });

  test('is idempotent — does not duplicate or overwrite', () {
    ensureLocalEnvironment(dao, clock);
    ensureLocalEnvironment(dao, clock);
    expect(dao.getAll().length, 1);
  });
}
