import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:test/test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

CommandResult _ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');
const _notFound = CommandResult(exitCode: 1, stdout: '', stderr: '');

/// A person-added ACP agent is a row; the row is an adapter; the registry
/// takes the adapters beside the shipped ones.
void main() {
  final row = AcpAgentRow(
    id: 'r1',
    name: 'My Agent',
    command: 'my-agent',
    args: const ['--acp', '--quiet'],
    env: const {'MY_AGENT_HOME': '/tmp/agent'},
    source: AcpAgentSource.registry,
    registryId: 'my-agent',
    createdAt: testTime,
  );

  group('acpAgentAdapter', () {
    test('is a data-only adapter shaped by the row', () {
      final adapter = acpAgentAdapter(row);
      expect(adapter, isA<DataOnlyAgentAdapter>());
      expect(adapter.id, 'acp:r1');
      expect(row.agentId, adapter.id);
      final descriptor = adapter.descriptor;
      expect(descriptor.displayName, 'My Agent');
      expect(descriptor.binaries.windows, ['my-agent']);
      expect(descriptor.binaries.posix, ['my-agent']);
      expect(descriptor.statusStrategy, AgentStatusStrategy.none);
      expect(descriptor.hooks, isNull);
      expect(descriptor.grid.isEmpty, isTrue);
      expect(descriptor.discovery.probeVersion, isFalse);
      expect(adapter.acp, isNotNull);
      expect(adapter.acp!.arguments, ['--acp', '--quiet']);
      expect(adapter.acp!.environment, {'MY_AGENT_HOME': '/tmp/agent'});
      expect(adapter.acp!.npxPackage, isNull);
      expect(adapter.capabilities, contains(AgentCapability.acp));
    });

    test('the row compares by value and copies with changes', () {
      expect(row, row.copyWith());
      expect(row.copyWith(name: 'Other'), isNot(row));
      expect(row.copyWith(clearRegistryId: true).registryId, isNull);
      expect(row.hashCode, row.copyWith().hashCode);
    });
  });

  group('AgentRegistry.withExtra', () {
    test('appends the extras after the built-ins and leaves builtIn alone', () {
      final registry = AgentRegistry.withExtra([acpAgentAdapter(row)]);
      expect(registry.adapters.map((a) => a.id), [
        ...AgentIds.builtIn,
        'acp:r1',
      ]);
      expect(registry.displayNameFor('acp:r1'), 'My Agent');
      expect(AgentRegistry.builtIn.adapters.map((a) => a.id), AgentIds.builtIn);
      expect(AgentRegistry.builtIn.adapterFor('acp:r1'), isNull);
    });

    test('a later id wins a collision, in the earlier one\'s place', () {
      final first = acpAgentAdapter(row);
      final second = acpAgentAdapter(row.copyWith(name: 'Renamed'));
      final registry = AgentRegistry.withExtra([first, second]);
      expect(
        registry.adapters
            .where((a) => a.id == 'acp:r1')
            .single
            .descriptor
            .displayName,
        'Renamed',
      );
      expect(registry.adapters.length, AgentIds.builtIn.length + 1);
    });

    test('with no extras it lists exactly the built-ins', () {
      expect(
        AgentRegistry.withExtra(const []).adapters.map((a) => a.id),
        AgentIds.builtIn,
      );
    });
  });

  group('discovery of a row-backed agent', () {
    test('a bare command is looked up on PATH like any binary', () async {
      final runner = FakeCommandRunner(
        responder: (req) {
          if (req.executable == 'where' && req.arguments.single == 'my-agent') {
            return _ok(r'C:\tools\my-agent.exe');
          }
          return _notFound;
        },
      );
      final found = await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        registry: AgentRegistry.withExtra([acpAgentAdapter(row)]),
        hostEnvironment: const {},
      ).discover(agentIds: {'acp:r1'});
      expect(found.single.agentId, 'acp:r1');
      expect(found.single.executable.path, r'C:\tools\my-agent.exe');
      // No version probe: the row never said `--version` is safe.
      expect(found.single.version, isNull);
      expect(runner.requests.where((r) => r.executable != 'where'), isEmpty);
    });

    test('an absolute command is taken as given, without a lookup', () async {
      final runner = FakeCommandRunner(responder: (_) => _notFound);
      final absolute = row.copyWith(command: '/opt/agent/bin/my-agent');
      final found = await AgentDiscoveryService(
        runner: runner,
        environment: wslEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        registry: AgentRegistry.withExtra([acpAgentAdapter(absolute)]),
        hostEnvironment: const {},
      ).discover(agentIds: {'acp:r1'});
      expect(found.single.executable.path, '/opt/agent/bin/my-agent');
      expect(runner.requests, isEmpty);
    });
  });
}
