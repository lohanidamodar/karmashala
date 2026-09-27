import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show GitDelivery;

import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';
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
  late TestMachine db;
  late FakeDataServer server;
  late DataClient data;
  late List<List<String>> gitCalls;
  late List<List<String>> ghCalls;

  const worktree = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\.karmashala-worktrees\app-s1',
  );

  var statusOutput = porcelainV2(
    branch: 'work',
    upstream: 'origin/work',
    ahead: 2,
    behind: 0,
  );
  var remoteUrl = 'git@github.com:popupbits/app.git\n';
  var originHead = 'origin/main\n';
  var revList = '0\t2\n';
  var numstat = '30\t4\tlib/a.dart\n';
  String? prJson;
  var protectionJson =
      '{"url":"u","required_pull_request_reviews":'
      '{"required_approving_review_count":1}}';
  var policyJson =
      '{"data":{"repository":{"mergeCommitAllowed":false,'
      '"squashMergeAllowed":true,"rebaseMergeAllowed":false,'
      '"pullRequest":{"reviewThreads":{"nodes":'
      '[{"isResolved":false},{"isResolved":true}]}}}}}';

  setUp(() async {
    statusOutput = porcelainV2(
      branch: 'work',
      upstream: 'origin/work',
      ahead: 2,
      behind: 0,
    );
    remoteUrl = 'git@github.com:popupbits/app.git\n';
    originHead = 'origin/main\n';
    revList = '0\t2\n';
    numstat = '30\t4\tlib/a.dart\n';
    prJson = null;
    protectionJson =
        '{"url":"u","required_pull_request_reviews":'
        '{"required_approving_review_count":1}}';
    policyJson =
        '{"data":{"repository":{"mergeCommitAllowed":false,'
        '"squashMergeAllowed":true,"rebaseMergeAllowed":false,'
        '"pullRequest":{"reviewThreads":{"nodes":'
        '[{"isResolved":false},{"isResolved":true}]}}}}}';
    gitCalls = [];
    ghCalls = [];
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.connect();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
  });

  CommandResult respond(CommandRequest request) {
    final args = request.arguments;
    if (request.executable == 'gh') {
      ghCalls.add(args);
      if (args.first == 'api') {
        if (args[1] == 'graphql') {
          return CommandResult(exitCode: 0, stdout: policyJson, stderr: '');
        }
        return CommandResult(exitCode: 0, stdout: protectionJson, stderr: '');
      }
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
        dataClientProvider.overrideWithValue(data),
        ...fakeTerminalOverrides(machine: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          server.gitWork.serve(FakeCommandRunnerFactory(
            fallback: FakeCommandRunner(responder: respond),
          )),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  void addSession(String id, {EnvironmentPath? at = worktree}) =>
      db.server.sessionRows.insert(
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
      statusOutput = porcelainV2(
        branch: 'work',
        upstream: 'origin/work',
        ahead: 2,
        behind: 0,
        modified: ['lib/a.dart'],
        untracked: ['new.txt'],
      );

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

    statusOutput = porcelainV2(
      branch: 'work',
      upstream: 'origin/work',
      ahead: 2,
      behind: 0,
      modified: ['a'],
    );
    expect(
      (await harness().read(sessionDeliveryProvider('s1').future)).stage,
      DeliveryStage.working,
    );

    statusOutput = porcelainV2(
      branch: 'work',
      upstream: 'origin/work',
      ahead: 2,
      behind: 0,
    );
    expect(
      (await harness().read(sessionDeliveryProvider('s1').future)).stage,
      DeliveryStage.committed,
    );

    statusOutput = porcelainV2(
      branch: 'work',
      upstream: 'origin/work',
      ahead: 0,
      behind: 0,
    );
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

  group('the forge policy — the second gh process', () {
    const openPr =
        '{"number":9,"state":"OPEN","url":"https://github.com/o/r/pull/9",'
        '"mergeable":"MERGEABLE","statusCheckRollup":'
        '[{"status":"COMPLETED","conclusion":"SUCCESS"}]}';

    test('an open PR buys the merge settings and the open threads', () async {
      addSession('s1', at: null);
      prJson = openPr;

      final delivery = await harness().read(
        sessionDeliveryProvider('s1').future,
      );

      expect(delivery.mergeStrategies.squash, isTrue);
      expect(delivery.mergeStrategies.mergeCommit, isFalse);
      expect(delivery.pullRequest?.unresolvedReviewThreads, 1);
      expect(ghCalls.where((c) => c.first == 'api'), hasLength(1));
    });

    test('no pull request, no query — a branch costs nothing', () async {
      addSession('s1', at: null);
      prJson = null;

      final delivery = await harness().read(
        sessionDeliveryProvider('s1').future,
      );

      expect(delivery.mergeStrategies, MergeStrategies.unknown);
      expect(ghCalls.where((c) => c.first == 'api'), isEmpty);
    });

    test('a closed pull request is not asked about either', () async {
      addSession('s1', at: null);
      prJson = '{"number":9,"state":"MERGED","url":"u"}';

      await harness().read(sessionDeliveryProvider('s1').future);

      expect(ghCalls.where((c) => c.first == 'api'), isEmpty);
    });

    test('the Explorer\'s row never pays for it', () async {
      // The local provider is what a tree draws per row. One GraphQL query per
      // visible session for a fact nineteen of them do not draw is the bill
      // this split exists to refuse.
      addSession('s1', at: null);
      prJson = openPr;

      await harness().read(sessionLocalDeliveryProvider('s1').future);

      expect(ghCalls, isEmpty);
    });

    test('a query that fails leaves the strip exactly as it was', () async {
      addSession('s1', at: null);
      prJson = openPr;
      policyJson = 'not json at all';

      final delivery = await harness().read(
        sessionDeliveryProvider('s1').future,
      );

      expect(delivery.mergeStrategies, MergeStrategies.unknown);
      expect(delivery.pullRequest?.unresolvedReviewThreads, isNull);
      // And the pull request itself still arrived: the two halves fail apart.
      expect(delivery.pullRequest?.number, 9);
    });
  });

  group('the branch-protection read behind a BLOCKED merge', () {
    // One extra `gh`, only when the status is BLOCKED, only on the tick that
    // observed it. Every open pull request in a protected repository reports
    // BLOCKED, so paying for this on any other status would be a process per
    // tick for a sentence nobody reads.
    List<List<String>> protectionCalls() =>
        ghCalls.where((c) => c.first == 'api' && c[1] != 'graphql').toList();

    test('a blocked merge buys the rule, once, for the base branch', () async {
      addSession('s1', at: null);
      prJson =
          '{"number":9,"state":"OPEN","url":"u","mergeable":"MERGEABLE",'
          '"mergeStateStatus":"BLOCKED","baseRefName":"main",'
          '"statusCheckRollup":[]}';

      final delivery = await harness().read(
        sessionDeliveryProvider('s1').future,
      );

      expect(protectionCalls(), [
        ['api', 'repos/{owner}/{repo}/branches/main/protection'],
      ]);
      expect(delivery.branchProtection.requiredApprovals, 1);
    });

    test('every other merge state costs nothing at all', () async {
      addSession('s1', at: null);
      prJson =
          '{"number":9,"state":"OPEN","url":"u","mergeable":"MERGEABLE",'
          '"mergeStateStatus":"CLEAN","baseRefName":"main",'
          '"statusCheckRollup":[]}';

      final delivery = await harness().read(
        sessionDeliveryProvider('s1').future,
      );

      expect(protectionCalls(), isEmpty);
      expect(delivery.branchProtection, BranchProtection.unknown);
    });

    test('a refused read leaves the strip exactly as it was', () async {
      addSession('s1', at: null);
      prJson =
          '{"number":9,"state":"OPEN","url":"u","mergeable":"MERGEABLE",'
          '"mergeStateStatus":"BLOCKED","baseRefName":"main",'
          '"statusCheckRollup":[]}';
      protectionJson = 'not json at all';

      final delivery = await harness().read(
        sessionDeliveryProvider('s1').future,
      );

      expect(delivery.branchProtection.status, BranchProtectionRead.unknown);
      expect(delivery.pullRequest?.number, 9);
    });
  });

  test('however many sessions share a worktree, git is asked once', () async {
    for (var i = 0; i < 5; i++) {
      addSession('s$i');
    }
    final container = harness();
    for (var i = 0; i < 5; i++) {
      await container.read(sessionDeliveryProvider('s$i').future);
    }

    // One reading of the one worktree, asked of the server — which measures
    // it against the repository it was made from.
    expect(server.gitWork.asked.whereType<GitDelivery>(), hasLength(1));
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
      statusOutput = porcelainV2(branch: 'work', ahead: 0, behind: 0);
      final container = ProviderContainer(
        overrides: [
          dataClientProvider.overrideWithValue(data),
          ...fakeTerminalOverrides(machine: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          commandRunnerFactoryProvider.overrideWithValue(
            server.gitWork.serve(FakeCommandRunnerFactory(
              fallback: FakeCommandRunner(
                responder: (request) {
                  if (request.arguments.contains('status')) {
                    // The repository is asked second; give it its own branch.
                    asked++;
                    return CommandResult(
                      exitCode: 0,
                      stdout: asked == 1
                          ? porcelainV2(branch: 'work', ahead: 0, behind: 0)
                          : porcelainV2(branch: 'main', ahead: 0, behind: 0),
                      stderr: '',
                    );
                  }
                  return respond(request);
                },
              ),
            )),
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
    db.server.sessionRows.markArchived('s1', testTime);

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
        dataClientProvider.overrideWithValue(data),
        ...fakeTerminalOverrides(machine: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          server.gitWork.serve(FakeCommandRunnerFactory(
            fallback: FakeCommandRunner(
              responder: (request) {
                if (request.executable == 'gh') {
                  throw CommandException('gh is not installed');
                }
                return respond(request);
              },
            ),
          )),
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
          dataClientProvider.overrideWithValue(data),
          ...fakeTerminalOverrides(machine: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          commandRunnerFactoryProvider.overrideWithValue(
            server.gitWork.serve(FakeCommandRunnerFactory(
              fallback: FakeCommandRunner(
                responder: (_) => const CommandResult(
                  exitCode: 128,
                  stdout: '',
                  stderr: 'fatal: not a git repository',
                ),
              ),
            )),
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
