import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_resume_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/workspace_mirror.dart';
import '../../support/fake_data_server.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';
import '../terminal/fake_instance.dart';

/// What one click on a card, or on a `+`, is allowed to do.
///
/// The rules are Loop 46's and they are not re-implemented here — these tests
/// exist to prove the Explorer *asks* rather than deciding for itself, and to
/// pin the two things it does own: a worktree session resumes **in its
/// worktree**, and a second click never stacks a third process on one
/// conversation.

/// Verbatim from codex-cli 0.151.0 — see `session_whereabouts_test.dart`. The
/// only proof we ever get that a process we do not own holds a conversation.
const _refusal =
    'Error: thread/resume failed: thread 01a051ab already has an active writer '
    '(code -32600)';

const _sharing = AgentDescriptor(
  id: 'sharing',
  displayName: 'Sharing Agent',
  binaries: AgentBinaries(windows: ['sharing'], posix: ['sharing']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    interactiveResume: AgentResume.flag('--resume'),
    allowsConcurrentResume: true,
  ),
);

/// The other half of the capability: an agent that refuses a second writer, and
/// whose refusal we can recognise on its own screen.
const _exclusive = AgentDescriptor(
  id: 'exclusive',
  displayName: 'Exclusive Agent',
  binaries: AgentBinaries(windows: ['exclusive'], posix: ['exclusive']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    interactiveResume: AgentResume.subcommand('resume'),
    resumeConflict: AgentResumeConflictRules(
      markers: [GridMatcher('already has an active writer')],
    ),
  ),
);

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

typedef Harness = ({ProviderContainer container, AppDatabase db});

Future<Harness> harness({
  bool installAgent = true,
  String agentId = 'sharing',
}) async {
  final db = AppDatabase.memory();
  final server = FakeDataServer()..mirrorInto(db);
  server.environmentRows.upsert(windowsEnv());
  server.projectRows.insert(project());
  server.repositoryRows.insert(repository());
  if (installAgent) {
    server.installationRows.insert(agentInstallation(agentId: agentId));
  }
  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      await server.override(),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      commandRunnerFactoryProvider.overrideWithValue(
        FakeCommandRunnerFactory(),
      ),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      agentRegistryProvider.overrideWithValue(
        const AgentRegistry([
          DataOnlyAgentAdapter(_sharing),
          DataOnlyAgentAdapter(_exclusive),
        ]),
      ),
      settingsControllerProvider.overrideWith(_StaticSettings.new),
      // The whereabouts provider watches this stream for a "last seen" time;
      // a real poll leaves an autoDispose stream mid-flight when a plain
      // container reads it once. Nothing here is about ageing evidence.
      agentSessionStatusProvider.overrideWith(
        (ref, id) => const Stream<AgentStatusReport>.empty(),
      ),
    ],
  );
  return (container: container, db: db);
}

EnvironmentPath path(String value) =>
    EnvironmentPath(environmentId: 'windows', path: value);

/// A row for a conversation nothing of ours is running — the resume case.
Session stopped({
  String id = 'old',
  String externalId = 'ext-1',
  EnvironmentPath? worktree,
}) => Session(
  id: id,
  repositoryId: 'r1',
  agentInstallationId: 'a1',
  title: 'Earlier work',
  useWorktree: worktree != null,
  worktree: worktree,
  status: SessionStatus.completed,
  createdAt: testTime,
  externalSessionId: externalId,
);

Future<String> launchLive(
  Harness h, {
  String? externalId,
  String agentId = 'sharing',
}) async {
  final launched = await h.container
      .read(sessionLauncherProvider)
      .launch(
        SessionLaunchRequest(
          repository: repository(),
          installation: agentInstallation(agentId: agentId),
          title: 'Live work',
          purpose: SessionPurpose.newSession,
        ),
      );
  if (externalId != null) {
    h.container
        .read(sessionsDataProvider)
        .updateExternalSessionId(launched.session.id, externalId);
  }
  return launched.session.id;
}

String? paneCwd(Harness h, String sessionId) {
  final paneId = h.container
      .read(sessionsDataProvider)
      .getById(sessionId)
      ?.paneId;
  if (paneId == null) return null;
  return h.container
      .read(terminalSessionsControllerProvider.notifier)
      .instanceFor(paneId)
      ?.workingDirectory;
}

void main() {
  group('opening a session', () {
    test(
      'a session we are still running is reattached, not relaunched',
      () async {
        final h = await harness();
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);
        final id = await launchLive(h);
        final before = h.container.read(sessionsDataProvider).getAll().length;

        final result = await h.container
            .read(explorerActionsProvider)
            .openNative(id);

        expect(result.outcome, ExplorerOutcome.reattached);
        expect(
          h.container.read(sessionsDataProvider).getAll().length,
          before,
          reason: 'nothing was spawned',
        );
      },
    );

    test('a stopped worktree session resumes in its worktree', () async {
      // Loop 57's blocker, and the reason it could not be fixed there: the
      // launcher had no way to say "this repository, but run over there", so
      // every resume put the agent back in the repository root — a different
      // directory on a different branch from the work being resumed.
      final h = await harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final worktree = path(r'C:\src\demo\.karmashala-worktrees\wt-a');
      serverOf(h.container).sessionRows.insert(stopped(worktree: worktree));

      final result = await h.container
          .read(explorerActionsProvider)
          .openNative('old');

      expect(result.outcome, ExplorerOutcome.resumed);
      // Loop 66: the resume continues the row it was asked to continue rather
      // than minting a second one for the same conversation.
      expect(h.container.read(sessionsDataProvider).getAll(), hasLength(1));
      final resumed = h.container.read(sessionsDataProvider).getById('old')!;
      expect(resumed.status, SessionStatus.running);
      expect(resumed.worktree, worktree);
      expect(resumed.useWorktree, isTrue);
      expect(
        resumed.externalSessionId,
        'ext-1',
        reason: 'the same conversation',
      );
      // The fact that actually matters: the process was started there.
      expect(paneCwd(h, resumed.id), worktree.path);
    });

    test('a session in no worktree resumes in the repository', () async {
      final h = await harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      serverOf(h.container).sessionRows.insert(stopped());

      await h.container.read(explorerActionsProvider).openNative('old');

      expect(h.container.read(sessionsDataProvider).getAll(), hasLength(1));
      final resumed = h.container.read(sessionsDataProvider).getById('old')!;
      expect(resumed.worktree, isNull);
      expect(paneCwd(h, resumed.id), repository().path.path);
    });

    test('a session whose CLI id we never learned is only selected', () async {
      // Starting the agent here would be a *new* conversation wearing this
      // row's title, which is worse than doing nothing.
      final h = await harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      serverOf(h.container).sessionRows.insert(stopped(externalId: ''));

      final result = await h.container
          .read(explorerActionsProvider)
          .openNative('old');

      expect(result.outcome, ExplorerOutcome.selected);
      expect(h.container.read(sessionsDataProvider).getAll().length, 1);
    });

    test('clicking the older row of a duplicated conversation reveals the live '
        'one instead of stacking a third', () async {
      // A resume no longer *creates* this shape (Loop 66 reuses the row), but
      // every database written before it holds duplicate pairs, and the older
      // card is still there to click. `_liveTwinOf` is what keeps that click
      // honest: two rows, one conversation, one process.
      final h = await harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      serverOf(h.container).sessionRows.insert(stopped());
      await launchLive(h, externalId: 'ext-1');
      final after = h.container.read(sessionsDataProvider).getAll().length;
      expect(after, 2);

      final result = await h.container
          .read(explorerActionsProvider)
          .openNative('old');

      expect(result.outcome, ExplorerOutcome.reattached);
      expect(
        h.container.read(sessionsDataProvider).getAll().length,
        after,
        reason: 'a second click must not put a third agent on the transcript',
      );
    });

    test('an agent that refused to share says so in plain words', () async {
      final h = await harness(agentId: 'exclusive');
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      // A pane of ours died showing the agent's own refusal — the only certain
      // knowledge we ever get about a process we do not own.
      final id = await launchLive(h, externalId: 'ext-9', agentId: 'exclusive');
      final paneId = h.container.read(sessionsDataProvider).getById(id)!.paneId!;
      final instance =
          h.container
                  .read(terminalSessionsControllerProvider.notifier)
                  .instanceFor(paneId)!
              as FakeTerminalInstance;
      instance.terminal.write('$_refusal\r\n');
      instance.livenessNotifier.value = PaneLiveness.exited;
      h.container.invalidate(sessionWhereaboutsProvider(id));
      expect(
        h.container.read(sessionWhereaboutsProvider(id)).knownHeldElsewhere,
        isTrue,
        reason: 'the fixture has to reach the state the assertion is about',
      );
      final before = h.container.read(sessionsDataProvider).getAll().length;

      final result = await h.container
          .read(explorerActionsProvider)
          .openNative(id);

      expect(result.outcome, ExplorerOutcome.blocked);
      expect(result.message, contains('will not resume a conversation'));
      expect(
        h.container.read(sessionsDataProvider).getAll().length,
        before,
        reason: 'refused means nothing was started',
      );
    });

    test(
      'a session that has been deleted underneath us fails cleanly',
      () async {
        final h = await harness();
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        final result = await h.container
            .read(explorerActionsProvider)
            .openNative('gone');

        expect(result.outcome, ExplorerOutcome.failed);
        expect(result.message, 'This session no longer exists.');
      },
    );
  });

  group('starting a session', () {
    test('the + uses the default agent for that environment', () async {
      final h = await harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final result = await h.container
          .read(explorerActionsProvider)
          .startSession(repository: repository());

      expect(result.outcome, ExplorerOutcome.started);
      final started = h.container.read(sessionsDataProvider).getAll().single;
      expect(started.agentInstallationId, 'a1');
      expect(paneCwd(h, started.id), repository().path.path);
    });

    test('a worktree with no repositories row of its own is startable', () async {
      // Loop 57 had to refuse this: a session needs a repository id and a folder
      // with no row has none. The owning repository supplies the id and
      // `existingWorktree` supplies the directory.
      final h = await harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final worktree = path(r'C:\elsewhere\wt-side');

      final result = await h.container
          .read(explorerActionsProvider)
          .startSession(repository: repository(), existingWorktree: worktree);

      expect(result.outcome, ExplorerOutcome.started);
      final started = h.container.read(sessionsDataProvider).getAll().single;
      expect(started.repositoryId, 'r1');
      expect(started.worktree, worktree);
      expect(paneCwd(h, started.id), worktree.path);
    });

    test('no agent installed is a sentence, not an exception', () async {
      final h = await harness(installAgent: false);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final result = await h.container
          .read(explorerActionsProvider)
          .startSession(repository: repository());

      expect(result.outcome, ExplorerOutcome.failed);
      expect(result.message, contains('Discover agents'));
      expect(h.container.read(sessionsDataProvider).getAll(), isEmpty);
    });

    test('installationsFor lists what the "…with" menu may offer', () async {
      final h = await harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final installations = h.container
          .read(explorerActionsProvider)
          .installationsFor(repository());

      expect(installations.map((i) => i.id), ['a1']);
    });
  });
}
