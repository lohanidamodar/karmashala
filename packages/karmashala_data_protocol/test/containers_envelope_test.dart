import 'dart:convert';

import 'package:karmashala_containers/karmashala_containers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// Linux containers as machines: the check, the create and its progress, and
/// start, stop and delete — through the envelope as JSON text.
void main() {
  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  const spec = ContainerSpec(
    name: 'sandbox',
    distro: ContainerDistro.fedora,
    cpus: 2,
    memoryMb: 4096,
    agents: [ContainerAgentCli.claude, ContainerAgentCli.copilot],
  );

  test('every request round-trips with its arguments', () {
    final requests = <DataRequest<Object?>>[
      const ContainerHostCheck('wsl:archlinux'),
      const ContainerCreate(
        environmentId: 'ssh:box',
        machineId: 'm1',
        spec: spec,
      ),
      const ContainerCreateCancel('m1'),
      const ContainerStatus('m1'),
      for (final action in ContainerPowerAction.values)
        ContainerPower('m1', action),
      const ContainerDelete('m1', withHome: true),
    ];
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request, isA<SshWorkRequest<Object?>>());
      expect(
        jsonEncode(read.request!.argumentsToJson()),
        jsonEncode(request.argumentsToJson()),
        reason: request.kind,
      );
    }
    final create =
        DataEnvelope.readRequest(
              overTheWire(
                DataEnvelope.request(
                  3,
                  const ContainerCreate(
                    environmentId: 'ssh:box',
                    machineId: 'm1',
                    spec: spec,
                  ),
                ),
              ),
            ).request!
            as ContainerCreate;
    expect(create.spec.distro, ContainerDistro.fedora);
    expect(create.spec.agents, spec.agents);
  });

  test('a distro this build does not offer is refused, not guessed', () {
    final json = overTheWire(
      DataEnvelope.request(
        3,
        const ContainerCreate(environmentId: 'e', machineId: 'm', spec: spec),
      ),
    );
    ((json['arguments']! as Map)['spec']! as Map)['distro'] = 'gentoo';
    expect(DataEnvelope.readRequest(json).refusal, isNotNull);
  });

  test('a check answers what the host has, or why it cannot', () {
    const ask = ContainerHostCheck('ssh:box');
    final reply = DataEnvelope.readAnswer(
      overTheWire(
        DataEnvelope.answer(
          4,
          ask,
          const DataReply(
            HostCheck(
              canHost: false,
              problem: 'Docker is installed on box but not running.',
              cores: 8,
            ),
            9,
            [],
          ),
        ),
      ),
      ask,
    );
    expect(reply.value.canHost, isFalse);
    expect(reply.value.problem, contains('not running'));
    expect(reply.value.cores, 8);
  });

  test('progress is told, and an older client drops what it does not '
      'know', () {
    final batch = DataChanges(5, [
      const ContainerProgress(
        machineId: 'm1',
        step: ContainerStep.settingUp,
        line: 'karmashala: installing ssh',
      ),
      const ContainerProgress(machineId: 'm1', step: ContainerStep.done),
    ]);
    final back = DataEnvelope.readChanges(
      overTheWire(DataEnvelope.changes(batch)),
    );
    final first = back.changes[0] as ContainerProgress;
    expect(first.step, ContainerStep.settingUp);
    expect(first.line, 'karmashala: installing ssh');
    expect((back.changes[1] as ContainerProgress).line, isNull);
  });

  test('status answers decode, and an unknown one reads as unknown', () {
    const ask = ContainerStatus('m1');
    expect(ask.resultFromJson('running'), ContainerState.running);
    expect(ask.resultFromJson('frozen'), ContainerState.unknown);
  });
}
