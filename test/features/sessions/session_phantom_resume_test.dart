import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_cli_store_locator.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/temp_directory.dart';
import 'package:agent_cli/read.dart';

/// The owner's report: *"when resuming last active tabs after restarting the
/// app instead it seems to have created new sessions"*, with
///
/// ```
/// No conversation found with session ID: 4b13c55e-ec74-4c0b-ac63-44747861aabd
/// [process exited with code 1]
/// ```
///
/// on the pane. The row for that id had `id == external_session_id` — the
/// `--session-id` convention working exactly as designed — status `running`,
/// and no conversation anywhere in Claude Code's store.
///
/// That is a **promise the CLI never kept**. The id is written the moment the
/// session is launched, which is before the agent has demonstrably written
/// anything, and a session nothing was ever said in leaves a row naming a
/// conversation that does not exist. Nothing distinguished it from a real one,
/// so a restore resumed it, the agent said it had never heard of it, and the
/// app carried on in silence.

const _claudeish = AgentDescriptor(
  id: 'claudeish',
  displayName: 'Claudeish',
  binaries: AgentBinaries(windows: ['claudeish'], posix: ['claudeish']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    interactiveResume: AgentResume.flag('--resume'),
    sessionIdAssignment: AgentSessionIdAssignment.flag('--session-id'),
    allowsConcurrentResume: true,
  ),
  store: AgentStoreSpec(
    homeDirectoryName: '.claude',
    format: AgentStoreFormat.claudeJsonl,
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
  AgentInstallationDao(db).insert(agentInstallation(agentId: 'claudeish'));
  return db;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_phantom_'));
  tearDown(() => removeTempDirectory(tmp));

  String storeHome() => p.join(tmp.path, '.claude');

  /// A store that exists and has been read to the end. Without this the answer
  /// is "we cannot tell", and nothing is refused.
  void emptyStore() =>
      Directory(p.join(storeHome(), 'projects')).createSync(recursive: true);

  void writeConversation(String id) {
    File(p.join(storeHome(), 'projects', '-c-src-demo-app', '$id.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"type":"user","cwd":"C:\\\\src\\\\demo\\\\app"}\n');
  }

  /// [locatable] false is a store home the locator could not resolve — a WSL
  /// distribution that is not running — which must never read as "absent".
  ProviderContainer containerOver(
    AppDatabase db, {
    String idPrefix = 's-',
    bool locatable = true,
  }) => ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      commandRunnerFactoryProvider.overrideWithValue(
        FakeCommandRunnerFactory(),
      ),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator(idPrefix)),
      agentRegistryProvider.overrideWithValue(
        const AgentRegistry([_claudeish]),
      ),
      settingsControllerProvider.overrideWith(_StaticSettings.new),
      agentSessionStatusProvider.overrideWith(
        (ref, id) => const Stream<AgentStatusReport>.empty(),
      ),
      cliStoreLocatorProvider.overrideWithValue(
        FixedLocator([
          if (locatable)
            CliStore(
              environmentId: 'windows',
              homesByAgentId: {'claudeish': storeHome()},
            ),
        ]),
      ),
    ],
  );

  /// Starts a session the way the app does, and returns its id — which is also
  /// the CLI session id it was launched with.
  Future<String> startSession(ProviderContainer container) async {
    final launched = await container
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository(),
            installation: agentInstallation(agentId: 'claudeish'),
            title: 'New session',
            purpose: SessionPurpose.newSession,
          ),
        );
    expect(
      launched.session.externalSessionId,
      launched.session.id,
      reason: 'the row records the id it promised the CLI',
    );
    return launched.session.id;
  }

  /// The restart: persist what is on screen, drop the container, build another
  /// over the same database. Panes come back dormant, as they do in the app.
  ProviderContainer restart(
    ProviderContainer first,
    AppDatabase db, {
    bool locatable = true,
  }) {
    first.read(terminalSessionsControllerProvider.notifier).persistLayout();
    first.dispose();
    final next = containerOver(db, idPrefix: 't-', locatable: locatable);
    addTearDown(next.dispose);
    return next;
  }

  test('a session whose conversation was never written is refused, not '
      'restarted as a new one', () async {
    final db = seededDatabase();
    addTearDown(db.close);
    emptyStore();

    final first = containerOver(db);
    final sessionId = await startSession(first);
    final paneId = first.read(sessionDaoProvider).getById(sessionId)!.paneId!;
    final next = restart(first, db);
    expect(
      next.read(terminalSessionsControllerProvider).livenessOf(paneId),
      PaneLiveness.restored,
    );

    final result = await next
        .read(explorerActionsProvider)
        .openNative(sessionId);

    // What the user is told, in words about this conversation rather than the
    // agent's own exit code.
    expect(result.outcome, ExplorerOutcome.failed);
    expect(result.message, contains('Claudeish'));
    expect(result.message, contains('no record of this conversation'));
    expect(result.message, contains('No work has been lost'));
    expect(result.message, contains(sessionId));

    // And what did *not* happen: no second row, no fresh conversation started
    // under the row that claims history, and the dormant pane left alone.
    expect(next.read(sessionDaoProvider).getAll(), hasLength(1));
    expect(next.read(terminalSessionsControllerProvider).tabs, hasLength(1));
    expect(
      next.read(terminalSessionsControllerProvider).livenessOf(paneId),
      PaneLiveness.restored,
    );

    // The row stops claiming to be running the moment we learn better. It is
    // kept, not deleted: its title, directory and lineage are still the user's.
    final row = next.read(sessionDaoProvider).getById(sessionId)!;
    expect(row.status, SessionStatus.failed);
    expect(row.externalSessionId, sessionId);
    expect(row.title, 'New session');
  });

  test('a session whose conversation is on disk still resumes into its own '
      'pane', () async {
    final db = seededDatabase();
    addTearDown(db.close);

    final first = containerOver(db);
    final sessionId = await startSession(first);
    final paneId = first.read(sessionDaoProvider).getById(sessionId)!.paneId!;
    writeConversation(sessionId);
    final next = restart(first, db);

    final result = await next
        .read(explorerActionsProvider)
        .openNative(sessionId);

    expect(result.outcome, ExplorerOutcome.resumed);
    final state = next.read(terminalSessionsControllerProvider);
    expect(state.tabs, hasLength(1));
    expect(state.livenessOf(paneId), PaneLiveness.live);
    final launch = next
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId)!
        .agentLaunch!;
    expect(launch.arguments, containsAllInOrder(['--resume', sessionId]));
    expect(
      next.read(sessionDaoProvider).getById(sessionId)!.status,
      SessionStatus.running,
    );
  });

  test('a store we could not read never refuses a resume', () async {
    // "Cannot tell" is not "does not exist". A stopped WSL distribution, an
    // unmounted drive or a store home we failed to resolve all land here, and
    // the resume goes ahead exactly as it did before any of this existed.
    final db = seededDatabase();
    addTearDown(db.close);
    emptyStore();

    final first = containerOver(db);
    final sessionId = await startSession(first);
    final next = restart(first, db, locatable: false);

    final result = await next
        .read(explorerActionsProvider)
        .openNative(sessionId);

    expect(result.outcome, ExplorerOutcome.resumed);
    expect(
      next.read(sessionDaoProvider).getById(sessionId)!.status,
      SessionStatus.running,
    );
  });

  test('an id we read back from the agent is not second-guessed', () async {
    // Only an id we *handed* the agent is a promise. One discovered from a hook
    // payload, an imported store entry or a Codex rollout is evidence the
    // conversation existed, and the store is not asked to retract it.
    final db = seededDatabase();
    addTearDown(db.close);
    emptyStore();

    final first = containerOver(db);
    final sessionId = await startSession(first);
    first
        .read(sessionDaoProvider)
        .updateExternalSessionId(sessionId, 'observed-elsewhere');
    final next = restart(first, db);

    final result = await next
        .read(explorerActionsProvider)
        .openNative(sessionId);

    expect(result.outcome, ExplorerOutcome.resumed);
  });

  test(
    'the refusal is thrown by the launcher, so no surface can forget it',
    () async {
      final db = seededDatabase();
      addTearDown(db.close);
      emptyStore();

      final container = containerOver(db);
      addTearDown(container.dispose);
      final sessionId = await startSession(container);

      await expectLater(
        container
            .read(sessionLauncherProvider)
            .launch(
              SessionLaunchRequest(
                repository: repository(),
                installation: agentInstallation(agentId: 'claudeish'),
                title: 'New session',
                purpose: SessionPurpose.existingSession,
                resumeExternalSessionId: sessionId,
              ),
            ),
        throwsA(isA<SessionConversationMissing>()),
      );
      expect(container.read(sessionDaoProvider).getAll(), hasLength(1));
    },
  );
}
