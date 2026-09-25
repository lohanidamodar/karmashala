import 'package:agent_cli/src/process/command_runner.dart';
import 'package:agent_cli/src/agents/data/agent_discovery_service.dart';
import 'package:agent_cli/src/agents/domain/agent_descriptor.dart';
import 'package:agent_cli/src/agents/adapter/data_only_agent_adapter.dart';
import 'package:agent_cli/src/agents/domain/agent_registry.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';
import '../support/fakes.dart';
import '../support/fixtures.dart';

CommandResult _ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');
const _notFound = CommandResult(exitCode: 1, stdout: '', stderr: 'not found');

/// A registry-only agent: a descriptor and no adapter code of its own.
const _kindless = AgentDescriptor(
  id: 'cursorAgent',
  displayName: 'Cursor Agent',
  binaries: AgentBinaries(
    windows: ['cursor-agent', 'cursor'],
    posix: ['cursor-agent'],
  ),
);

AgentDiscoveryService serviceWith(
  FakeCommandRunner runner,
  AgentRegistry registry,
) => AgentDiscoveryService(
  runner: runner,
  environment: windowsEnv(),
  ids: SequentialIdGenerator(),
  clock: FixedClock(testTime),
  registry: registry,
);

void main() {
  test('probes exactly the registry descriptors, in registry order', () async {
    final runner = FakeCommandRunner(responder: (_) => _ok(r'C:\bin\x.exe'));
    final registry = AgentRegistry([
      AgentRegistry.builtIn.adapterFor('codex')!,
      DataOnlyAgentAdapter(_kindless),
    ]);

    final found = await serviceWith(runner, registry).probeAll();

    expect(found.map((f) => f.descriptor.id), ['codex', 'cursorAgent']);
    expect(
      runner.requests
          .where((r) => r.executable == 'where')
          .map((r) => r.arguments.single),
      ['codex', 'cursor-agent'],
    );
  });

  test('falls through to the next binary name for the platform', () async {
    final runner = FakeCommandRunner(
      responder: (req) {
        if (req.executable != 'where') return _ok('2.0.0');
        return req.arguments.single == 'cursor'
            ? _ok(r'C:\bin\cursor.exe')
            : _notFound;
      },
    );

    final found = await serviceWith(
      runner,
      const AgentRegistry([DataOnlyAgentAdapter(_kindless)]),
    ).probeAll();

    expect(found.single.executable.path, r'C:\bin\cursor.exe');
    expect(found.single.version, '2.0.0');
  });

  test('skips the version probe when the descriptor opts out', () async {
    final runner = FakeCommandRunner(responder: (_) => _ok(r'C:\bin\x.exe'));
    const descriptor = AgentDescriptor(
      id: 'quiet',
      displayName: 'Quiet',
      binaries: AgentBinaries(windows: ['quiet'], posix: ['quiet']),
      discovery: AgentDiscoveryRules(probeVersion: false),
    );

    final found = await serviceWith(
      runner,
      const AgentRegistry([DataOnlyAgentAdapter(descriptor)]),
    ).probeAll();

    expect(found.single.version, isNull);
    expect(
      runner.requests.length,
      1,
    ); // located only, never asked for a version
  });

  test('discover() persists data-only agents', () async {
    final runner = FakeCommandRunner(responder: (_) => _ok(r'C:\bin\x.exe'));
    final registry = AgentRegistry([
      AgentRegistry.builtIn.adapterFor('codex')!,
      DataOnlyAgentAdapter(_kindless),
    ]);

    expect((await serviceWith(runner, registry).probeAll()).length, 2);
    expect(
      (await serviceWith(runner, registry).discover()).map((i) => i.agentId),
      ['codex', 'cursorAgent'],
    );
  });
}
