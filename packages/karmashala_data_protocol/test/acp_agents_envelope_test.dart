import 'dart:convert';

import 'package:agent_cli/discovery.dart' show AgentDiscoveryReport;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// The person-added ACP agents through the envelope as JSON text.
void main() {
  final t0 = DateTime.utc(2026, 10, 2, 9, 30);
  final row = AcpAgentRow(
    id: 'r1',
    name: 'My Agent',
    command: 'my-agent',
    args: const ['--acp'],
    env: const {'HOME_X': '/x'},
    source: AcpAgentSource.registry,
    registryId: 'my-agent',
    iconUrl: 'https://cdn.example.test/registry/my-agent.svg',
    createdAt: t0,
  );
  final custom = AcpAgentRow(
    id: 'c1',
    name: 'Local',
    command: r'C:\tools\agent.exe',
    createdAt: t0,
  );

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  test('a row round-trips, with and without a registry id and icon', () {
    final read = acpAgentRowFromJson(overTheWire(acpAgentRowToJson(row)));
    expect(read, row);
    expect(read.iconUrl, 'https://cdn.example.test/registry/my-agent.svg');
    final wire = overTheWire(acpAgentRowToJson(custom));
    expect(wire.containsKey('registryId'), isFalse);
    expect(wire.containsKey('iconUrl'), isFalse);
    expect(wire['source'], 'custom');
    expect(acpAgentRowFromJson(wire), custom);
    // A row an older server sent, with no icon field at all.
    final older = overTheWire(acpAgentRowToJson(row))..remove('iconUrl');
    expect(acpAgentRowFromJson(older).iconUrl, isNull);
  });

  test('a row out of shape is refused in words', () {
    final json = acpAgentRowToJson(row);
    expect(
      () => acpAgentRowFromJson({...json, 'args': 'nope'}),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => acpAgentRowFromJson({
        ...json,
        'env': {'A': 1},
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => acpAgentRowFromJson({...json, 'source': 'elsewhere'}),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => acpAgentRowFromJson({...json, 'command': null}),
      throwsA(isA<FormatException>()),
    );
  });

  test('every request round-trips with its arguments', () {
    final requests = <DataRequest<Object?>>[
      const AcpAgentsList(),
      const AcpAgentPut(
        agentName: 'My Agent',
        command: 'my-agent',
        args: ['--acp'],
        env: {'A': '1'},
        source: AcpAgentSource.registry,
        registryId: 'my-agent',
        iconUrl: 'https://cdn.example.test/registry/my-agent.svg',
      ),
      const AcpAgentPut(id: 'r1', agentName: 'Renamed', command: 'x'),
      const AcpAgentDelete('r1'),
    ];
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request.runtimeType, request.runtimeType);
      expect(
        read.request!.argumentsToJson(),
        request.argumentsToJson(),
        reason: request.kind,
      );
    }
    expect(
      requests.map((r) => r.kind),
      [
        'acpAgents.list',
        'acpAgents.put',
        'acpAgents.delete',
      ].expand((k) => k == 'acpAgents.put' ? [k, k] : [k]),
    );
  });

  test('a put with a bad source or env is refused invalid', () {
    DataRefused? refusalOf(Map<String, Object?> arguments) =>
        DataEnvelope.readRequest({
          'id': 1,
          'kind': AcpAgentPut.name,
          'arguments': arguments,
        }).refusal;
    expect(
      refusalOf({'name': 'n', 'command': 'c', 'source': 'elsewhere'})?.code,
      DataRefusalCode.invalid,
    );
    expect(
      refusalOf({
        'name': 'n',
        'command': 'c',
        'env': {'A': 1},
      })?.code,
      DataRefusalCode.invalid,
    );
    expect(refusalOf({'name': 'n', 'command': 'c'}), isNull);
    expect(
      refusalOf({'name': 'n', 'command': 'c', 'iconUrl': 7})?.code,
      DataRefusalCode.invalid,
    );
  });

  test('an install request round-trips with every argument, and refuses '
      'what is missing', () {
    const install = AcpAgentInstall(
      environmentId: 'wsl:arch',
      registryId: 'antigravity-acp',
      version: '1.3.0',
      archive: 'https://dl.example.test/agy-1.3.0-linux-x86_64.zip',
      command: './agy_acp_server.par',
      args: ['--uid='],
      sha256: 'abc',
      agentId: 'antigravity-acp',
    );
    final read = DataEnvelope.readRequest(
      overTheWire(DataEnvelope.request(7, install)),
    );
    expect(read.refusal, isNull);
    final back = read.request! as AcpAgentInstall;
    expect(back.environmentId, 'wsl:arch');
    expect(back.registryId, 'antigravity-acp');
    expect(back.version, '1.3.0');
    expect(back.archive, install.archive);
    expect(back.command, './agy_acp_server.par');
    expect(back.args, ['--uid=']);
    expect(back.sha256, 'abc');
    expect(back.agentId, 'antigravity-acp');
    expect(install.kind, 'acpAgents.install');
    // Answered when the server's work is done, like every agent work.
    expect(install, isA<AgentWorkRequest<Object?>>());

    const least = AcpAgentInstall(
      environmentId: 'windows',
      registryId: 'x',
      version: '1',
      archive: 'https://x.test/a.zip',
      command: 'a.exe',
    );
    final wire = overTheWire(least.argumentsToJson());
    expect(wire.containsKey('sha256'), isFalse);
    expect(wire.containsKey('agentId'), isFalse);
    final leastBack =
        DataEnvelope.readRequest(
              overTheWire(DataEnvelope.request(8, least)),
            ).request!
            as AcpAgentInstall;
    expect(leastBack.args, isEmpty);
    expect(leastBack.sha256, isNull);
    expect(leastBack.agentId, isNull);

    expect(
      DataEnvelope.readRequest({
        'id': 9,
        'kind': AcpAgentInstall.name,
        'arguments': {'environmentId': 'windows', 'registryId': 'x'},
      }).refusal?.code,
      DataRefusalCode.invalid,
    );
  });

  test('an install\'s answer and its progress are typed', () {
    const install = AcpAgentInstall(
      environmentId: 'windows',
      registryId: 'x',
      version: '1',
      archive: 'https://x.test/a.zip',
      command: 'a.exe',
    );
    const installed = AcpAgentInstalled(
      executablePath: r'C:\Users\me\karmashala\acp\x\1\a.exe',
      report: AgentDiscoveryReport.empty(),
    );
    final answer = DataEnvelope.readAnswer(
      overTheWire(
        DataEnvelope.answer(4, install, DataReply(installed, 9, const [])),
      ),
      install,
    );
    expect(answer.value.executablePath, installed.executablePath);
    expect(answer.value.report, isNotNull);
    final bare = AcpAgentInstalled.fromJson(
      overTheWire(const AcpAgentInstalled(executablePath: '/x').toJson()),
    );
    expect(bare.executablePath, '/x');
    expect(bare.report, isNull);

    final batch = DataChanges(5, [
      const AcpInstallProgress(
        environmentId: 'windows',
        registryId: 'x',
        step: AcpInstallStep.unpacking,
      ),
    ]);
    final read = DataChanges.fromJson(overTheWire(batch.toJson()));
    final progress = read.changes.single as AcpInstallProgress;
    expect(progress.environmentId, 'windows');
    expect(progress.registryId, 'x');
    expect(progress.step, AcpInstallStep.unpacking);
  });

  test('answers carry typed results', () {
    DataReply<R> roundTrip<R>(DataRequest<R> request, R result) =>
        DataEnvelope.readAnswer(
          overTheWire(
            DataEnvelope.answer(4, request, DataReply(result, 9, const [])),
          ),
          request,
        );
    expect(roundTrip(const AcpAgentsList(), [row, custom]).value, [
      row,
      custom,
    ]);
    expect(
      roundTrip(
        const AcpAgentPut(agentName: 'My Agent', command: 'my-agent'),
        row,
      ).value,
      row,
    );
    expect(
      roundTrip(const AcpAgentDelete('r1'), const DataAck()).value,
      isA<DataAck>(),
    );
  });

  test('changes round-trip and are typed', () {
    final batch = DataChanges(5, [
      AcpAgentChanged(row),
      const AcpAgentRemoved('c1'),
    ]);
    final read = DataChanges.fromJson(overTheWire(batch.toJson()));
    expect(read.revision, 5);
    expect((read.changes[0] as AcpAgentChanged).row, row);
    expect((read.changes[1] as AcpAgentRemoved).id, 'c1');
    expect(read.changes, everyElement(isA<AcpAgentsChange>()));
  });

  test('the agents snapshot carries the rows, and reads none when absent', () {
    final snapshot = AgentsSnapshot(acpAgents: [row]);
    final read = AgentsSnapshot.fromJson(overTheWire(snapshot.toJson()));
    expect(read.acpAgents, [row]);
    final older = overTheWire(snapshot.toJson())..remove('acpAgents');
    expect(AgentsSnapshot.fromJson(older).acpAgents, isEmpty);
  });
}
