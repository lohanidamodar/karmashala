import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late ExecutionEnvironmentDao dao;

  setUp(() {
    db = AppDatabase.memory();
    dao = ExecutionEnvironmentDao(db);
  });
  tearDown(() => db.close());

  test('upsert then read round-trips a windows environment', () {
    final env = windowsEnv();
    dao.upsert(env);
    expect(dao.getById('windows'), env);
  });

  test('stores wsl distribution name', () {
    dao.upsert(wslEnv());
    final loaded = dao.getById('wsl:Ubuntu');
    expect(loaded!.wslDistribution, 'Ubuntu');
  });

  test('upsert updates an existing row in place', () {
    dao.upsert(windowsEnv());
    dao.upsert(windowsEnv().copyWith(name: 'Windows 11'));
    expect(dao.getAll().length, 1);
    expect(dao.getById('windows')!.name, 'Windows 11');
  });

  test('getAll returns all and getById returns null when absent', () {
    dao.upsert(windowsEnv());
    dao.upsert(wslEnv());
    expect(dao.getAll().length, 2);
    expect(dao.getById('nope'), isNull);
  });

  test('delete removes the environment', () {
    dao.upsert(windowsEnv());
    dao.delete('windows');
    expect(dao.getById('windows'), isNull);
  });
}
