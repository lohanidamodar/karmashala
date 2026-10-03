import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The ACP agents a person added, at the server: list, put, delete, the
/// refusals, and what every other client is told.
void main() {
  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late List<DataChanges> told;
  var now = DateTime.utc(2026, 10, 2, 12);
  var ids = 0;

  setUp(() {
    now = DateTime.utc(2026, 10, 2, 12);
    ids = 0;
    db = AppDatabase.memory();
    service = DataService(db, clock: () => now, newId: () => 'id-${++ids}');
    app = service.open((_) {});
    told = [];
    service.open(told.add).handle(const DataSubscribe());
  });
  tearDown(() => db.close());

  Matcher refused(DataRefusalCode code, String words) => throwsA(
    isA<DataRefused>()
        .having((r) => r.code, 'code', code)
        .having((r) => r.message, 'message', contains(words)),
  );

  List<DataChange> lastTold() => told.last.changes;

  const put = AcpAgentPut(
    agentName: ' My Agent ',
    command: ' my-agent ',
    args: ['--acp'],
    env: {'A': '1'},
    source: AcpAgentSource.registry,
    registryId: 'my-agent',
  );

  test('a put with no id creates under a server id, trimmed, and is told', () {
    final row = app.handle(put).value;
    expect(row.id, 'id-1');
    expect(row.name, 'My Agent');
    expect(row.command, 'my-agent');
    expect(row.args, ['--acp']);
    expect(row.env, {'A': '1'});
    expect(row.source, AcpAgentSource.registry);
    expect(row.registryId, 'my-agent');
    expect(row.createdAt, now);
    expect((lastTold().single as AcpAgentChanged).row, row);
    expect(app.handle(const AcpAgentsList()).value, [row]);
    expect(service.acpAgents, [row]);
  });

  test('a put naming a row rewrites it in place, keeping when it was made', () {
    final first = app.handle(put).value;
    now = now.add(const Duration(hours: 1));
    final again = app
        .handle(
          AcpAgentPut(
            id: first.id,
            agentName: 'Renamed',
            command: '/opt/agent',
            source: AcpAgentSource.custom,
          ),
        )
        .value;
    expect(again.id, first.id);
    expect(again.name, 'Renamed');
    expect(again.command, '/opt/agent');
    expect(again.args, isEmpty);
    expect(again.registryId, isNull);
    expect(again.createdAt, first.createdAt);
    expect(app.handle(const AcpAgentsList()).value, [again]);
    expect((lastTold().single as AcpAgentChanged).row, again);
  });

  test('a put keeps the registry icon, trimmed; a blank one is none', () {
    final withIcon = app
        .handle(
          const AcpAgentPut(
            id: 'i',
            agentName: 'n',
            command: 'c',
            iconUrl: ' https://cdn.example.test/registry/n.svg ',
          ),
        )
        .value;
    expect(withIcon.iconUrl, 'https://cdn.example.test/registry/n.svg');
    expect(app.handle(const AcpAgentsList()).value.single.iconUrl, isNotNull);
    final blank = app
        .handle(
          const AcpAgentPut(
            id: 'i',
            agentName: 'n',
            command: 'c',
            iconUrl: ' ',
          ),
        )
        .value;
    expect(blank.iconUrl, isNull);
    final none = app
        .handle(const AcpAgentPut(id: 'i', agentName: 'n', command: 'c'))
        .value;
    expect(none.iconUrl, isNull);
  });

  test('a put under an unknown id creates under that id', () {
    final row = app
        .handle(const AcpAgentPut(id: 'mine', agentName: 'n', command: 'c'))
        .value;
    expect(row.id, 'mine');
    expect(ids, 0);
  });

  test('a blank name or command is refused in words', () {
    expect(
      () => app.handle(const AcpAgentPut(agentName: '  ', command: 'c')),
      refused(DataRefusalCode.invalid, 'needs a name'),
    );
    expect(
      () => app.handle(const AcpAgentPut(agentName: 'n', command: ' ')),
      refused(DataRefusalCode.invalid, 'needs a command'),
    );
    expect(app.handle(const AcpAgentsList()).value, isEmpty);
    expect(told, isEmpty);
  });

  test('the list is oldest first', () {
    app.handle(const AcpAgentPut(id: 'b', agentName: 'B', command: 'b'));
    now = now.add(const Duration(minutes: 1));
    app.handle(const AcpAgentPut(id: 'a', agentName: 'A', command: 'a'));
    expect(app.handle(const AcpAgentsList()).value.map((r) => r.id), [
      'b',
      'a',
    ]);
  });

  test('a delete removes and is told; one already gone is acknowledged', () {
    final row = app.handle(put).value;
    expect(app.handle(AcpAgentDelete(row.id)).value, isA<DataAck>());
    expect((lastTold().single as AcpAgentRemoved).id, row.id);
    expect(app.handle(const AcpAgentsList()).value, isEmpty);
    final before = told.length;
    expect(app.handle(AcpAgentDelete(row.id)).value, isA<DataAck>());
    expect(told.length, before);
  });

  test('a delete is refused while a session runs under the agent', () {
    // Without the row its sessions would stop reading as ACP sessions, and
    // their transcript, resume and status hang on that.
    final row = app.handle(put).value;
    final windows = ExecutionEnvironment(
      id: 'windows',
      kind: EnvironmentKind.windowsNative,
      name: 'Windows',
      createdAt: now,
    );
    service.recordAgentsFound(windows, [
      AgentInstallation(
        id: 'w',
        agentId: row.agentId,
        executable: const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\mine.exe',
        ),
        createdAt: now,
      ),
    ], now);
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, '
      'title, use_worktree, status, created_at) '
      'VALUES (?, ?, ?, ?, 0, ?, ?);',
      ['s1', 'r1', 'w', 'Over ACP', 'completed', '$now'],
    );

    expect(
      () => app.handle(AcpAgentDelete(row.id)),
      refused(DataRefusalCode.invalid, 'has 1 session'),
    );
    expect(app.handle(const AcpAgentsList()).value, hasLength(1));
  });

  test('a delete takes the agent\'s installations with it, on every '
      'machine, told as removed', () {
    final row = app.handle(put).value;
    final windows = ExecutionEnvironment(
      id: 'windows',
      kind: EnvironmentKind.windowsNative,
      name: 'Windows',
      createdAt: now,
    );
    final wsl = ExecutionEnvironment(
      id: 'wsl:Ubuntu',
      kind: EnvironmentKind.wsl,
      name: 'Ubuntu',
      wslDistribution: 'Ubuntu',
      createdAt: now,
    );
    AgentInstallation found(
      String id,
      ExecutionEnvironment where,
      String path, {
      String? agentId,
    }) => AgentInstallation(
      id: id,
      agentId: agentId ?? row.agentId,
      executable: EnvironmentPath(environmentId: where.id, path: path),
      createdAt: now,
    );
    service.recordAgentsFound(windows, [
      found('w', windows, r'C:\mine.exe'),
      found('other', windows, r'C:\claude.exe', agentId: AgentIds.claudeCode),
    ], now);
    service.recordAgentsFound(wsl, [found('u', wsl, '/usr/bin/mine')], now);
    told.clear();

    app.handle(AcpAgentDelete(row.id));

    final changes = lastTold();
    expect(changes.whereType<AcpAgentRemoved>().single.id, row.id);
    expect(
      changes.whereType<InstallationRemoved>().map((c) => c.id),
      unorderedEquals(['w', 'u']),
    );
    expect(
      app.handle(const AgentsList()).value.installations.map((i) => i.id),
      ['other'],
    );
  });

  test('the agents snapshot carries the rows', () {
    final row = app.handle(put).value;
    expect(app.handle(const AgentsList()).value.acpAgents, [row]);
  });

  test('the request and its answer survive the wire', () {
    final read = DataEnvelope.readRequest(DataEnvelope.request(1, put));
    expect(read.refusal, isNull);
    expect(read.request!.argumentsToJson(), put.argumentsToJson());
    final reply = app.handle(put);
    final answer = DataEnvelope.readAnswer(
      DataEnvelope.answer(1, put, reply),
      put,
    );
    expect(answer.value, reply.value);
    expect(answer.changes.single, isA<AcpAgentChanged>());
  });
}
