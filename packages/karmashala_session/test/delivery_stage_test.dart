import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:test/test.dart';

/// The stage machine: working → committed → pushed → pr-open →
/// checks-passing/failing → merged → archived.
///
/// The rule under test throughout is that a stage is claimed only on facts git
/// or `gh` positively established. "Pushed" in particular must never be guessed:
/// telling a user their work is on the remote when it is not is the one mistake
/// here with a cost.
void main() {
  SessionDelivery delivery({
    String? branch = 'work',
    String? upstream,
    int? dirty,
    int? ahead,
    int? unpushed,
    PullRequestSnapshot? pr,
    bool archived = false,
  }) => SessionDelivery(
    branch: branch,
    baseBranch: 'origin/main',
    upstream: upstream,
    hasRemote: true,
    dirtyFiles: dirty,
    aheadOfBase: ahead,
    unpushed: unpushed,
    pullRequest: pr,
    archived: archived,
  );

  PullRequestSnapshot pr({
    PullRequestState state = PullRequestState.open,
    ChecksSummary checks = ChecksSummary.none,
  }) => PullRequestSnapshot(number: 3, state: state, checks: checks);

  group('local stages', () {
    test('nothing done yet is working', () {
      expect(delivery(dirty: 0, ahead: 0).stage, DeliveryStage.working);
    });

    test('uncommitted changes are working', () {
      expect(delivery(dirty: 3, ahead: 2).stage, DeliveryStage.working);
    });

    test('commits with no upstream are committed, not pushed', () {
      expect(
        delivery(dirty: 0, ahead: 2, unpushed: null).stage,
        DeliveryStage.committed,
      );
    });

    test('commits the upstream does not have are committed', () {
      expect(
        delivery(
          dirty: 0,
          ahead: 2,
          upstream: 'origin/work',
          unpushed: 2,
        ).stage,
        DeliveryStage.committed,
      );
    });

    test('an upstream that has everything is pushed', () {
      expect(
        delivery(
          dirty: 0,
          ahead: 2,
          upstream: 'origin/work',
          unpushed: 0,
        ).stage,
        DeliveryStage.pushed,
      );
    });

    test('an unreadable unpushed count stops at committed', () {
      expect(
        delivery(dirty: 0, ahead: 2, upstream: 'origin/work').stage,
        DeliveryStage.committed,
      );
    });
  });

  group('pull request stages', () {
    test('an open PR with no checks is pr-open', () {
      expect(delivery(pr: pr()).stage, DeliveryStage.prOpen);
    });

    test('pending checks are still pr-open', () {
      expect(
        delivery(pr: pr(checks: const ChecksSummary(pending: 2))).stage,
        DeliveryStage.prOpen,
      );
    });

    test('a green build is checks-passing', () {
      expect(
        delivery(pr: pr(checks: const ChecksSummary(passed: 3))).stage,
        DeliveryStage.checksPassing,
      );
    });

    test('a red build is checks-failing even beside a pending one', () {
      expect(
        delivery(
          pr: pr(checks: const ChecksSummary(failed: 1, pending: 2)),
        ).stage,
        DeliveryStage.checksFailing,
      );
    });

    test('a merged PR is merged', () {
      expect(
        delivery(pr: pr(state: PullRequestState.merged)).stage,
        DeliveryStage.merged,
      );
    });

    test('the PR outranks an uncommitted edit — the stage is how far the work '
        'has got, not what to do next', () {
      expect(
        delivery(
          dirty: 4,
          pr: pr(checks: const ChecksSummary(passed: 1)),
        ).stage,
        DeliveryStage.checksPassing,
      );
    });

    test('a closed, unmerged PR is not progress; the local facts decide', () {
      expect(
        delivery(
          dirty: 0,
          ahead: 1,
          upstream: 'origin/work',
          unpushed: 0,
          pr: pr(state: PullRequestState.closed),
        ).stage,
        DeliveryStage.pushed,
      );
    });
  });

  test('archived outranks everything, including a merged PR', () {
    expect(
      delivery(pr: pr(state: PullRequestState.merged), archived: true).stage,
      DeliveryStage.archived,
    );
  });

  test('nothing known at all is working, not an error', () {
    expect(SessionDelivery.unknown.stage, DeliveryStage.working);
  });

  group('behind the base, and conflicting with it', () {
    // Neither is a stage. A branch that conflicts with its base has travelled
    // exactly as far as one that does not — the stage line is how far the work
    // got, and these are answers to a different question ("what is in the
    // way") that `deliveryActionsFor` asks instead.
    test('a local count above zero is proof', () {
      expect(
        const SessionDelivery(behindBase: 3).isBehindBase,
        isTrue,
      );
    });

    test('a count of zero is proof of nothing, because nothing fetches', () {
      // The count is measured against whatever origin/main this clone last
      // saw, and this app never runs `git fetch`. Zero means "no commits on
      // this disk that this branch lacks", which is not "up to date".
      expect(const SessionDelivery(behindBase: 0).isBehindBase, isFalse);
      expect(SessionDelivery.unknown.isBehindBase, isFalse);
    });

    test("GitHub's BEHIND carries it when the local ref is stale", () {
      expect(
        const SessionDelivery(
          behindBase: 0,
          pullRequest: PullRequestSnapshot(
            number: 1,
            state: PullRequestState.open,
            mergeStateStatus: MergeStateStatus.behind,
          ),
        ).isBehindBase,
        isTrue,
      );
    });

    test('a masked reading is not a denial', () {
      // BLOCKED outranks BEHIND on the wire, so a blocked pull request may or
      // may not also be behind. The local count is still allowed to answer.
      expect(
        const SessionDelivery(
          behindBase: 2,
          pullRequest: PullRequestSnapshot(
            number: 1,
            state: PullRequestState.open,
            mergeStateStatus: MergeStateStatus.blocked,
          ),
        ).isBehindBase,
        isTrue,
      );
    });

    test('either conflict reading is enough, and neither is the default', () {
      PullRequestSnapshot pr({bool? mergeable, MergeStateStatus? state}) =>
          PullRequestSnapshot(
            number: 1,
            state: PullRequestState.open,
            mergeable: mergeable,
            mergeStateStatus: state,
          );
      expect(
        SessionDelivery(pullRequest: pr(mergeable: false)).hasConflict,
        isTrue,
      );
      expect(
        SessionDelivery(
          pullRequest: pr(state: MergeStateStatus.dirty),
        ).hasConflict,
        isTrue,
      );
      // Not computed yet must never read as a conflict: GitHub answers UNKNOWN
      // until it has, and every freshly opened pull request passes through it.
      expect(SessionDelivery(pullRequest: pr()).hasConflict, isFalse);
      expect(SessionDelivery.unknown.hasConflict, isFalse);
    });
  });

  group('what the row reads', () {
    test('line counts render as +N -M', () {
      expect(
        const SessionDelivery(
          lines: DiffStat(added: 120, removed: 18, files: 4),
        ).lineLabel,
        '+120 −18',
      );
    });

    test('an empty diff has nothing to say', () {
      expect(const SessionDelivery(lines: DiffStat.none).lineLabel, isNull);
      expect(SessionDelivery.unknown.lineLabel, isNull);
    });

    test('failing and passing are the same distance along the line', () {
      expect(
        DeliveryStage.checksFailing.order,
        DeliveryStage.checksPassing.order,
      );
      expect(DeliveryStage.checksFailing.isTrouble, isTrue);
    });
  });
}
