import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/delivery_providers.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/delivery_action.dart';
import 'package:chitragupta/src/features/sessions/domain/delivery_stage.dart';
import 'package:chitragupta/src/features/sessions/domain/session.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// The delivery providers: what they ask git and `gh`, how often, and what they
/// make of the answers.
///
/// Two properties matter as much as the values. **Cost**: however many sessions
/// share a working tree, it is asked about once — a tree that ran this per row
/// would be unusable, and nothing in a widget test would notice because every
/// answer would still be right. And **honesty**: a probe that fails must leave a
/// null behind, never a confident zero.
void main() {
  late AppDatabase db;
  late List<List<String>> gitCalls;
  late List<List<String>> ghCalls;

  const worktree = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\.chitragupta-worktrees\app-s1',
  );

  var statusOutput = '## work...origin/work [ahead 2]\n';
  var remoteUrl = 'git@github.com:popupbits/app.git\n';
  var originHead = 'origin/main\n';
  var revList = '0\t2\n';
  var numstat = '30\t4\tlib/a.dart\n';
  String? prJson;

  setUp(() {
    statusOutput = '## work...origin/work [ahead 2]\n';
    remoteUrl = 'git@github.com:popupbits/app.git\n';
    originHead = 'origin/main\n';
    revList = '0\t2\n';
    numstat = '30\t4\tlib/a.dart\n';
    prJson = null;
    gitCalls = [];
    ghCalls = [];
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
  });
  tearDown(() => db.close());

  CommandResult respond(CommandRequest request) {
    final args = request.arguments;
    if (request.executable == 'gh') {
      ghCalls.add(args);
      final json = prJson;
      if (json == null) {
        return const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'no pull requests found for branch "work"',
        );
      }
      return CommandResult(exitCode: 0, stdout: json, stderr: '');
    }
    gitCalls.add(args);
    if (args.contains('status')) {
      return CommandResult(exitCode: 0, stdout: statusOutput, stderr: '');
    }
    if (args.contains('get-url')) {
      return remoteUrl.isEmpty
          ? const CommandResult(exitCode: 2, stdout: '', stderr: 'no origin')
          : CommandResult(exitCode: 0, stdout: remoteUrl, stderr: '');
    }
    if (args.contains('origin/HEAD')) {
      return originHead.isEmpty
          ? const CommandResult(exitCode: 128, stdout: '', stderr: 'no HEAD')
          : CommandResult(exitCode: 0, stdout: originHead, stderr: '');
    }
    if (args.contains('rev-list')) {
      return CommandResult(exitCode: 0, stdout: revList, stderr: '');
    }
    if (args.contains('--numstat')) {
      return CommandResult(exitCode: 0, stdout: numstat, stderr: '');
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  ProviderContainer harness() {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(
            fallback: FakeCommandRunner(responder: respond),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  void addSession(String id, {EnvironmentPath? at = worktree}) =>
      SessionDao(db).insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Session $id',
          useWorktree: at != null,
          worktree: at,
          status: SessionStatus.running,
          createdAt: testTime,
        ),
      );

  test(
    'reads branch, upstream, dirt, lines and distance from one checkout',
    () async {
      addSession('s1', at: null);
      statusOutput =
          '## work...origin/work [ahead 2]\n M lib/a.dart\n?? new.txt\n';

      final delivery = await harness().read(
        sessionDeliveryProvider('s1').future,
      );

      expect(delivery.branch, 'work');
      expect(delivery.upstream, 'origin/work');
      expect(delivery.unpushed, 2);
      expect(delivery.dirtyFiles, 2);
      expect(delivery.baseBranch, 'origin/main');
      expect(delivery.defaultBranch, 'main');
      expect(delivery.aheadOfBase, 2);
      expect(delivery.lineLabel, '+30 −4');
      expect(
        delivery.remote?.commitUrl('abc'),
        'https://github.com/popupbits/app/commit/abc',
      );
      expect(delivery.stage, DeliveryStage.working);
    },
  );

  test('the stage walks the line as git answers differently', () async {
    addSession('s1', at: null);

    statusOutput = '## work...origin/work [ahead 2]\n M a\n';
    expect(
      (await harness().read(sessionDeliveryProvider('s1').future)).stage,
      DeliveryStage.working,
    );

    statusOutput = '## work...origin/work [ahead 2]\n';
    expect(
      (await harness().read(sessionDeliveryProvider('s1').future)).stage,
      DeliveryStage.committed,
    );

    statusOutput = '## work...origin/work\n';
    expect(
      (await harness().read(sessionDeliveryProvider('s1').future)).stage,
      DeliveryStage.pushed,
    );

    prJson =
        '{"number":9,"state":"OPEN","url":"https://github.com/o/r/pull/9",'
        '"mergeable":"MERGEABLE","statusCheckRollup":'
        '[{"status":"COMPLETED","conclusion":"SUCCESS"}]}';
    expect(
      (await harness().read(sessionDeliveryProvider('s1').future)).stage,
      DeliveryStage.checksPassing,
    );

    prJson =
        '{"number":9,"state":"MERGED","url":"https://github.com/o/r/pull/9"}';
    expect(
      (await harness().read(sessionDeliveryProvider('s1').future)).stage,
      DeliveryStage.merged,
    );
  });

  test('however many sessions share a worktree, git is asked once', () async {
    for (var i = 0; i < 5; i++) {
      addSession('s$i');
    }
    final container = harness();
    for (var i = 0; i < 5; i++) {
      await container.read(sessionDeliveryProvider('s$i').future);
    }

    final statuses = gitCalls.where((a) => a.contains('status')).toList();
    // Two working trees are involved — the worktree and the repository it was
    // made from, which the base branch is measured against — and no more.
    expect(statuses.length, 2);
    expect(ghCalls.where((a) => a.contains('view')).length, 1);
  });

  test('the two-minute poll costs one gh per checkout being looked at', () async {
    // Written while hunting a periodic hitch, where this poll was the leading
    // suspect: a `gh` process per checkout every two minutes, on a machine with
    // seventeen repositories, would be a plausible once-a-minute stall.
    //
    // It is not, and the reason is which provider the tree reads. Every row in
    // the Explorer watches `sessionLocalDeliveryProvider`, which never touches
    // `gh`; only `sessionDeliveryProvider` does, and that one exists for the
    // session whose strip is on screen. So a tick costs one `gh` per *watched*
    // checkout — one, in practice — not one per session and not one per
    // repository.
    for (var i = 0; i < 5; i++) {
      addSession('s$i');
    }
    final container = harness();

    // What the Explorer draws: every row, none of them asking `gh`.
    for (var i = 0; i < 5; i++) {
      await container.read(sessionLocalDeliveryProvider('s$i').future);
    }
    expect(ghCalls, isEmpty, reason: 'a tree row must never start a gh');

    // What the strip draws: one session, kept alive across the tick the way a
    // widget watching it would.
    final subscription = container.listen(
      sessionDeliveryProvider('s0'),
      (_, _) {},
    );
    addTearDown(subscription.close);
    await container.read(sessionDeliveryProvider('s0').future);
    final afterFirstRead = ghCalls.length;

    container.read(deliveryPollProvider.notifier).state++;
    await container.read(sessionDeliveryProvider('s0').future);

    expect(afterFirstRead, 1);
    expect(
      ghCalls.length - afterFirstRead,
      1,
      reason: 'one tick, one gh — not one per session sharing the checkout',
    );
  });

  test('a repository with no remote asks gh nothing at all', () async {
    addSession('s1', at: null);
    remoteUrl = '';

    final delivery = await harness().read(sessionDeliveryProvider('s1').future);
    expect(delivery.hasRemote, isFalse);
    expect(ghCalls, isEmpty);
    expect(
      deliveryActionsFor(delivery).map((o) => o.action),
      isNot(contains(DeliveryAction.push)),
    );
  });

  test(
    'no origin/HEAD falls back to the branch the repository has out',
    () async {
      addSession('s1');
      originHead = '';
      // The worktree is on `work`; the repository itself is on `main`.
      var asked = 0;
      statusOutput = '## work\n';
      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(
              fallback: FakeCommandRunner(
                responder: (request) {
                  if (request.arguments.contains('status')) {
                    // The repository is asked second; give it its own branch.
                    asked++;
                    return CommandResult(
                      exitCode: 0,
                      stdout: asked == 1 ? '## work\n' : '## main\n',
                      stderr: '',
                    );
                  }
                  return respond(request);
                },
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final delivery = await container.read(
        sessionDeliveryProvider('s1').future,
      );
      expect(delivery.baseBranch, 'main');
      expect(delivery.aheadOfBase, 2);
    },
  );

  test('an archived session reports archived, offers no prompts, and asks '
      'git nothing — its directory is gone', () async {
    addSession('s1');
    SessionDao(db).markArchived('s1', testTime);

    final container = harness();
    final delivery = await container.read(sessionDeliveryProvider('s1').future);
    expect(delivery.archived, isTrue);
    expect(delivery.stage, DeliveryStage.archived);
    expect(
      container
          .read(sessionDeliveryActionsProvider('s1'))
          .where((o) => o.action.isPrompt),
      isEmpty,
    );
    expect(gitCalls, isEmpty);
    expect(ghCalls, isEmpty);
  });

  test('gh being unusable leaves no pull request, never a wrong one', () async {
    addSession('s1', at: null);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(
            fallback: FakeCommandRunner(
              responder: (request) {
                if (request.executable == 'gh') {
                  throw CommandException('gh is not installed');
                }
                return respond(request);
              },
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final delivery = await container.read(sessionDeliveryProvider('s1').future);
    expect(delivery.pullRequest, isNull);
    expect(delivery.stage, DeliveryStage.committed);
  });

  test(
    'a directory that is not a repository says nothing, and does not throw',
    () async {
      addSession('s1', at: null);
      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(
              fallback: FakeCommandRunner(
                responder: (_) => const CommandResult(
                  exitCode: 128,
                  stdout: '',
                  stderr: 'fatal: not a git repository',
                ),
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final delivery = await container.read(
        sessionDeliveryProvider('s1').future,
      );
      expect(delivery.branch, isNull);
      expect(delivery.dirtyFiles, isNull);
      expect(delivery.stage, DeliveryStage.working);
    },
  );
}
