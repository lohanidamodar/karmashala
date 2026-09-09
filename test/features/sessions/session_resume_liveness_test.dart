import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_launch.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';
import '../terminal/fake_instance.dart';

/// A resumable agent. Codex is the one that actually refuses a second writer,
/// but nothing here depends on which CLI it is: the guard is about *our*
/// knowledge of what is running, not about parsing an agent's error.
const _codexish = AgentDescriptor(
  id: 'codexish',
  displayName: 'Codexish',
  binaries: AgentBinaries(windows: ['codexish'], posix: ['codexish']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    interactiveResume: AgentResume.subcommand('resume'),
  ),
);

/// An agent that shares a conversation — Claude Code's behaviour. The refusal
/// never fires for it, so it is the only way to reach the launcher's decisions
/// *about a live row*.
const _shareable = AgentDescriptor(
  id: 'sharish',
  displayName: 'Sharish',
  binaries: AgentBinaries(windows: ['sharish'], posix: ['sharish']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    interactiveResume: AgentResume.flag('--resume'),
    allowsConcurrentResume: true,
  ),
);

({ProviderContainer container, AppDatabase db}) harness({
  AgentDescriptor descriptor = _codexish,
}) {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  AgentInstallationDao(db).insert(agentInstallation(agentId: descriptor.id));

  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      agentRegistryProvider.overrideWithValue(AgentRegistry([descriptor])),
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
  String title = 'Live work',
  String agentId = 'codexish',
}) async {
  final launched = await container
      .read(sessionLauncherProvider)
      .launch(
        SessionLaunchRequest(
          repository: repository(),
          installation: agentInstallation(agentId: agentId),
          title: title,
          purpose: SessionPurpose.newSession,
        ),
      );
  container
      .read(sessionDaoProvider)
      .updateExternalSessionId(launched.session.id, externalId);
  return launched.session.id;
}

/// A second row for the same conversation whose process has since ended — the
/// duplicate a resume used to leave behind.
Future<String> _startDeadSession(
  ProviderContainer container, {
  String externalId = 'ext-1',
  String title = 'Dead work',
}) async {
  final id = await _startLiveSession(
    container,
    externalId: externalId,
    title: title,
  );
  container
      .read(terminalSessionsControllerProvider.notifier)
      .endSession(container.read(sessionDaoProvider).getById(id)!.paneId!);
  return id;
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

  test('a session whose process has ended is genuinely resumed, in its own '
      'row', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);

    final stoppedId = await _startDeadSession(h.container, title: 'Live work');

    final resumed = await h.container
        .read(sessionActionsProvider)
        .resumeImported(_imported());

    // A new agent process is exactly right — nothing is running it any more —
    // but it continues the row that already records this conversation rather
    // than leaving the dead one behind and starting a second (A3).
    expect(resumed, stoppedId);
    expect(SessionDao(h.db).getByRepository('r1'), hasLength(1));
    final row = SessionDao(h.db).getById(resumed)!;
    expect(row.status, SessionStatus.running);
    final launch = h.container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(row.paneId!)!
        .agentLaunch!;
    expect(launch.arguments, ['--mode', 'ask', 'resume', 'ext-1']);
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

  group('a resume reuses the row it is resuming', () {
    /// Resumes `ext-1` through the launcher, the way every native resume path
    /// does (`explorer_actions`, `launcher_control_server`, `resumeImported`).
    Future<SessionLaunchResult> resume(
      ProviderContainer container, {
      String title = 'Continue',
      Repository? repository_,
      String installationId = 'a1',
    }) => container
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository_ ?? repository(),
            installation: agentInstallation(
              id: installationId,
              agentId: 'codexish',
            ),
            title: title,
            purpose: SessionPurpose.existingSession,
            resumeExternalSessionId: 'ext-1',
          ),
        );

    test('resuming twice does not grow the table', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final originalId = await _startDeadSession(h.container);

      for (var round = 0; round < 2; round++) {
        final result = await resume(h.container);
        expect(result.session.id, originalId);
        expect(
          SessionDao(h.db).getAllByExternalSessionId('ext-1'),
          hasLength(1),
        );
        // Each round ends the pane again so the next one is a resume of a
        // stopped session rather than a second writer.
        h.container
            .read(terminalSessionsControllerProvider.notifier)
            .endSession(SessionDao(h.db).getById(originalId)!.paneId!);
      }
    });

    test(
      'reuse continues the session and never renames or re-dates it',
      () async {
        final h = harness();
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        final originalId = await _startDeadSession(
          h.container,
          title: 'Refactor the parser',
        );
        final before = SessionDao(h.db).getById(originalId)!;

        await resume(h.container, title: 'rollout-ext-1.jsonl');

        final after = SessionDao(h.db).getById(originalId)!;
        // The imported entry's CLI-derived title must not overwrite the name the
        // user's session already has, and its identity must survive the resume.
        expect(after.title, 'Refactor the parser');
        expect(after.createdAt, before.createdAt);
        expect(after.externalSessionId, 'ext-1');
        expect(after.status, SessionStatus.running);
        expect(after.paneId, isNot(before.paneId));
        // Nobody chose a mode for this session, and a resume is not a choice:
        // the column stays empty so the session goes on following the setting.
        expect(after.permissionMode, isNull);
      },
    );

    test('a resume onto a different repository writes its own row', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      RepositoryDao(h.db).insert(repository(id: 'r2', name: 'other'));
      final originalId = await _startDeadSession(h.container);

      final result = await resume(
        h.container,
        repository_: repository(id: 'r2', name: 'other'),
      );

      // Same conversation, different thing being run: reusing the row would
      // leave it claiming a repository it is not in.
      expect(result.session.id, isNot(originalId));
      expect(SessionDao(h.db).getAllByExternalSessionId('ext-1'), hasLength(2));
    });

    test('a resume by a different installation writes its own row', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      AgentInstallationDao(h.db).insert(
        agentInstallation(id: 'a2', agentId: 'codexish', path: r'C:\alt\c.exe'),
      );
      final originalId = await _startDeadSession(h.container);

      final result = await resume(h.container, installationId: 'a2');

      expect(result.session.id, isNot(originalId));
      expect(SessionDao(h.db).getAllByExternalSessionId('ext-1'), hasLength(2));
    });

    test(
      'an archived row is left archived, and a new one is written',
      () async {
        final h = harness();
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        final originalId = await _startDeadSession(h.container);
        // Its worktree is gone; pointing a live agent back at it would run in a
        // directory that no longer exists.
        SessionDao(h.db).markArchived(originalId, testTime);

        final result = await resume(h.container);

        expect(result.session.id, isNot(originalId));
        expect(SessionDao(h.db).getById(originalId)!.isArchived, isTrue);
      },
    );

    test('a live row is never reused, even where the agent shares the '
        'conversation', () async {
      // Claude Code permits a second process on one conversation, so the
      // refusal does not fire and the reuse check is what stands between "a
      // second session, as asked" and losing the pane the first one is in.
      final h = harness(descriptor: _shareable);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final liveId = await _startLiveSession(h.container, agentId: 'sharish');
      final livePane = SessionDao(h.db).getById(liveId)!.paneId;

      final second = await h.container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'sharish'),
              title: 'Second window',
              purpose: SessionPurpose.existingSession,
              resumeExternalSessionId: 'ext-1',
            ),
          );

      expect(second.session.id, isNot(liveId));
      expect(SessionDao(h.db).getAllByExternalSessionId('ext-1'), hasLength(2));
      // The first session still owns its own pane.
      expect(SessionDao(h.db).getById(liveId)!.paneId, livePane);
      expect(
        h.container.read(sessionLauncherProvider).livePaneFor(liveId),
        livePane,
      );
    });
  });

  group('duplicate rows for one conversation', () {
    // The double-writer check is what stands between a Codex thread and a
    // corrupted rollout JSONL, and until Loop 66 it asked the database for
    // *a* row with the conversation's id and trusted whichever came back.
    // With two rows — the shape every resume used to create — that answer was
    // the insertion order, so a dead duplicate written first reported the
    // conversation free while a pane was still writing to it.
    test('the live row is found when the dead duplicate came first', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final deadId = await _startDeadSession(h.container);
      final liveId = await _startLiveSession(h.container);
      expect(SessionDao(h.db).getAllByExternalSessionId('ext-1'), hasLength(2));

      final launcher = h.container.read(sessionLauncherProvider);
      expect(launcher.runningSessionWithExternalId('ext-1')?.id, liveId);
      expect(launcher.hostedLive(externalSessionId: 'ext-1'), isTrue);
      expect(launcher.livePaneFor(deadId), isNull);

      // And the refusal that gate exists for still fires, naming the session
      // that actually holds the conversation.
      await expectLater(
        launcher.launch(
          SessionLaunchRequest(
            repository: repository(),
            installation: agentInstallation(agentId: 'codexish'),
            title: 'Second writer',
            purpose: SessionPurpose.existingSession,
            resumeExternalSessionId: 'ext-1',
          ),
        ),
        throwsA(
          isA<SessionAlreadyRunning>()
              .having((e) => e.sessionId, 'sessionId', liveId)
              .having((e) => e.title, 'title', 'Live work'),
        ),
      );
    });

    test('the live row is found when the dead duplicate came after', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final liveId = await _startLiveSession(h.container);
      await _startDeadSession(h.container);

      final launcher = h.container.read(sessionLauncherProvider);
      expect(launcher.runningSessionWithExternalId('ext-1')?.id, liveId);
    });

    test('all-dead duplicates leave the conversation free', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await _startDeadSession(h.container);
      await _startDeadSession(h.container);

      final launcher = h.container.read(sessionLauncherProvider);
      expect(launcher.runningSessionWithExternalId('ext-1'), isNull);
      expect(launcher.hostedLive(externalSessionId: 'ext-1'), isFalse);
    });
  });

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
