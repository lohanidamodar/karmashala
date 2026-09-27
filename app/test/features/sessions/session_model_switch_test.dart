import 'dart:async';

import 'package:karmashala_terminal_core/grid.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/sessions/application/pending_live_switches.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_working_directory.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';

/// **Live where supported, next launch otherwise — and never into a busy pane.**
///
/// The gate this file exists for is the second half of that sentence. A
/// `/model` typed mid-turn is not a harmless no-op: the line lands in whatever
/// is reading input, which is the user's own conversation. So the interesting
/// assertions here are the ones where *nothing* was written.
///
/// A fake pane throughout: `FakeTerminalInstance` owns a real `xterm` terminal
/// with no process behind it, so what the launcher writes is observable through
/// `onOutput` without a CLI ever being driven.
class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);
  final Settings _settings;

  @override
  Settings build() => _settings;
}

Future<({ProviderContainer container, TestMachine db, FakeDataServer server})>
harness({
  String agentId = AgentIds.claudeCode,
  AgentActivityStatus status = AgentActivityStatus.idle,
  AgentActivityStatus Function()? statusNow,
  Stream<String>? becameIdle,
}) async {
  final db = TestMachine();
  final server = FakeDataServer()..runsOn(db);
  server.environmentRows.upsert(windowsEnv());
  server.projectRows.insert(project());
  server.repositoryRows.insert(repository());
  server.installationRows.insert(agentInstallation(agentId: agentId));
  final container = ProviderContainer(
    overrides: [
      await server.override(),
      ...fakeTerminalOverrides(machine: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      agentRegistryProvider.overrideWithValue(AgentRegistry.builtIn),
      settingsControllerProvider.overrideWith(
        () => _StaticSettings(const Settings()),
      ),
      // The status seam. Standing up the real registry would mean a status
      // pipeline, a store scan and a timer to assert one boolean.
      sessionActivityLookupProvider.overrideWithValue(
        (_) => statusNow?.call() ?? status,
      ),
      pendingLiveSwitchesProvider.overrideWith(
        (ref) => PendingLiveSwitches(ref, becameIdle ?? const Stream.empty()),
      ),
      sessionDirectoryPresentProvider.overrideWithValue((_) => true),
      // A resume refuses when the CLI has no record of the conversation, and
      // nothing here writes a real transcript. The question this file asks is
      // what the *arguments* carry, so the presence probe is answered rather
      // than exercised.
      conversationPresenceProvider.overrideWithValue(
        ({
          required descriptor,
          required environmentId,
          required conversationId,
        }) async => ConversationPresence.present,
      ),
    ],
  );
  return (container: container, db: db, server: server);
}

Future<({String id, List<String> written})> launched(
  ProviderContainer container, {
  String agentId = AgentIds.claudeCode,
}) async {
  final result = await container
      .read(sessionLauncherProvider)
      .launch(
        SessionLaunchRequest(
          repository: repository(),
          installation: agentInstallation(agentId: agentId),
          title: 'Session',
          purpose: SessionPurpose.newSession,
        ),
      );
  final instance = container
      .read(terminalSessionsControllerProvider.notifier)
      .instanceFor(result.paneId!)!;
  final written = <String>[];
  instance.terminal.onOutput = written.add;
  return (id: result.session.id, written: written);
}

void main() {
  test(
    'idle and slash-capable: the command is sent and the row is written',
    () async {
      final h = await harness();
      addTearDown(h.container.dispose);
      final session = await launched(h.container);

      final outcome = h.container
          .read(sessionLauncherProvider)
          .setModel(session.id, 'opus');

      expect(outcome.switchedNow, isTrue);
      expect(outcome.command, '/model opus');
      expect(outcome.deferral, isNull);
      // The command, then the keypress and carriage return that submit it — a
      // slash command goes through `sendTo` and is typed exactly like a message.
      expect(session.written, ['/model opus', kEndOfLineKey, '\r']);
      // And it persists, so the next launch agrees with what was just typed.
      expect(
        h.container.read(sessionsDataProvider).getById(session.id)!.modelId,
        'opus',
      );
    },
  );

  test(
    'working: nothing is typed, and the override is still recorded',
    () async {
      final h = await harness(status: AgentActivityStatus.working);
      addTearDown(h.container.dispose);
      final session = await launched(h.container);

      final outcome = h.container
          .read(sessionLauncherProvider)
          .setModel(session.id, 'opus');

      expect(outcome.switchedNow, isFalse);
      expect(outcome.deferral, ModelDeferral.busy);
      expect(outcome.command, isNull);
      expect(
        session.written,
        isEmpty,
        reason: 'mid-turn the line lands in the user\'s own conversation',
      );
      expect(
        h.container.read(sessionsDataProvider).getById(session.id)!.modelId,
        'opus',
      );
    },
  );

  test('a state no source can vouch for counts as busy', () async {
    // `unknown` is the ordinary answer for a session with no hooks, and a key
    // we are not sure lands at a prompt is a key we do not send.
    final h = await harness(status: AgentActivityStatus.unknown);
    addTearDown(h.container.dispose);
    final session = await launched(h.container);

    final outcome = h.container
        .read(sessionLauncherProvider)
        .setModel(session.id, 'opus');

    expect(outcome.deferral, ModelDeferral.busy);
    expect(session.written, isEmpty);
  });

  test(
    'just resumed, no hook yet: the agent\'s own idle footer is enough',
    () async {
      final h = await harness(status: AgentActivityStatus.unknown);
      addTearDown(h.container.dispose);
      final session = await launched(h.container);
      final paneId = h.container
          .read(sessionsDataProvider)
          .getById(session.id)!
          .paneId!;
      h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(paneId)!
          .terminal
          .write('> \r\n  ⏸ manual mode on\r\n');

      final outcome = h.container
          .read(sessionLauncherProvider)
          .setModel(session.id, 'opus');

      expect(outcome.switchedNow, isTrue);
      expect(session.written.join(), contains('/model opus'));
    },
  );

  test('just resumed, mid-turn on screen: still nothing is typed', () async {
    final h = await harness(status: AgentActivityStatus.unknown);
    addTearDown(h.container.dispose);
    final session = await launched(h.container);
    final paneId = h.container
        .read(sessionsDataProvider)
        .getById(session.id)!
        .paneId!;
    h.container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId)!
        .terminal
        .write('✻ Thinking…\r\n  ⏸ manual mode on · esc to interrupt\r\n');

    final outcome = h.container
        .read(sessionLauncherProvider)
        .setModel(session.id, 'opus');

    expect(outcome.deferral, ModelDeferral.busy);
    expect(session.written, isEmpty);
  });

  test('an open prompt is not typed into either', () async {
    final h = await harness(status: AgentActivityStatus.awaitingApproval);
    addTearDown(h.container.dispose);
    final session = await launched(h.container);

    expect(
      h.container.read(sessionLauncherProvider).setModel(session.id, 'opus'),
      (switchedNow: false, command: null, deferral: ModelDeferral.busy),
    );
    expect(session.written, isEmpty);
  });

  test(
    'Codex, idle: its own picker is opened, since /model takes no argument',
    () async {
      final h = await harness(agentId: AgentIds.codex);
      addTearDown(h.container.dispose);
      final session = await launched(h.container, agentId: AgentIds.codex);

      final outcome = h.container
          .read(sessionLauncherProvider)
          .setModel(session.id, 'gpt-5.5');

      expect(outcome.switchedNow, isFalse);
      expect(outcome.deferral, ModelDeferral.openedPicker);
      expect(outcome.command, '/model');
      expect(session.written.join(), contains('/model'));
      expect(
        h.container.read(sessionsDataProvider).getById(session.id)!.modelId,
        'gpt-5.5',
      );
    },
  );

  test('Codex mid-turn: nothing is typed, not even the picker', () async {
    final h = await harness(
      agentId: AgentIds.codex,
      status: AgentActivityStatus.working,
    );
    addTearDown(h.container.dispose);
    final session = await launched(h.container, agentId: AgentIds.codex);

    final outcome = h.container
        .read(sessionLauncherProvider)
        .setModel(session.id, 'gpt-5.5');

    expect(outcome.deferral, ModelDeferral.noCommand);
    expect(session.written, isEmpty);
  });

  test('a pick made mid-turn is sent the moment the turn ends', () async {
    var status = AgentActivityStatus.working;
    final idle = StreamController<String>.broadcast();
    addTearDown(idle.close);
    final h = await harness(statusNow: () => status, becameIdle: idle.stream);
    addTearDown(h.container.dispose);
    final session = await launched(h.container);
    h.container.read(pendingLiveSwitchesProvider);

    final outcome = h.container
        .read(sessionLauncherProvider)
        .setModel(session.id, 'opus');
    expect(outcome.deferral, ModelDeferral.busy);
    expect(session.written, isEmpty);
    expect(
      h.container.read(pendingLiveSwitchesProvider).holds(session.id),
      isTrue,
    );

    status = AgentActivityStatus.idle;
    idle.add(session.id);
    await Future<void>.delayed(Duration.zero);

    expect(session.written.join(), contains('/model opus'));
    expect(
      h.container.read(pendingLiveSwitchesProvider).holds(session.id),
      isFalse,
    );
  });

  test('a session nothing is running is deferred, not refused', () async {
    final h = await harness();
    addTearDown(h.container.dispose);
    final session = await launched(h.container);
    // The pane exits: the row is still there and still ours to configure.
    final paneId = h.container
        .read(sessionsDataProvider)
        .getById(session.id)!
        .paneId!;
    (h.container
                .read(terminalSessionsControllerProvider.notifier)
                .instanceFor(paneId)!
            as FakeTerminalInstance)
        .exitCleanly();

    final outcome = h.container
        .read(sessionLauncherProvider)
        .setModel(session.id, 'opus');

    expect(outcome.deferral, ModelDeferral.notRunning);
    expect(session.written, isEmpty);
    expect(
      h.container.read(sessionsDataProvider).getById(session.id)!.modelId,
      'opus',
    );
  });

  test('handing the session back to the default clears the row', () async {
    final h = await harness();
    addTearDown(h.container.dispose);
    final session = await launched(h.container);
    final launcher = h.container.read(sessionLauncherProvider);
    launcher.setModel(session.id, 'opus');
    session.written.clear();

    final outcome = launcher.setModel(session.id, null);

    // Nothing to switch *to*, so nothing is typed — and the row is empty
    // again, which is the state a session that never chose is in.
    expect(outcome.switchedNow, isFalse);
    expect(outcome.deferral, ModelDeferral.noModel);
    expect(session.written, isEmpty);
    expect(
      h.container.read(sessionsDataProvider).getById(session.id)!.modelId,
      isNull,
    );
    expect(launcher.effectiveModelFor(session.id)!.modelId, isNull);
    expect(launcher.effectiveModelFor(session.id)!.inherited, isTrue);
  });

  test('a session that never chose passes no model flag at all', () async {
    final h = await harness();
    addTearDown(h.container.dispose);
    final result = await h.container
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository(),
            installation: agentInstallation(agentId: AgentIds.claudeCode),
            title: 'Session',
            purpose: SessionPurpose.newSession,
          ),
        );
    final arguments = h.container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(result.paneId!)!
        .agentLaunch!
        .arguments;
    expect(arguments, isNot(contains('--model')));
  });
}
