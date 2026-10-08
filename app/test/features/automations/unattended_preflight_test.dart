import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/automations/application/automation_providers.dart';
import 'package:karmashala/src/features/automations/application/unattended_preflight.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/unattended.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';

/// The lookup half of the gate, against the app's own tables.
///
/// The rules are pinned by `unattended_gate_test.dart`; what these hold is that
/// the *right* facts reach them — that the mode's rung comes from the agent's
/// own declared axes, and that the environment answer is the resolver's, in
/// the resolver's own words. Project checks are none of them.
void main() {
  late FakeDataServer server;
  late DataClient client;
  late ProviderContainer container;

  Automation automation({
    String repositoryId = 'r1',
    String installationId = 'a1',
    // Claude Code's declared default asks, so a helper that left this null
    // would be testing the permission rule in every case. `auto` is one of the
    // agent's own modes that does not prompt.
    PermissionSelection? mode = const PermissionSelection({'mode': 'auto'}),
  }) => Automation(
    id: 'auto1',
    repositoryId: repositoryId,
    name: 'Nightly sweep',
    schedule: const AutomationSchedule.cron('0 3 * * *'),
    agentInstallationId: installationId,
    prompt: 'Run the checks.',
    permissionMode: mode,
    enabled: true,
    armedAt: testTime,
  );

  UnattendedRefusal? refusalFor(Automation a) =>
      container.read(unattendedPreflightProvider).refusalFor(a);

  ProviderContainer build({List<Override> extra = const []}) =>
      ProviderContainer(
        overrides: [
          dataClientProvider.overrideWithValue(client),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator('c-')),
          ...extra,
        ],
      );

  setUp(() async {
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    client = await server.connect();
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    server.automationRows.insert(automation());
    container = build();
    addTearDown(container.dispose);
  });

  group('checks are an optional step, never a precondition', () {
    test('with no checks at all, an agent that never asks may run', () {
      expect(
        container.read(projectChecksDataProvider).forRepository('r1'),
        isEmpty,
      );
      expect(refusalFor(automation()), isNull);
    });

    test('with no checks at all, an agent that asks is refused', () {
      final refusal = refusalFor(
        automation(mode: const PermissionSelection({'mode': 'manual'})),
      )!;
      expect(refusal.kind, UnattendedRefusalKind.permissionModeCanPrompt);
    });
  });

  group('the mode comes from the agent\'s own declared axes', () {
    test('Claude Code\'s default asks every time, so it is refused', () {
      // `manual` is the declared default, `PermissionRisk.ask`. A null stored
      // mode means "nobody chose", which resolves to that default — not to
      // "enforce nothing", and not to a way past the rule.
      final refusal = refusalFor(automation(mode: null))!;
      expect(refusal.kind, UnattendedRefusalKind.permissionModeCanPrompt);
      expect(refusal.reason, contains('Claude Code'));
      // The evidence the mode was read off travels with the refusal.
      expect(refusal.reason, contains('permission-mode'));
    });

    test('a mode that does not prompt is allowed', () {
      expect(
        refusalFor(
          automation(mode: const PermissionSelection({'mode': 'auto'})),
        ),
        isNull,
      );
    });

    test('"enforce nothing" claims nothing, so it is refused', () {
      final refusal = refusalFor(automation(mode: PermissionSelection.empty))!;
      expect(refusal.kind, UnattendedRefusalKind.permissionModeUnknown);
    });

    test('an agent that is no longer installed is refused by name', () {
      final refusal = refusalFor(automation(installationId: 'gone'))!;
      expect(refusal.kind, UnattendedRefusalKind.agentUnavailable);
      expect(refusal.reason, contains('no longer installed'));
    });

    test('every rung the gate allows is one this agent really has', () {
      // The rungs are not invented here: each is a value on Claude Code's own
      // axis, with its own evidence.
      for (final mode in const [
        'plan',
        'dontAsk',
        'auto',
        'bypassPermissions',
      ]) {
        expect(
          refusalFor(automation(mode: PermissionSelection({'mode': mode}))),
          isNull,
          reason: '$mode does not stop for a human',
        );
      }
      for (final mode in const ['manual', 'acceptEdits']) {
        expect(
          refusalFor(
            automation(mode: PermissionSelection({'mode': mode})),
          )?.kind,
          UnattendedRefusalKind.permissionModeCanPrompt,
          reason: '$mode asks',
        );
      }
    });
  });

  group('the environment has to be reachable from here', () {
    test('an SSH checkout with no connection pool is refused, in the '
        'resolver\'s words', () async {
      server.environmentRows.upsert(
        ExecutionEnvironment(
          id: 'ssh:build',
          kind: EnvironmentKind.ssh,
          name: 'build host',
          createdAt: testTime,
        ),
      );
      server.repositoryRows.insert(
        repository(
          id: 'r2',
          name: 'remote',
          environmentId: 'ssh:build',
          path: '/home/me/app',
        ),
      );
      await pumpEventQueue();
      // A container composed without a pool: exactly "this app cannot reach
      // where the agent would run".
      container.dispose();
      container = build(
        extra: [
          commandRunnerFactoryProvider.overrideWithValue(
            const CommandRunnerFactory(),
          ),
        ],
      );

      final refusal = refusalFor(automation(repositoryId: 'r2'))!;
      expect(refusal.kind, UnattendedRefusalKind.environmentUnreachable);
      expect(refusal.reason, contains('No SSH connection pool is configured'));
      expect(refusal.reason, contains('cannot run a command in'));
    });

    test('a checkout that left the workspace is refused as unnamed', () {
      final refusal = refusalFor(automation(repositoryId: 'gone'))!;
      expect(refusal.kind, UnattendedRefusalKind.environmentUnnamed);
      expect(refusal.reason, contains('no longer in the workspace'));
    });

    test(
      'a WSL checkout whose distribution went away is refused as unnamed',
      () async {
        server.environmentRows.upsert(
          ExecutionEnvironment(
            id: 'wsl:gone',
            kind: EnvironmentKind.wsl,
            name: 'gone',
            createdAt: testTime,
          ),
        );
        server.repositoryRows.insert(
          repository(
            id: 'r3',
            name: 'inside',
            environmentId: 'wsl:gone',
            path: '/home/me/app',
          ),
        );
        await pumpEventQueue();
        final refusal = refusalFor(automation(repositoryId: 'r3'))!;
        expect(refusal.kind, UnattendedRefusalKind.environmentUnnamed);
        expect(refusal.reason, contains('has no distribution name'));
      },
    );
  });

  test('the gate\'s inputs are the app\'s own facts, not defaults', () {
    final input = container
        .read(unattendedPreflightProvider)
        .inputFor(automation());
    expect(input.repositoryName, 'app');
    expect(input.agentName, 'Claude Code');
    expect(input.agentInstalled, isTrue);
    expect(input.permits, PermissionRisk.autoRun);
    expect(input.permissionLabel, 'Automatic');
    expect(input.permissionEvidence, isNotEmpty);
    expect(input.reach, UnattendedReach.reachable);
  });
}
