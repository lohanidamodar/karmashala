import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/domain/session_launch.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/features/terminal/domain/pane_liveness.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';
import '../terminal/fake_instance.dart';

/// One session, one terminal — across a restart too.
///
/// `SessionLauncher.livePaneFor` and `sessionTerminalPane` used to disagree
/// about what "has a pane" means. The launcher required a *live* instance, so
/// `reveal` refused a pane restored from disk and the resume opened a second
/// tab; the workbench required only an instance, so it happily showed the first
/// one. The user got two terminals for one session, one of them dead.
///
/// Both halves of that disagreement were protecting something real: a pane that
/// ran and died must never be reattached and presented as a running session,
/// and a restored pane is the session's own scrollback. These tests pin the
/// resolution — a **dormant** pane is resumed *into*, an **exited** one is not.

const _sharing = AgentDescriptor(
  id: 'sharing',
  displayName: 'Sharing Agent',
  binaries: AgentBinaries(windows: ['sharing'], posix: ['sharing']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    interactiveResume: AgentResume.flag('--resume'),
    // So a session started with an opening prompt records that prompt, which
    // is what pressing Start used to run a second time.
    prompt: AgentPromptSupport.positional(),
    allowsConcurrentResume: true,
  ),
);

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

AppDatabase seededDatabase() {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  AgentInstallationDao(db).insert(agentInstallation(agentId: 'sharing'));
  return db;
}

/// A container over [db]. The id prefix is a parameter because a second
/// container over the same database is what a restart *is*, and two generators
/// counting from zero would hand out ids the first run already used.
ProviderContainer containerOver(AppDatabase db, {String idPrefix = 's-'}) =>
    ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator(idPrefix)),
        agentRegistryProvider.overrideWithValue(const AgentRegistry([_sharing])),
        settingsControllerProvider.overrideWith(_StaticSettings.new),
        // The whereabouts provider watches this for a "last seen" time; a real
        // poll would leave an autoDispose stream mid-flight. Nothing here is
        // about ageing evidence.
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
      ],
    );

/// Starts a session in a pane and pins the CLI id a resume needs.
Future<String> startSession(
  ProviderContainer container, {
  String externalId = 'ext-1',
  String? firstMessage,
}) async {
  final launched = await container
      .read(sessionLauncherProvider)
      .launch(
        SessionLaunchRequest(
          repository: repository(),
          installation: agentInstallation(agentId: 'sharing'),
          title: 'Earlier work',
          purpose: SessionPurpose.newSession,
          firstMessage: firstMessage,
        ),
      );
  container
      .read(sessionDaoProvider)
      .updateExternalSessionId(launched.session.id, externalId);
  return launched.session.id;
}

String paneOf(ProviderContainer container, String sessionId) =>
    container.read(sessionDaoProvider).getById(sessionId)!.paneId!;

void main() {
  test('a session restored from disk resumes in the pane it came back in, '
      'not beside it', () async {
    final db = seededDatabase();
    addTearDown(db.close);

    final first = containerOver(db);
    final sessionId = await startSession(first);
    final paneId = paneOf(first, sessionId);
    first
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId)!
        .terminal
        .write('what happened yesterday\r\n');
    first.read(terminalSessionsControllerProvider.notifier).persistLayout();
    first.dispose();

    // The restart. The pane comes back holding its scrollback with nothing
    // running behind it, and the row still names it.
    final next = containerOver(db, idPrefix: 't-');
    addTearDown(next.dispose);
    expect(
      next.read(terminalSessionsControllerProvider).livenessOf(paneId),
      PaneLiveness.restored,
    );
    expect(next.read(terminalSessionsControllerProvider).tabs, hasLength(1));

    final result = await next
        .read(explorerActionsProvider)
        .openNative(sessionId);

    expect(result.outcome, ExplorerOutcome.resumed);
    final state = next.read(terminalSessionsControllerProvider);
    expect(
      state.tabs,
      hasLength(1),
      reason: 'one session, one terminal — the dormant pane *is* the terminal',
    );
    expect(state.tabs.single.layout.panes, [paneId]);
    expect(state.livenessOf(paneId), PaneLiveness.live);
    expect(next.read(sessionDaoProvider).getById(sessionId)!.paneId, paneId);

    final started =
        next
                .read(terminalSessionsControllerProvider.notifier)
                .instanceFor(paneId)!
            as FakeTerminalInstance;
    // The agent was resumed, not started afresh…
    expect(started.agentLaunch!.arguments, contains('--resume'));
    expect(started.agentLaunch!.arguments, contains('ext-1'));
    // …and the buffer that was the whole reason to keep the pane survived it.
    expect(started.restored, contains('what happened yesterday'));
  });

  test('a session whose pane ran and died is resumed in a pane of its '
      'own', () async {
    // The distinction `livePaneFor` was right to make, kept: an exited pane
    // belongs to *this* run of the app, its buffer has moved on since anything
    // was restored into it, and it is a record of a process that failed or was
    // ended rather than history waiting to be continued.
    final db = seededDatabase();
    addTearDown(db.close);
    final container = containerOver(db);
    addTearDown(container.dispose);

    final sessionId = await startSession(container);
    final paneId = paneOf(container, sessionId);
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    (terminals.instanceFor(paneId)! as FakeTerminalInstance).exitCleanly();
    expect(
      container.read(terminalSessionsControllerProvider).livenessOf(paneId),
      PaneLiveness.exited,
    );

    final result = await container
        .read(explorerActionsProvider)
        .openNative(sessionId);

    expect(result.outcome, ExplorerOutcome.resumed);
    final state = container.read(terminalSessionsControllerProvider);
    expect(state.tabs, hasLength(2));
    expect(
      container.read(sessionDaoProvider).getById(sessionId)!.paneId,
      isNot(paneId),
    );
  });

  test('a session with no pane at all still gets one', () async {
    final db = seededDatabase();
    addTearDown(db.close);
    final container = containerOver(db);
    addTearDown(container.dispose);

    final sessionId = await startSession(container);
    // Ending the session takes its pane away; the row keeps the stale id, which
    // is the case `dormantPaneFor` must not answer with.
    final paneId = paneOf(container, sessionId);
    container.read(terminalSessionsControllerProvider.notifier).endSession(
      paneId,
    );
    expect(
      container.read(terminalSessionsControllerProvider).tabs,
      isEmpty,
    );

    final result = await container
        .read(explorerActionsProvider)
        .openNative(sessionId);

    expect(result.outcome, ExplorerOutcome.resumed);
    expect(
      container.read(terminalSessionsControllerProvider).tabs,
      hasLength(1),
    );
  });

  test('a dormant pane is not a running session', () async {
    // The property `livePaneFor` exists to hold, restated as the thing that
    // must not change: the double-writer refusal, the archive guard and the
    // permission chip all read it, and a restored pane is not a process.
    final db = seededDatabase();
    addTearDown(db.close);

    final first = containerOver(db);
    final sessionId = await startSession(first);
    first.read(terminalSessionsControllerProvider.notifier).persistLayout();
    first.dispose();

    final next = containerOver(db, idPrefix: 't-');
    addTearDown(next.dispose);
    final launcher = next.read(sessionLauncherProvider);

    expect(launcher.livePaneFor(sessionId), isNull);
    expect(launcher.hostedLive(sessionId: sessionId), isFalse);
    expect(launcher.reveal(sessionId), isFalse);
    // But it is a pane, and it is this session's.
    expect(launcher.dormantPaneFor(sessionId), paneOf(next, sessionId));
  });

  /// The button on the pane itself.
  ///
  /// Everything above resumes from a *session* — a row clicked in the Explorer,
  /// a name picked in quick open. The pane bar asks the same question from the
  /// other end ("this terminal, whatever it is holding") and used to answer it
  /// with `startPane`, which re-executes the recorded command line. For a
  /// session first launched with an opening prompt that is the prompt again: a
  /// new conversation, a turn spent, tools run, while the transcript the user
  /// came back for stays on disk.
  group('the pane bar', () {
    test('resumes a restored agent pane instead of running its opening '
        'prompt again', () async {
      final db = seededDatabase();
      addTearDown(db.close);

      final first = containerOver(db);
      final sessionId = await startSession(
        first,
        firstMessage: 'summarise yesterday',
      );
      final paneId = paneOf(first, sessionId);
      final terminals = first.read(
        terminalSessionsControllerProvider.notifier,
      );
      expect(
        terminals.instanceFor(paneId)!.agentLaunch!.arguments,
        contains('summarise yesterday'),
        reason: 'the recorded line is the one Start used to re-run',
      );
      terminals.instanceFor(paneId)!.terminal.write('what happened\r\n');
      terminals.persistLayout();
      first.dispose();

      final next = containerOver(db, idPrefix: 't-');
      addTearDown(next.dispose);
      expect(
        next.read(terminalSessionsControllerProvider).livenessOf(paneId),
        PaneLiveness.restored,
      );

      final result = await next
          .read(explorerActionsProvider)
          .resumeRestoredPane(paneId);

      expect(result.outcome, ExplorerOutcome.resumed);
      final started =
          next
                  .read(terminalSessionsControllerProvider.notifier)
                  .instanceFor(paneId)!
              as FakeTerminalInstance;
      expect(started.agentLaunch!.arguments, containsAllInOrder([
        '--resume',
        'ext-1',
      ]));
      expect(
        started.agentLaunch!.arguments,
        isNot(contains('summarise yesterday')),
        reason:
            'this is the whole bug: the opening prompt is not something to '
            'run again on the way back into a conversation',
      );
      // And the pane the resume was looking for is the pane it ran in, so the
      // user still has one terminal for one session.
      expect(
        next.read(terminalSessionsControllerProvider).tabs.single.layout.panes,
        [paneId],
      );
      expect(started.restored, contains('what happened'));
    });

    test('says so when the pane is not one of our sessions', () async {
      final db = seededDatabase();
      addTearDown(db.close);
      final container = containerOver(db);
      addTearDown(container.dispose);

      // An agent pane with no session row behind it — nothing to continue, and
      // a silent no-op would be indistinguishable from a broken button.
      final opened = container
          .read(terminalSessionsControllerProvider.notifier)
          .openAgentTab(
            const AgentPaneLaunch(
              agentId: 'sharing',
              executable: 'sharing',
              workingDirectory: r'C:\ws',
            ),
          );

      final result = await container
          .read(explorerActionsProvider)
          .resumeRestoredPane(opened.paneId);

      expect(result.outcome, ExplorerOutcome.failed);
      expect(result.message, contains('not one of our sessions'));
    });
  });
}
