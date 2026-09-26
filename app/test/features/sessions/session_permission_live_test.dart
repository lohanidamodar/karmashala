import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/sessions/application/pending_live_switches.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_working_directory.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';
import '../terminal/fake_instance.dart';

/// A running session's permission mode is moved in place where the agent
/// allows it, read back off its own screen, and never pressed into a busy pane.
class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  var status = AgentActivityStatus.idle;
  late StreamController<String> idle;
  late FakeDataServer server;

  setUp(() {
    status = AgentActivityStatus.idle;
    idle = StreamController<String>.broadcast();
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
  });

  tearDown(() async {
    container.dispose();
    db.close();
    await idle.close();
  });

  Future<ProviderContainer> build(String agentId) async {
    server.installationRows.insert(agentInstallation(agentId: agentId));
    return container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
        agentRegistryProvider.overrideWithValue(AgentRegistry.builtIn),
        settingsControllerProvider.overrideWith(_StaticSettings.new),
        sessionActivityLookupProvider.overrideWithValue((_) => status),
        sessionDirectoryPresentProvider.overrideWithValue((_) => true),
        pendingLiveSwitchesProvider.overrideWith(
          (ref) => PendingLiveSwitches(ref, idle.stream),
        ),
        conversationPresenceProvider.overrideWithValue(
          ({
            required descriptor,
            required environmentId,
            required conversationId,
          }) async => ConversationPresence.present,
        ),
      ],
    );
  }

  /// Launches a session and stands in for the agent: each Shift+Tab redraws
  /// the status line with the next mode of Claude Code's own cycle, after
  /// [redrawAfter] — or never, when it is null.
  Future<({String id, List<String> keys})> launched(
    String agentId, {
    List<String> cycle = const ['manual', 'acceptEdits', 'plan', 'auto'],
    Duration? redrawAfter = Duration.zero,
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
    final terminal = container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(result.paneId!)!
        .terminal;
    // Claude Code 2.1.280's own lines, read off a host recording.
    const words = {
      'manual': '⏸ manual mode on · esc to interrupt · ← for agents',
      'acceptEdits': '⏵⏵ accept edits on (shift+tab to cycle) · ← for agents',
      'plan': '⏸ plan mode on (shift+tab to cycle) · ← for agents',
      'auto': '⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt',
    };
    var at = 0;
    void draw() => terminal.write(
      '\x1b[2J\x1b[H> \r\n${words[cycle[at]] ?? '? for shortcuts'}\r\n',
    );
    draw();
    final keys = <String>[];
    terminal.onOutput = (data) {
      keys.add(data);
      if (data == '\x1b[Z' && redrawAfter != null) {
        at = (at + 1) % cycle.length;
        if (redrawAfter == Duration.zero) {
          draw();
        } else {
          Timer(redrawAfter, draw);
        }
      }
    };
    return (id: result.session.id, keys: keys);
  }

  void choose(String sessionId, String mode) => container
      .read(sessionLauncherProvider)
      .setPermissionMode(sessionId, PermissionSelection({'mode': mode}));

  test(
    'idle: stepped to the mode asked for, read back off the screen',
    () async {
      await build(AgentIds.claudeCode);
      final session = await launched(AgentIds.claudeCode);
      choose(session.id, 'plan');

      final outcome = await container
          .read(sessionLauncherProvider)
          .switchPermissionLive(session.id, settle: Duration.zero);

      expect(outcome, LivePermissionOutcome.switched);
      expect(session.keys, ['\x1b[Z', '\x1b[Z']);
    },
  );

  test('a mode this session does not offer comes round and says so', () async {
    await build(AgentIds.claudeCode);
    // Launched without auto available: the cycle skips it.
    final session = await launched(
      AgentIds.claudeCode,
      cycle: const ['manual', 'acceptEdits', 'plan'],
    );
    choose(session.id, 'auto');

    final outcome = await container
        .read(sessionLauncherProvider)
        .switchPermissionLive(session.id, settle: Duration.zero);

    expect(outcome, LivePermissionOutcome.notOffered);
    expect(session.keys, hasLength(3), reason: 'left where it was found');
  });

  test(
    'mid-turn: switched at once, since the key works while it works',
    () async {
      await build(AgentIds.claudeCode);
      final session = await launched(AgentIds.claudeCode);
      status = AgentActivityStatus.working;
      choose(session.id, 'plan');

      final outcome = await container
          .read(sessionLauncherProvider)
          .switchPermissionLive(session.id, settle: Duration.zero);

      expect(outcome, LivePermissionOutcome.switched);
      expect(session.keys, ['\x1b[Z', '\x1b[Z']);
    },
  );

  test('a slow redraw is waited for, not read as a lap', () async {
    await build(AgentIds.claudeCode);
    final session = await launched(
      AgentIds.claudeCode,
      redrawAfter: const Duration(milliseconds: 150),
    );
    choose(session.id, 'plan');

    final outcome = await container
        .read(sessionLauncherProvider)
        .switchPermissionLive(session.id, settle: const Duration(seconds: 1));

    expect(outcome, LivePermissionOutcome.switched);
    expect(session.keys, ['\x1b[Z', '\x1b[Z']);
  });

  test('a screen that never redraws is pressed once, and said so', () async {
    await build(AgentIds.claudeCode);
    final session = await launched(AgentIds.claudeCode, redrawAfter: null);
    choose(session.id, 'plan');

    final outcome = await container
        .read(sessionLauncherProvider)
        .switchPermissionLive(
          session.id,
          settle: const Duration(milliseconds: 100),
        );

    expect(outcome, LivePermissionOutcome.noAnswer);
    expect(session.keys, ['\x1b[Z']);
  });

  test('an open prompt: nothing is pressed until it is idle', () async {
    await build(AgentIds.claudeCode);
    final session = await launched(AgentIds.claudeCode);
    container.read(pendingLiveSwitchesProvider);
    status = AgentActivityStatus.awaitingApproval;
    choose(session.id, 'acceptEdits');

    final outcome = await container
        .read(sessionLauncherProvider)
        .switchPermissionLive(session.id, settle: Duration.zero);
    expect(outcome, LivePermissionOutcome.held);
    expect(session.keys, isEmpty);

    status = AgentActivityStatus.idle;
    idle.add(session.id);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(session.keys, ['\x1b[Z']);
  });

  test('a mode outside the cycle waits for the next launch', () async {
    await build(AgentIds.claudeCode);
    final session = await launched(AgentIds.claudeCode);
    choose(session.id, 'dontAsk');

    final outcome = await container
        .read(sessionLauncherProvider)
        .switchPermissionLive(session.id, settle: Duration.zero);

    expect(outcome, LivePermissionOutcome.nextLaunch);
    expect(session.keys, isEmpty);
  });

  test('Codex: its own permission picker is opened in the pane', () async {
    await build(AgentIds.codex);
    final session = await launched(AgentIds.codex);

    final outcome = await container
        .read(sessionLauncherProvider)
        .switchPermissionLive(session.id, settle: Duration.zero);

    expect(outcome, LivePermissionOutcome.openedPicker);
    expect(session.keys.join(), contains('/permissions'));
  });

  test('the cycle reads the mode the screen draws', () {
    final live = AgentRegistry.builtIn
        .byId(AgentIds.claudeCode)!
        .launch
        .permission
        .live!;
    expect(live.read(['⏸ plan mode on (shift+tab to cycle)']), 'plan');
    expect(live.read(['? for shortcuts']), 'manual');
    expect(live.read(['⏸ manual mode on · esc to interrupt']), 'manual');
    expect(live.read(['⏵⏵ auto mode on']), 'auto');
  });
}
