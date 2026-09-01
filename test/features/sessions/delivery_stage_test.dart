import 'package:karmashala/src/features/git/domain/diff_stat.dart';
import 'package:karmashala/src/features/github/domain/pull_request_snapshot.dart';
import 'package:karmashala/src/features/sessions/domain/delivery_stage.dart';
import 'package:karmashala/src/features/sessions/domain/session_delivery.dart';
import 'package:flutter_test/flutter_test.dart';

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
