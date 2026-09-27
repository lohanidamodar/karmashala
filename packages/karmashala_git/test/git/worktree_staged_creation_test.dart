import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/worktrees.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';
import '../support/fixtures.dart';
import '../support/worktree_processes.dart';

const _repo = EnvironmentPath(environmentId: 'windows', path: r'C:\src\app');
const _worktree = r'C:\src\.karmashala-worktrees\app-s1';

/// Worktree creation in named stages: what each runs, what it shows while it
/// runs, and what a failure or a cancel leaves behind.
void main() {
  late FakeCommandRunner runner;
  late WorktreeService service;
  late WorktreeCreationTracker tracker;

  /// Streamed processes by git subcommand. A missing entry finishes at once.
  late Map<String, FakeProcessHandle> streams;

  /// Run-to-completion answers by git subcommand; anything else succeeds.
  late Map<String, CommandResult> answers;

  String verb(List<String> args) => args.length > 2 ? args[2] : '';

  List<List<String>> ran() => [
    for (final request in runner.requests) request.arguments.skip(2).toList(),
  ];

  List<List<String>> streamed() => [
    for (final request in runner.startRequests)
      request.arguments.skip(2).toList(),
  ];

  setUp(() {
    streams = {};
    answers = {};
    runner = FakeCommandRunner(
      responder: (request) =>
          answers[verb(request.arguments)] ??
          const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      processFactory: (request) =>
          streams[verb(request.arguments)] ?? finishedGit(),
    );
    service = WorktreeService(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environmentOf: environmentsOf([windowsEnv()]),
    );
    tracker = WorktreeCreationTracker(repo: _repo);
  });

  Future<GitWorktree> create({String? baseRef}) => service.createForSession(
    repo: _repo,
    worktreeName: 's1',
    branch: 'session/s1',
    baseRef: baseRef,
    tracker: tracker,
  );

  WorktreeStageStatus stage(WorktreeStage stage) => tracker.record.stage(stage);

  test(
    'every stage runs in order, each through the checkout\'s runner',
    () async {
      answers['remote'] = const CommandResult(
        exitCode: 0,
        stdout: 'origin\n',
        stderr: '',
      );
      answers['ls-files'] = const CommandResult(
        exitCode: 0,
        stdout: '.gitmodules\n',
        stderr: '',
      );

      await create(baseRef: 'origin/main');

      expect(streamed(), [
        ['fetch', '--progress', 'origin', 'main'],
        ['checkout', '--progress'],
        ['submodule', 'update', '--init', '--recursive', '--progress'],
      ]);
      expect(ran(), contains(equals(['remote'])));
      // The fetch runs in the repository; the rest in the new worktree.
      expect(runner.startRequests.map((r) => r.arguments[1]), [
        r'C:\src\app',
        _worktree,
        _worktree,
      ]);
      expect(stage(WorktreeStage.fetch).state, WorktreeStageState.done);
      expect(stage(WorktreeStage.checkout).state, WorktreeStageState.done);
      expect(stage(WorktreeStage.submodules).state, WorktreeStageState.done);
      expect(
        stage(WorktreeStage.setupScript).state,
        WorktreeStageState.skipped,
      );
      expect(stage(WorktreeStage.agent).state, WorktreeStageState.skipped);
      expect(tracker.record.outcome, WorktreeCreationOutcome.succeeded);
    },
  );

  test('nothing to fetch and no submodules are skipped, and say why', () async {
    await create();
    expect(streamed(), [
      ['checkout', '--progress'],
    ]);
    expect(stage(WorktreeStage.fetch).state, WorktreeStageState.skipped);
    expect(stage(WorktreeStage.fetch).detail, contains('own HEAD'));
    expect(stage(WorktreeStage.submodules).state, WorktreeStageState.skipped);
    expect(
      ran(),
      isNot(contains(equals(['remote']))),
      reason: 'no base ref to ask about',
    );
    // The question the failure and cancel tests hold to not being asked.
    expect(ran(), contains(equals(['ls-files', '--', '.gitmodules'])));
  });

  test('the checkout shows git\'s own percentage while it runs', () async {
    final checkout = streams['checkout'] = FakeProcessHandle();
    final creating = create();
    await pumpEventQueue();

    expect(stage(WorktreeStage.checkout).state, WorktreeStageState.running);
    expect(stage(WorktreeStage.checkout).percent, isNull);

    checkout.emitStderr('Updating files:  45% (1800/4000)');
    await pumpEventQueue();
    expect(stage(WorktreeStage.checkout).percent, 45);
    expect(stage(WorktreeStage.checkout).progressLabel, 'Updating files');

    checkout.emitStderr('Updating files: 100% (4000/4000), done.');
    checkout.complete(0);
    await creating;
    expect(stage(WorktreeStage.checkout).percent, 100);
    expect(stage(WorktreeStage.checkout).state, WorktreeStageState.done);
  });

  test(
    'a failing checkout shows its output and removes what git registered',
    () async {
      streams['checkout'] = finishedGit(
        code: 128,
        stderr: [
          'Updating files:  40% (4/10)',
          '\x1B[31merror: unable to create file lib/a.dart: Permission denied\x1B[0m',
          'fatal: cannot create directory',
        ],
      );

      await expectLater(
        create(),
        throwsA(
          isA<GitException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('exited 128'),
              contains('fatal: cannot create directory'),
            ),
          ),
        ),
      );

      final checkout = stage(WorktreeStage.checkout);
      expect(checkout.state, WorktreeStageState.failed);
      expect(checkout.outputTail, [
        'Updating files:  40% (4/10)',
        'error: unable to create file lib/a.dart: Permission denied',
        'fatal: cannot create directory',
      ], reason: 'ANSI-stripped, so it reads as text');
      expect(
        ran(),
        containsAllInOrder([
          ['worktree', 'remove', '--force', _worktree],
          ['worktree', 'prune'],
          ['branch', '-D', 'session/s1'],
        ]),
      );
      expect(
        ran(),
        isNot(contains(equals(['ls-files', '--', '.gitmodules']))),
        reason: 'no later stage runs after a failed checkout',
      );
      expect(stage(WorktreeStage.submodules).state, WorktreeStageState.skipped);
      expect(tracker.record.outcome, WorktreeCreationOutcome.failed);
      expect(
        tracker.record.cleanup,
        contains('Removed the half-made worktree'),
      );
    },
  );

  test(
    'git refusing the add removes nothing, because nothing was made',
    () async {
      answers['worktree'] = const CommandResult(
        exitCode: 128,
        stdout: '',
        stderr: "fatal: a branch named 'session/s1' already exists",
      );
      await expectLater(create(), throwsA(isA<GitException>()));
      expect(stage(WorktreeStage.checkout).detail, contains('already exists'));
      expect(
        ran().where((args) => args.contains('remove') || args.contains('-D')),
        isEmpty,
        reason:
            'deleting a branch this creation did not make would be data loss',
      );
      expect(streamed(), isEmpty);
    },
  );

  group('cancel', () {
    test('mid-checkout kills git, removes the worktree, and says so', () async {
      final checkout = streams['checkout'] = FakeProcessHandle();
      final creating = create();
      await pumpEventQueue();
      checkout.emitStderr('Updating files:  12% (12/100)');
      await pumpEventQueue();
      expect(tracker.canCancel, isTrue);

      tracker.cancel();
      await expectLater(
        creating,
        throwsA(
          isA<WorktreeCreationCancelled>().having(
            (e) => e.cleanup,
            'cleanup',
            contains('Removed the half-made worktree'),
          ),
        ),
      );

      expect(checkout.killed, isTrue);
      expect(
        ran(),
        containsAllInOrder([
          ['worktree', 'remove', '--force', _worktree],
          ['worktree', 'prune'],
          ['branch', '-D', 'session/s1'],
        ]),
      );
      expect(stage(WorktreeStage.checkout).state, WorktreeStageState.failed);
      expect(stage(WorktreeStage.checkout).detail, contains('Cancelled'));
      expect(stage(WorktreeStage.submodules).state, WorktreeStageState.skipped);
      expect(ran(), isNot(contains(equals(['ls-files', '--', '.gitmodules']))));
      expect(tracker.record.outcome, WorktreeCreationOutcome.cancelled);
    });

    test('a cleanup git refuses is named, with how to finish it', () async {
      final checkout = streams['checkout'] = FakeProcessHandle();
      answers['worktree'] = const CommandResult(
        exitCode: 0,
        stdout: '',
        stderr: '',
      );
      final creating = create();
      await pumpEventQueue();
      // The add has run; from here the removal is what fails.
      answers['worktree'] = const CommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'fatal: cannot remove: Device or resource busy',
      );
      tracker.cancel();
      await expectLater(creating, throwsA(isA<WorktreeCreationCancelled>()));

      expect(checkout.killed, isTrue);
      expect(tracker.record.cleanup, contains('Could not remove'));
      expect(tracker.record.cleanup, contains('Device or resource busy'));
      expect(
        tracker.record.cleanup,
        contains('git worktree remove --force $_worktree'),
      );
      expect(
        ran(),
        isNot(contains(equals(['branch', '-D', 'session/s1']))),
        reason: 'git will not delete a branch still checked out',
      );
    });

    test('is refused once the agent stage has begun', () async {
      final created = await service.create(
        repo: _repo,
        worktreeName: 's1',
        branch: 'session/s1',
        launchesAgent: true,
      );
      expect(created.tracker.canCancel, isFalse);
      created.tracker.cancel();
      expect(created.tracker.isCancelled, isFalse);
      created.tracker.agentFailed(StateError('no such agent'));
      expect(
        created.tracker.record.stage(WorktreeStage.agent).state,
        WorktreeStageState.failed,
      );
      expect(created.tracker.record.outcome, WorktreeCreationOutcome.warning);
    });
  });

  test('a failing submodule update keeps the worktree, as a warning', () async {
    answers['ls-files'] = const CommandResult(
      exitCode: 0,
      stdout: '.gitmodules',
      stderr: '',
    );
    streams['submodule'] = finishedGit(
      code: 1,
      stderr: [
        "fatal: clone of 'git@host:vendor.git' into submodule path failed",
      ],
    );
    final worktree = await create();

    expect(worktree.path.path, _worktree);
    final submodules = stage(WorktreeStage.submodules);
    expect(submodules.state, WorktreeStageState.warning);
    expect(submodules.outputTail.single, contains('clone of'));
    expect(ran().where((args) => args.contains('remove')), isEmpty);
    expect(tracker.record.outcome, WorktreeCreationOutcome.warning);
  });

  test('a fetch that fails warns, and branches from what is local', () async {
    answers['remote'] = const CommandResult(
      exitCode: 0,
      stdout: 'origin',
      stderr: '',
    );
    streams['fetch'] = finishedGit(
      code: 128,
      stderr: ['fatal: unable to access remote'],
    );
    await create(baseRef: 'origin/main');
    expect(stage(WorktreeStage.fetch).state, WorktreeStageState.warning);
    expect(stage(WorktreeStage.fetch).outputTail, [
      'fatal: unable to access remote',
    ]);
    expect(stage(WorktreeStage.checkout).state, WorktreeStageState.done);
  });
}
