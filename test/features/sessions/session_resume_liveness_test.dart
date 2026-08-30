import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/core/util/id_generator_provider.dart';
import 'package:chitragupta/src/features/agents/application/agent_providers.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:chitragupta/src/features/cli_detection/domain/imported_session.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/session_actions.dart';
import 'package:chitragupta/src/features/sessions/application/session_launcher.dart';
import 'package:chitragupta/src/features/sessions/application/session_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_ui_providers.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session_launch.dart';
import 'package:chitragupta/src/features/settings/application/settings_controller.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:chitragupta/src/features/settings/domain/settings.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// A resumable agent. Codex is the one that actually refuses a second writer,
/// but nothing here depends on which CLI it is: the guard is about *our*
/// knowledge of what is running, not about parsing an agent's error.
const _codexish = AgentDescriptor(
  id: 'codexish',
  displayName: 'Codexish',
  binaries: AgentBinaries(windows: ['codexish'], posix: ['codexish']),
  launch: AgentLaunchSpec(
    permissionModes: {
      PermissionMode.ask: PermissionModeMapping.exact(['--ask']),
    },
    interactiveResume: AgentResume.subcommand('resume'),
  ),
);

({ProviderContainer container, AppDatabase db}) harness() {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  AgentInstallationDao(db).insert(agentInstallation(agentId: 'codexish'));

  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      agentRegistryProvider.overrideWithValue(const AgentRegistry([_codexish])),
      settingsControllerProvider.overrideWith(_StaticSettings.new),
    ],
  );
  return (container: container, db: db);
}

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

/// Starts a session in a pane and pins its CLI id, which is the join the guard
/// uses between an imported entry and one of our rows.
Future<String> _startLiveSession(
  ProviderContainer container, {
  String externalId = 'ext-1',
}) async {
  final launched = await container
      .read(sessionLauncherProvider)
      .launch(
        SessionLaunchRequest(
          repository: repository(),
          installation: agentInstallation(agentId: 'codexish'),
          title: 'Live work',
          purpose: SessionPurpose.newSession,
        ),
      );
  container
      .read(sessionDaoProvider)
      .updateExternalSessionId(launched.session.id, externalId);
  return launched.session.id;
}

ImportedSession _imported({String externalId = 'ext-1'}) => ImportedSession(
  id: 'i1',
  repositoryId: 'r1',
  cli: 'codexish',
  externalId: externalId,
  environmentId: 'windows',
  filePath: '/home/dlohani/.codex/sessions/2026/08/30/rollout-ext-1.jsonl',
  storeHome: '/home/dlohani/.codex',
  isSubagent: false,
  preview: 'earlier work',
  createdAt: testTime,
);

void main() {
  test('resuming a session that never stopped reopens it, and launches '
      'nothing', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);

    final liveId = await _startLiveSession(h.container);
    ImportedSessionDao(h.db).insertIfAbsent(_imported());

    final resumed = await h.container
        .read(sessionActionsProvider)
        .resumeImported(_imported());

    // The same session, not a second one on the same conversation.
    expect(resumed, liveId);
    expect(SessionDao(h.db).getByRepository('r1'), hasLength(1));
    // And it is on screen: selected, with the terminal shown.
    expect(h.container.read(selectedSessionIdProvider), liveId);
    expect(h.container.read(terminalVisibleProvider), isTrue);
    // The imported entry was a duplicate record of a session we own.
    expect(ImportedSessionDao(h.db).getById('i1'), isNull);
  });

  test('a detached session is reattached rather than relaunched', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);

    final liveId = await _startLiveSession(h.container);
    final terminals = h.container.read(
      terminalSessionsControllerProvider.notifier,
    );
    // Closing the tab is a view action: Loop 38 leaves the process running.
    terminals.closeTab(
      h.container.read(terminalSessionsControllerProvider).tabs.single.id,
    );
    expect(
      h.container.read(terminalSessionsControllerProvider).detached,
      hasLength(1),
    );

    final resumed = await h.container
        .read(sessionActionsProvider)
        .resumeImported(_imported());

    expect(resumed, liveId);
    expect(SessionDao(h.db).getByRepository('r1'), hasLength(1));
    // The view came back; the session was never recreated.
    final state = h.container.read(terminalSessionsControllerProvider);
    expect(state.detached, isEmpty);
    expect(state.tabs, hasLength(1));
  });

  test('a session whose process has ended is genuinely resumed', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);

    final liveId = await _startLiveSession(h.container);
    final paneId = SessionDao(h.db).getById(liveId)!.paneId!;
    h.container
        .read(terminalSessionsControllerProvider.notifier)
        .endSession(paneId);

    final resumed = await h.container
        .read(sessionActionsProvider)
        .resumeImported(_imported());

    // Nothing is running it any more, so a new agent is exactly right.
    expect(resumed, isNot(liveId));
    expect(SessionDao(h.db).getByRepository('r1'), hasLength(2));
    final launch = h.container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(SessionDao(h.db).getById(resumed)!.paneId!)!
        .agentLaunch!;
    expect(launch.arguments, ['--ask', 'resume', 'ext-1']);
  });

  test(
    'the launcher itself refuses a second writer, and writes no row',
    () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await _startLiveSession(h.container);

      await expectLater(
        h.container
            .read(sessionLauncherProvider)
            .launch(
              SessionLaunchRequest(
                repository: repository(),
                installation: agentInstallation(agentId: 'codexish'),
                title: 'Second writer',
                purpose: SessionPurpose.existingSession,
                resumeExternalSessionId: 'ext-1',
              ),
            ),
        throwsA(isA<SessionAlreadyRunning>()),
      );
      // The refusal happens before anything is created — no orphan row, no pane.
      expect(SessionDao(h.db).getByRepository('r1'), hasLength(1));
    },
  );

  test(
    'handing a running session to an external terminal is refused, legibly',
    () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final liveId = await _startLiveSession(h.container);
      final actions = h.container.read(sessionActionsProvider);
      const terminal = SystemTerminal(
        kind: SystemTerminalKind.windowsTerminal,
        label: 'Windows Terminal',
        executable: 'wt.exe',
      );

      await expectLater(
        actions.openSessionInSystemTerminal(liveId, terminal),
        throwsA(
          isA<SessionAlreadyRunning>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('already running'), contains('Live work')),
          ),
        ),
      );
      await expectLater(
        actions.openInSystemTerminal(_imported(), terminal),
        throwsA(isA<SessionAlreadyRunning>()),
      );
    },
  );

  test('an unrelated conversation is unaffected by a live one', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);

    await _startLiveSession(h.container);
    final launcher = h.container.read(sessionLauncherProvider);

    expect(launcher.runningSessionWithExternalId('someone-else'), isNull);
    expect(launcher.runningSessionWithExternalId(null), isNull);
    expect(launcher.runningSessionWithExternalId(''), isNull);
    expect(launcher.reveal('no-such-session'), isFalse);
  });
}
