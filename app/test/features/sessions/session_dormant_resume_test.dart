import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/frame_yield.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/persistence.dart';
import 'package:karmashala/src/features/terminal/application/terminal_layout_providers.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_session/session.dart' show SessionStatus;
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionResume, SessionStart;

import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';
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

/// The agent a session is switched to.
const _other = AgentDescriptor(
  id: 'other',
  displayName: 'Other Agent',
  binaries: AgentBinaries(windows: ['other'], posix: ['other']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    interactiveResume: AgentResume.flag('--resume'),
    prompt: AgentPromptSupport.positional(),
    allowsConcurrentResume: true,
  ),
);

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

/// The data client each seeded database's workspace is served through — one
/// server per database, so a restart (a second container over the same db)
/// sees the same workspace.
final _clients = Expando<DataClient>();

/// This machine's layout store, one per seeded database, so a restart finds
/// what the first run saved.
final _layouts = Expando<TerminalLayoutStore>();

TerminalLayoutStore layoutOf(TestMachine db) =>
    _layouts[db] ??= TerminalLayoutStore.memory();

Future<TestMachine> seededDatabase() async {
  final db = TestMachine();
  final server = FakeDataServer()..runsOn(db);
  server.environmentRows.upsert(windowsEnv());
  server.projectRows.insert(project());
  server.repositoryRows.insert(repository());
  server.installationRows.insert(agentInstallation(agentId: 'sharing'));
  _clients[db] = await server.connect();
  return db;
}

/// A container over [db]. The id prefix is a parameter because a second
/// container over the same database is what a restart *is*, and two generators
/// counting from zero would hand out ids the first run already used.
///
/// [layoutDao] and [frameYield] are the two seams a bulk resume is counted
/// through — named rather than a list of overrides because Riverpod's
/// `Override` is a sealed type its public library does not export, so it
/// cannot be written down as a parameter type.
ProviderContainer containerOver(
  TestMachine db, {
  String idPrefix = 's-',
  TerminalLayoutDao? layoutDao,
  Future<void> Function()? frameYield,
}) => ProviderContainer(
  overrides: [
    dataClientProvider.overrideWithValue(_clients[db]!),
    ...fakeTerminalOverrides(machine: db, layoutStore: layoutOf(db)),
    clockProvider.overrideWithValue(FixedClock(testTime)),
    hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
    commandRunnerFactoryProvider.overrideWithValue(FakeCommandRunnerFactory()),
    idGeneratorProvider.overrideWithValue(SequentialIdGenerator(idPrefix)),
    agentRegistryProvider.overrideWithValue(
      const AgentRegistry([
        DataOnlyAgentAdapter(_sharing),
        DataOnlyAgentAdapter(_other),
      ]),
    ),
    settingsControllerProvider.overrideWith(_StaticSettings.new),
    // The whereabouts provider watches this for a "last seen" time; a real
    // poll would leave an autoDispose stream mid-flight. Nothing here is
    // about ageing evidence.
    agentSessionStatusProvider.overrideWith(
      (ref, id) => const Stream<AgentStatusReport>.empty(),
    ),
    if (layoutDao != null)
      terminalLayoutDaoProvider.overrideWithValue(layoutDao),
    if (frameYield != null) frameYieldProvider.overrideWithValue(frameYield),
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
      .read(sessionsDataProvider)
      .updateExternalSessionId(launched.session.id, externalId);
  return launched.session.id;
}

String paneOf(ProviderContainer container, String sessionId) =>
    container.read(sessionsDataProvider).getById(sessionId)!.paneId!;

void main() {
  test('a session restored from disk resumes in the pane it came back in, '
      'not beside it', () async {
    final db = await seededDatabase();

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
    expect(next.read(sessionsDataProvider).getById(sessionId)!.paneId, paneId);

    final started =
        next
                .read(terminalSessionsControllerProvider.notifier)
                .instanceFor(paneId)!
            as FakeTerminalInstance;
    // The agent was resumed, not started afresh — asked of the server, whose
    // command line it is (slice 5b)…
    final asked = db.server.sessionWork.asked
        .whereType<SessionStart>()
        .last
        .spec;
    expect(asked.resumeConversationId, 'ext-1');
    // …and the buffer that was the whole reason to keep the pane survived it.
    expect(started.restored, contains('what happened yesterday'));
  });

  test('a session whose pane ran and died is resumed in a pane of its '
      'own', () async {
    // The distinction `livePaneFor` was right to make, kept: an exited pane
    // belongs to *this* run of the app, its buffer has moved on since anything
    // was restored into it, and it is a record of a process that failed or was
    // ended rather than history waiting to be continued.
    final db = await seededDatabase();
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
      container.read(sessionsDataProvider).getById(sessionId)!.paneId,
      isNot(paneId),
    );
  });

  test('a session with no pane at all still gets one', () async {
    final db = await seededDatabase();
    final container = containerOver(db);
    addTearDown(container.dispose);

    final sessionId = await startSession(container);
    // Ending the session takes its pane away; the row keeps the stale id, which
    // is the case `dormantPaneFor` must not answer with.
    final paneId = paneOf(container, sessionId);
    container
        .read(terminalSessionsControllerProvider.notifier)
        .endSession(paneId);
    expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);

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
    final db = await seededDatabase();

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

  test('after a restart, the restored panes of a switched session each show '
      'that nothing runs, and Resume leaves one terminal on its current '
      'agent', () async {
    final db = await seededDatabase();
    db.server.installationRows.insert(
      agentInstallation(id: 'a2', agentId: 'other', path: r'C:inother'),
    );

    final first = containerOver(db);
    final sessionId = await startSession(first);
    final terminals = first.read(terminalSessionsControllerProvider.notifier);
    final current = paneOf(first, sessionId);
    // A second terminal on the row, of the agent it was switched to.
    final switched = terminals
        .openAgentTab(
          AgentPaneLaunch(
            agentId: 'other',
            executable: 'other',
            sessionId: sessionId,
          ),
        )
        .paneId;
    terminals.persistLayout();
    first.dispose();
    db.server.sessionRows.put(
      db.server.sessionRows
          .getById(sessionId)!
          .copyWith(
            agentInstallationId: 'a2',
            status: SessionStatus.unknown,
            externalSessionId: 'ext-1',
          ),
    );

    final next = containerOver(db, idPrefix: 't-');
    addTearDown(next.dispose);
    final restored = next.read(terminalSessionsControllerProvider);
    // Each pane is restored history: its bar says so and offers Resume.
    expect(restored.livenessOf(current), PaneLiveness.restored);
    expect(restored.livenessOf(switched), PaneLiveness.restored);
    next.read(terminalSessionsControllerProvider.notifier).focusPane(current);
    expect(
      next.read(terminalSessionsControllerProvider).livenessOf(current),
      PaneLiveness.restored,
      reason: 'focusing a restored agent pane starts nothing',
    );

    // Resume on the pane of the agent the row has left.
    final result = await next
        .read(explorerActionsProvider)
        .resumeRestoredPane(current);

    expect(result.outcome, ExplorerOutcome.resumed, reason: result.message);
    final state = next.read(terminalSessionsControllerProvider);
    final panes = [for (final tab in state.tabs) ...tab.layout.panes];
    expect(panes, [switched]);
    expect(state.livenessOf(switched), PaneLiveness.live);
    expect(
      next
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(switched)!
          .agentLaunch!
          .agentId,
      'other',
    );
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
      final db = await seededDatabase();

      final first = containerOver(db);
      final sessionId = await startSession(
        first,
        firstMessage: 'summarise yesterday',
      );
      final paneId = paneOf(first, sessionId);
      final terminals = first.read(terminalSessionsControllerProvider.notifier);
      expect(
        db.server.sessionWork.asked.whereType<SessionStart>().last.spec.prompt,
        'summarise yesterday',
        reason: 'the opening prompt the session was first started with',
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
      expect(started.agentLaunch?.sessionId, sessionId);
      final resumed = db.server.sessionWork.asked.last;
      expect(
        resumed is SessionResume ||
            (resumed is SessionStart &&
                resumed.spec.resumeConversationId == 'ext-1'),
        isTrue,
        reason: 'a resume of its own conversation, asked of the server',
      );
      expect(
        resumed is SessionStart ? resumed.spec.prompt : null,
        isNull,
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
      final db = await seededDatabase();
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
