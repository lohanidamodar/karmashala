import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/checkpoints/data/checkpoint_dao.dart';
import 'package:karmashala/src/features/checkpoints/domain/checkpoint.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_archive_service.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_event_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_event.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// Archiving a session's worktree.
///
/// The rule this file exists to pin: **only the directory goes.** A user who
/// tidies away a finished task must still be able to read what the agent did,
/// which means the transcript, the review notes and the checkpoints all have to
/// survive an archive with nothing but a timestamp changing in the database.
void main() {
  late AppDatabase db;
  late FakeCommandRunner git;
  late List<CommandRequest> requests;

  const worktree = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\.karmashala-worktrees\app-s1',
  );

  /// `git status --porcelain=v1` output for the worktree, scripted per test.
  var statusOutput = '';

  setUp(() {
    statusOutput = '';
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    requests = [];
    git = FakeCommandRunner(
      responder: (request) {
        requests.add(request);
        if (request.arguments.contains('status')) {
          return CommandResult(exitCode: 0, stdout: statusOutput, stderr: '');
        }
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      },
    );
  });
  tearDown(() => db.close());

  void addSession({EnvironmentPath? at = worktree}) => SessionDao(db).insert(
    Session(
      id: 's1',
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: 'Fix the login',
      useWorktree: at != null,
      worktree: at,
      status: SessionStatus.completed,
      createdAt: testTime,
    ),
  );

  void addHistory() {
    SessionEventDao(db).append(
      SessionEvent(
        sessionId: 's1',
        seq: 0,
        type: 'user_message',
        payload: '{"text":"fix the login"}',
        createdAt: testTime,
      ),
    );
    CheckpointDao(db).insert(
      Checkpoint(
        id: 'c1',
        sessionId: 's1',
        repository: worktree,
        sequence: 1,
        treeSha: 'tree',
        commitSha: 'commit',
        parentCommitSha: null,
        headSha: 'head',
        reason: CheckpointReason.turn,
        createdAt: testTime,
      ),
    );
  }

  ({SessionArchiveService service, ProviderContainer container}) build() {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
      ],
    );
    addTearDown(container.dispose);
    return (
      service: container.read(sessionArchiveServiceProvider),
      container: container,
    );
  }

  test('removes the worktree and records when', () async {
    addSession();
    final outcome = await build().service.archive('s1');

    expect(outcome.isArchived, isTrue);
    expect(SessionDao(db).getById('s1')!.isArchived, isTrue);
    expect(SessionDao(db).getById('s1')!.archivedAt, testTime);
    expect(
      requests.map((r) => r.arguments).where((a) => a.contains('worktree')),
      [
        ['-C', r'C:\src\demo\app', 'worktree', 'remove', worktree.path],
      ],
    );
  });

  test('the transcript, review notes and checkpoints all survive', () async {
    addSession();
    addHistory();

    expect((await build().service.archive('s1')).isArchived, isTrue);

    // The session row itself is still there — archiving is not deleting.
    final session = SessionDao(db).getById('s1');
    expect(session, isNotNull);
    expect(session!.title, 'Fix the login');
    // And it still says what the agent did, which is the whole point.
    expect(session.status, SessionStatus.completed);
    expect(
      SessionEventDao(db).listForSession('s1').single.payload,
      '{"text":"fix the login"}',
    );
    expect(CheckpointDao(db).forSession('s1').single.treeSha, 'tree');
  });

  test('refuses while an agent is live in the worktree', () async {
    addSession();
    final harness = build();
    // A real pane in the (fake) terminal controller, so the launcher genuinely
    // sees something alive rather than the test asserting its own stub.
    final terminals = harness.container.read(
      terminalSessionsControllerProvider.notifier,
    );
    terminals.openTab(TerminalProfile.powerShell);
    final paneId = harness.container
        .read(terminalSessionsControllerProvider)
        .tabs
        .single
        .focusedPaneId;
    SessionDao(db).updatePaneId('s1', paneId);

    final outcome = await harness.service.archive('s1');
    expect(outcome.refusal, ArchiveRefusal.stillRunning);
    expect(outcome.message, contains('still running'));
    expect(SessionDao(db).getById('s1')!.isArchived, isFalse);
    expect(requests.any((r) => r.arguments.contains('remove')), isFalse);
  });

  test('refuses to destroy uncommitted work without a confirmation', () async {
    addSession();
    statusOutput = ' M lib/a.dart\n?? lib/b.dart\n';

    final outcome = await build().service.archive('s1');
    expect(outcome.refusal, ArchiveRefusal.uncommittedChanges);
    expect(outcome.changes.length, 2);
    expect(outcome.message, contains('2 uncommitted changes'));
    expect(SessionDao(db).getById('s1')!.isArchived, isFalse);
    expect(
      requests.any((r) => r.arguments.contains('remove')),
      isFalse,
      reason: 'nothing may be removed before the user has confirmed it',
    );
  });

  test('a confirmed archive forces git past the dirty worktree', () async {
    addSession();
    statusOutput = ' M lib/a.dart\n';

    final outcome = await build().service.archive(
      's1',
      discardUncommitted: true,
    );
    expect(outcome.isArchived, isTrue);
    expect(requests.last.arguments, [
      '-C',
      r'C:\src\demo\app',
      'worktree',
      'remove',
      '--force',
      worktree.path,
    ]);
  });

  test(
    'a session working in the repository has no worktree to archive',
    () async {
      addSession(at: null);
      final outcome = await build().service.archive('s1');
      expect(outcome.refusal, ArchiveRefusal.noWorktree);
      expect(outcome.message, contains('no worktree'));
    },
  );

  test('archiving twice is refused, not repeated', () async {
    addSession();
    expect((await build().service.archive('s1')).isArchived, isTrue);
    final second = await build().service.archive('s1');
    expect(second.refusal, ArchiveRefusal.alreadyArchived);
  });

  test(
    'a git failure is reported, and the session is not marked archived',
    () async {
      addSession();
      git.responder = (request) {
        requests.add(request);
        if (request.arguments.contains('remove')) {
          return const CommandResult(
            exitCode: 1,
            stdout: '',
            stderr: 'fatal: validation failed, cannot remove working tree',
          );
        }
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      };

      final outcome = await build().service.archive('s1');
      expect(outcome.isArchived, isFalse);
      expect(outcome.message, contains('cannot remove working tree'));
      expect(SessionDao(db).getById('s1')!.isArchived, isFalse);
    },
  );

  test('a session that is gone is refused rather than crashed into', () async {
    final outcome = await build().service.archive('nope');
    expect(outcome.refusal, ArchiveRefusal.sessionGone);
  });
}
