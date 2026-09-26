import 'dart:async';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:karmashala/src/features/cli_detection/application/cli_detection_service.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/process.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';

/// Adoption through the real providers, and the point of the exercise: what it
/// produces is a session row like any other.
///
/// The pane is a fake with no shell integration — the case a real WSL bash pane
/// is in — so it is armed the way that pane would be, off Claude Code's own
/// footer, and named by the hook it fires.

const _repoPath = r'C:\src\demo\app';

/// Claude Code v2.1.251's idle footer, the row `AgentGridRules.idle` matches.
const _claudeFooter = '  ? for shortcuts · shift+tab to cycle';

/// A detection service with no stores behind it.
class _NoStores implements CliDetectionService {
  const _NoStores();
  @override
  Future<List<DetectedProject>> detect(
    List<CliStore> stores,
    Map<String, ExecutionEnvironment> environmentsById,
  ) async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

typedef Harness = ({ProviderContainer container, AppDatabase db});

Future<Harness> harness() async {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  final server = FakeDataServer()..mirrorInto(db);
  server.projectRows.insert(project());
  server.repositoryRows.insert(repository());
  AgentInstallationDao(
    db,
  ).insert(agentInstallation(agentId: AgentIds.claudeCode));
  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      await server.override(),
      // Hermetic: the real probe would read this machine's own agent store.
      conversationPresenceProvider.overrideWithValue(
        ({
          required descriptor,
          required environmentId,
          required conversationId,
        }) async => ConversationPresence.unknown,
      ),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      commandRunnerFactoryProvider.overrideWithValue(
        FakeCommandRunnerFactory(),
      ),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      settingsControllerProvider.overrideWith(_StaticSettings.new),
      agentSessionStatusProvider.overrideWith(
        (ref, id) => const Stream<AgentStatusReport>.empty(),
      ),
      // The sweep is real; the stores it would walk are the machine's own, and
      // a test has no business reading them.
      cliDetectionServiceProvider.overrideWithValue(const _NoStores()),
    ],
  );
  return (container: container, db: db);
}

/// Opens a plain shell pane in the repository and draws an agent's footer in
/// it, which is what "the user typed `claude` here" looks like from outside.
String openAgentLookingPane(Harness h) {
  final terminals = h.container.read(
    terminalSessionsControllerProvider.notifier,
  );
  final tabId = terminals.openTab(
    TerminalProfile.powerShell,
    workingDirectory: _repoPath,
  );
  final paneId = h.container
      .read(terminalSessionsControllerProvider)
      .tabs
      .firstWhere((tab) => tab.id == tabId)
      .focusedPaneId;
  terminals.instanceFor(paneId)!.terminal.write('$_claudeFooter\r\n');
  return paneId;
}

/// One store slot's worth of adoption, driven the way the registry drives it.
Future<void> runStoreSlot(Harness h) async {
  final adoption = h.container.read(sessionAdoptionServiceProvider);
  adoption.observePanes();
  await adoption.sweep();
}

void main() {
  test('a pane running an agent is adopted, and the hook names it', () async {
    final h = await harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final paneId = openAgentLookingPane(h);

    // The screen arms the pane; the store has nothing to say (no CLI store on
    // this machine), so the conversation stays unnamed …
    await runStoreSlot(h);
    expect(h.container.read(sessionDaoProvider).getAll(), isEmpty);

    // … until the agent's own hook says which conversation it is.
    h.container
        .read(sessionAdoptionServiceProvider)
        .onHookPayload(
          agentId: AgentIds.claudeCode,
          sessionId: 'cli-abc',
          body: '{"session_id":"cli-abc","cwd":"$_repoPath"}',
        );

    final rows = h.container.read(sessionDaoProvider).getAll();
    expect(rows, hasLength(1));
    expect(rows.single.paneId, paneId);
    expect(rows.single.externalSessionId, 'cli-abc');
    expect(
      h.container.read(sessionDaoProvider).getByRepository('r1'),
      hasLength(1),
      reason: 'it hangs under the repository the Explorer draws',
    );
  });

  test('adoption queues the conversation for the search index', () async {
    final h = await harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    openAgentLookingPane(h);
    await runStoreSlot(h);

    expect(
      h.container.read(conversationIndexerProvider).wantedIds,
      isEmpty,
      reason: 'nothing has been adopted yet',
    );

    h.container
        .read(sessionAdoptionServiceProvider)
        .onHookPayload(
          agentId: AgentIds.claudeCode,
          sessionId: 'cli-abc',
          body: '{"session_id":"cli-abc","cwd":"$_repoPath"}',
        );

    // A conversation entering the workspace is the first of the two triggers
    // the index is built on. Queuing is a map entry — the disk work happens on
    // the store slot that is already open, and only there.
    expect(
      h.container.read(conversationIndexerProvider).wantedIds,
      contains('cli-abc'),
    );
  });

  test(
    'an adopted session renames and reattaches like a launched one',
    () async {
      final h = await harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      openAgentLookingPane(h);
      await runStoreSlot(h);
      h.container
          .read(sessionAdoptionServiceProvider)
          .onHookPayload(
            agentId: AgentIds.claudeCode,
            sessionId: 'cli-abc',
            body: '{"session_id":"cli-abc"}',
          );
      final id = h.container.read(sessionDaoProvider).getAll().single.id;

      unawaited(
        h.container
            .read(sessionActionsProvider)
            .renameNative(id, 'The parser bug'),
      );
      final opened = await h.container
          .read(explorerActionsProvider)
          .openNative(id);

      expect(
        h.container.read(sessionDaoProvider).getById(id)?.title,
        'The parser bug',
      );
      expect(
        opened.outcome,
        ExplorerOutcome.reattached,
        reason: 'clicking the card brings back the terminal it is running in',
      );
      expect(h.container.read(sessionDaoProvider).getAll(), hasLength(1));
    },
  );

  test(
    'an adopted session resumes its own conversation once its pane is gone',
    () async {
      final h = await harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final paneId = openAgentLookingPane(h);
      await runStoreSlot(h);
      h.container
          .read(sessionAdoptionServiceProvider)
          .onHookPayload(
            agentId: AgentIds.claudeCode,
            sessionId: 'cli-abc',
            body: '{"session_id":"cli-abc"}',
          );
      final id = h.container.read(sessionDaoProvider).getAll().single.id;

      // The agent is ended, so there is nothing to reattach to.
      h.container.read(terminalSessionsControllerProvider.notifier)
        ..endSession(paneId)
        ..closePane(paneId, detach: false);

      final opened = await h.container
          .read(explorerActionsProvider)
          .openNative(id);

      expect(opened.outcome, ExplorerOutcome.resumed);
      // The same row, continued — not a second one for one conversation.
      expect(h.container.read(sessionDaoProvider).getAll(), hasLength(1));
      final resumed = h.container.read(sessionDaoProvider).getById(id)!;
      expect(resumed.externalSessionId, 'cli-abc');
      expect(resumed.status, SessionStatus.running);
      expect(resumed.surface, SessionSurface.pane);
      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(resumed.paneId!)!
          .agentLaunch!;
      expect(launch.arguments, containsAllInOrder(['--resume', 'cli-abc']));
    },
  );

  test('a plain pane with nothing agent-like in it is never adopted', () async {
    final h = await harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final terminals = h.container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final tabId = terminals.openTab(
      TerminalProfile.powerShell,
      workingDirectory: _repoPath,
    );
    final paneId = h.container
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((tab) => tab.id == tabId)
        .focusedPaneId;
    terminals
        .instanceFor(paneId)!
        .terminal
        .write('PS C:\\src\\demo\\app> ls\r\n');

    await runStoreSlot(h);
    h.container
        .read(sessionAdoptionServiceProvider)
        .onHookPayload(
          agentId: AgentIds.claudeCode,
          sessionId: 'cli-abc',
          body: '{"session_id":"cli-abc"}',
        );

    expect(
      h.container.read(sessionAdoptionServiceProvider).armedPaneIds,
      isEmpty,
    );
    expect(h.container.read(sessionDaoProvider).getAll(), isEmpty);
  });
}
