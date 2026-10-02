import 'package:karmashala_environments/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// `acp_auth_choices`: one choice per installation, replaced whole, with the
/// confirmation time kept apart from the choice.
void main() {
  late AppDatabase db;
  late AcpAuthChoiceDao dao;
  final t0 = DateTime.utc(2026, 10, 2, 12);

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    AgentInstallationDao(db).insert(agentInstallation());
    dao = AcpAuthChoiceDao(db);
  });
  tearDown(() => db.close());

  test('nothing chosen reads as null', () {
    expect(dao.getByInstallation('a1'), isNull);
  });

  test('a choice round-trips, and a later one replaces it', () {
    dao.upsert(
      AcpAuthChoice(
        installationId: 'a1',
        methodId: 'login',
        methodName: 'Log in',
        chosenAt: t0,
      ),
    );
    var read = dao.getByInstallation('a1')!;
    expect(read.methodId, 'login');
    expect(read.methodName, 'Log in');
    expect(read.authenticatedAt, isNull);
    expect(read.chosenAt, t0);

    dao.upsert(
      AcpAuthChoice(
        installationId: 'a1',
        methodId: 'api-key',
        methodName: 'API key',
        chosenAt: t0.add(const Duration(minutes: 1)),
        authenticatedAt: t0.add(const Duration(minutes: 2)),
      ),
    );
    read = dao.getByInstallation('a1')!;
    expect(read.methodId, 'api-key');
    expect(read.authenticatedAt, t0.add(const Duration(minutes: 2)));
  });

  test('a cleared choice is gone', () {
    dao.upsert(
      AcpAuthChoice(
        installationId: 'a1',
        methodId: 'login',
        methodName: 'Log in',
        chosenAt: t0,
      ),
    );
    dao.delete('a1');
    expect(dao.getByInstallation('a1'), isNull);
  });
}
