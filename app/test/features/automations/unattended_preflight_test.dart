import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/automations/application/automation_providers.dart';
import 'package:karmashala/src/features/automations/application/unattended_preflight.dart';
import 'package:karmashala_automations/persistence.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/unattended.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';

/// The lookup half of the gate, against the app's own tables.
///
/// The rules are pinned by `unattended_gate_test.dart`; what these hold is that
/// the *right* facts reach them — that "verification is on" reads the checkout
/// the automation names, that the mode's rung comes from the agent's own
/// declared axes, and that the environment answer is the resolver's, in the
/// resolver's own words.
void main() {
  late FakeDataServer server;
  late DataClient client;
  late AppDatabase db;
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

  void makeReady() {
    final checks = container.read(projectCheckDaoProvider);
    checks.setVerificationEnabled('r1', enabled: true, now: testTime);
    container.read(automationControllerProvider).addCheck(
      'r1',
      'the test suite',
      const ['flutter', 'test'],
    );
  }

  ProviderContainer build({List<Override> extra = const []}) =>
      ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          dataClientProvider.overrideWithValue(client),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator('c-')),
          ...extra,
        ],
      );

  setUp(() async {
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    client = await server.connect();
    server.installationRows.insert(agentInstallation(agentId: AgentIds.claudeCode));
    AutomationDao(db).insert(automation());
    container = build();
    addTearDown(container.dispose);
    addTearDown(db.close);
  });

  group('verification, read off the checkout the automation names', () {
    test('a checkout nobody configured is refused', () {
      final refusal = refusalFor(automation())!;
      expect(refusal.kind, UnattendedRefusalKind.verificationDisabled);
      expect(refusal.reason, contains('Verification is off for app'));
    });

    test('verification on with no check is still refused', () {
      container
          .read(projectCheckDaoProvider)
          .setVerificationEnabled('r1', enabled: true, now: testTime);
      expect(
        refusalFor(automation())!.kind,
        UnattendedRefusalKind.noProjectChecks,
      );
    });

    test('on, with one check, is not refused', () {
      makeReady();
      expect(refusalFor(automation()), isNull);
    });

    test('another checkout\'s checks do not count for this one', () async {
      server.repositoryRows.insert(repository(id: 'r2', name: 'other'));
      await pumpEventQueue();
      makeReady();
      final elsewhere = refusalFor(automation(repositoryId: 'r2'))!;
      expect(elsewhere.kind, UnattendedRefusalKind.verificationDisabled);
      expect(elsewhere.reason, contains('other'));
    });

    test('a check deleted after arming lapses the automation', () {
      makeReady();
      expect(refusalFor(automation()), isNull);
      final check = container
          .read(projectCheckDaoProvider)
          .forRepository('r1')
          .single;
      container.read(automationControllerProvider).removeCheck(check.id);
      // The fire is the moment that matters, not the arming.
      expect(
        refusalFor(automation())!.kind,
        UnattendedRefusalKind.noProjectChecks,
      );
    });
  });

  group('the mode comes from the agent\'s own declared axes', () {
    setUp(makeReady);

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
      container
          .read(projectCheckDaoProvider)
          .setVerificationEnabled('r2', enabled: true, now: testTime);
      container.read(automationControllerProvider).addCheck(
        'r2',
        'the test suite',
        const ['flutter', 'test'],
      );

      final refusal = refusalFor(automation(repositoryId: 'r2'))!;
      expect(refusal.kind, UnattendedRefusalKind.environmentUnreachable);
      expect(refusal.reason, contains('No SSH connection pool is configured'));
      expect(refusal.reason, contains('cannot be armed'));
    });

    test('a checkout that left the workspace is refused at the first rule', () {
      makeReady();
      // The order is deliberate: a checkout that is gone verifies nothing, and
      // that is the sentence a person can act on. The environment rule is
      // behind it and never reached here.
      final refusal = refusalFor(automation(repositoryId: 'gone'))!;
      expect(refusal.kind, UnattendedRefusalKind.verificationDisabled);
      expect(refusal.reason, contains('this checkout'));
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
        container
            .read(projectCheckDaoProvider)
            .setVerificationEnabled('r3', enabled: true, now: testTime);
        container.read(automationControllerProvider).addCheck(
          'r3',
          'the test suite',
          const ['flutter', 'test'],
        );
        final refusal = refusalFor(automation(repositoryId: 'r3'))!;
        expect(refusal.kind, UnattendedRefusalKind.environmentUnnamed);
        expect(refusal.reason, contains('has no distribution name'));
      },
    );
  });

  test('the gate\'s inputs are the app\'s own facts, not defaults', () {
    makeReady();
    final input = container
        .read(unattendedPreflightProvider)
        .inputFor(automation());
    expect(input.repositoryName, 'app');
    expect(input.verificationEnabled, isTrue);
    expect(input.projectCheckCount, 1);
    expect(input.agentName, 'Claude Code');
    expect(input.agentInstalled, isTrue);
    expect(input.permits, PermissionRisk.autoRun);
    expect(input.permissionLabel, 'Automatic');
    expect(input.permissionEvidence, isNotEmpty);
    expect(input.reach, UnattendedReach.reachable);
  });
}
