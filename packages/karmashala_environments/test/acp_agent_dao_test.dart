import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The `acp_agents` table and the installation column v66 added.
void main() {
  final t0 = DateTime.utc(2026, 10, 2, 12);
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  AcpAgentRow row({
    String id = 'r1',
    String name = 'My Agent',
    List<String> args = const ['--acp'],
    Map<String, String> env = const {'A': '1'},
    DateTime? createdAt,
  }) => AcpAgentRow(
    id: id,
    name: name,
    command: 'my-agent',
    args: args,
    env: env,
    source: AcpAgentSource.registry,
    registryId: 'my-agent',
    createdAt: createdAt ?? t0,
  );

  group('AcpAgentDao', () {
    late AcpAgentDao dao;
    setUp(() => dao = AcpAgentDao(db));

    test('round-trips args and env as JSON, upserts in place, deletes', () {
      dao.upsert(row());
      dao.upsert(row(id: 'r2', createdAt: t0.add(const Duration(minutes: 1))));
      expect(dao.getById('r1'), row());
      expect(dao.getAll().map((r) => r.id), ['r1', 'r2']);
      dao.upsert(row(name: 'Renamed', args: const [], env: const {}));
      expect(dao.getById('r1')!.name, 'Renamed');
      expect(dao.getById('r1')!.args, isEmpty);
      expect(dao.getById('r1')!.env, isEmpty);
      expect(dao.getAll(), hasLength(2));
      expect(dao.getById('nope'), isNull);
      dao.delete('r1');
      expect(dao.getById('r1'), isNull);
    });

    test('a custom row has no registry id', () {
      dao.upsert(
        AcpAgentRow(
          id: 'c1',
          name: 'Local',
          command: r'C:\tools\agent.exe',
          createdAt: t0,
        ),
      );
      final read = dao.getById('c1')!;
      expect(read.source, AcpAgentSource.custom);
      expect(read.registryId, isNull);
      expect(read.command, r'C:\tools\agent.exe');
    });

    test('malformed JSON in a row reads as no args and no env', () {
      db.execute(
        'INSERT INTO acp_agents (id, name, command, args, env, source, '
        "created_at) VALUES ('bad', 'Bad', 'bad', 'not json', '[1]', "
        "'custom', ?);",
        [isoFromDate(t0)],
      );
      var read = dao.getById('bad')!;
      expect(read.args, isEmpty);
      expect(read.env, isEmpty);
      db.execute("UPDATE acp_agents SET args = '{}', env = '[1]';");
      read = dao.getById('bad')!;
      expect(read.args, isEmpty);
      expect(read.env, isEmpty);
    });

    test('a source this build does not know reads as custom, and the table '
        'still lists', () {
      dao.upsert(row());
      db.execute("UPDATE acp_agents SET source = 'marketplace';");
      expect(dao.getById('r1')!.source, AcpAgentSource.custom);
      expect(dao.getAll(), hasLength(1));
    });
  });

  group('installation leading arguments', () {
    late AgentInstallationDao dao;

    AgentInstallation npx({List<String> leading = const []}) =>
        AgentInstallation(
          id: 'i1',
          agentId: 'some-agent',
          executable: const EnvironmentPath(
            environmentId: 'windows',
            path: r'C:\Program Files\nodejs\npx.cmd',
          ),
          createdAt: t0,
          leadingArguments: leading,
        );

    setUp(() {
      ExecutionEnvironmentDao(db).upsert(
        ExecutionEnvironment(
          id: 'windows',
          kind: EnvironmentKind.windowsNative,
          name: 'Windows',
          createdAt: t0,
        ),
      );
      dao = AgentInstallationDao(db);
    });

    test('round-trip through the store', () {
      dao.insert(npx(leading: const ['-y', '@scope/pkg']));
      expect(dao.getById('i1'), npx(leading: const ['-y', '@scope/pkg']));
      expect(
        db.query('SELECT leading_arguments FROM agent_installations;').first,
        {'leading_arguments': '["-y","@scope/pkg"]'},
      );
    });

    test('none is stored as null and read as empty', () {
      dao.insert(npx());
      expect(
        db.query('SELECT leading_arguments FROM agent_installations;').first,
        {'leading_arguments': null},
      );
      expect(dao.getById('i1')!.leadingArguments, isEmpty);
    });

    test('round-trip through the wire', () {
      final sent = npx(leading: const ['-y', '@scope/pkg']);
      expect(installationFromJson(installationToJson(sent)), sent);
      expect(installationToJson(sent)['leadingArguments'], [
        '-y',
        '@scope/pkg',
      ]);
      expect(
        installationToJson(npx()).containsKey('leadingArguments'),
        isFalse,
      );
      expect(installationFromJson(installationToJson(npx())), npx());
      expect(
        () => installationFromJson({
          ...installationToJson(npx()),
          'leadingArguments': [1],
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
