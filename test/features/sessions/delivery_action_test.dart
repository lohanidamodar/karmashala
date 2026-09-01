import 'package:karmashala/src/features/github/domain/pull_request_snapshot.dart';
import 'package:karmashala/src/features/sessions/domain/delivery_action.dart';
import 'package:karmashala/src/features/sessions/domain/session_delivery.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the delivery strip offers, and which one it highlights.
///
/// Two biases pull in opposite directions and both are deliberate: a prompt is
/// withheld only on an established fact (a wasted click costs one sentence in
/// the transcript), while a blocked step is *shown disabled* with the reason,
/// because the user needs to see that something is in the way.
void main() {
  DeliveryAction? primaryOf(SessionDelivery? delivery) {
    final offered = deliveryActionsFor(delivery);
    final primary = offered.where((o) => o.isPrimary);
    return primary.isEmpty ? null : primary.single.action;
  }

  Set<DeliveryAction> actionsOf(SessionDelivery? delivery) =>
      deliveryActionsFor(delivery).map((o) => o.action).toSet();

  OfferedAction? entryFor(SessionDelivery d, DeliveryAction action) {
    final matches = deliveryActionsFor(d).where((o) => o.action == action);
    return matches.isEmpty ? null : matches.single;
  }

  const pr = PullRequestSnapshot(
    number: 7,
    state: PullRequestState.open,
    url: 'https://github.com/o/r/pull/7',
    mergeable: true,
  );

  group('the primary action follows the stage', () {
    test('uncommitted work asks to commit', () {
      expect(
        primaryOf(const SessionDelivery(dirtyFiles: 2, hasRemote: true)),
        DeliveryAction.commit,
      );
    });

    test('commits with nowhere to be ask to push', () {
      expect(
        primaryOf(
          const SessionDelivery(
            branch: 'work',
            hasRemote: true,
            dirtyFiles: 0,
            aheadOfBase: 2,
          ),
        ),
        DeliveryAction.push,
      );
    });

    test('a pushed branch asks to open a PR', () {
      expect(
        primaryOf(
          const SessionDelivery(
            branch: 'work',
            hasRemote: true,
            upstream: 'origin/work',
            dirtyFiles: 0,
            aheadOfBase: 2,
            unpushed: 0,
          ),
        ),
        DeliveryAction.openPullRequest,
      );
    });

    test('an open PR with checks asks to look at them', () {
      expect(
        primaryOf(
          const SessionDelivery(
            hasRemote: true,
            dirtyFiles: 0,
            pullRequest: PullRequestSnapshot(
              number: 7,
              state: PullRequestState.open,
              url: 'https://github.com/o/r/pull/7',
              checks: ChecksSummary(pending: 1),
            ),
          ),
        ),
        DeliveryAction.viewChecks,
      );
    });

    test('a green PR asks to merge', () {
      expect(
        primaryOf(
          const SessionDelivery(
            hasRemote: true,
            dirtyFiles: 0,
            pullRequest: PullRequestSnapshot(
              number: 7,
              state: PullRequestState.open,
              url: 'https://github.com/o/r/pull/7',
              mergeable: true,
              checks: ChecksSummary(passed: 2),
            ),
          ),
        ),
        DeliveryAction.merge,
      );
    });

    test('a merged PR with a worktree asks to archive it', () {
      expect(
        primaryOf(
          const SessionDelivery(
            hasRemote: true,
            dirtyFiles: 0,
            hasWorktree: true,
            pullRequest: PullRequestSnapshot(
              number: 7,
              state: PullRequestState.merged,
            ),
          ),
        ),
        DeliveryAction.archive,
      );
    });

    test('an uncommitted edit outranks the pull request it belongs to', () {
      expect(
        primaryOf(
          const SessionDelivery(
            hasRemote: true,
            dirtyFiles: 3,
            pullRequest: pr,
          ),
        ),
        DeliveryAction.commit,
      );
    });

    test('an archived session has nothing next', () {
      expect(
        primaryOf(const SessionDelivery(archived: true, hasRemote: true)),
        isNull,
      );
    });
  });

  group('prompts are withheld only on established facts', () {
    test('everything unknown offers the whole prompt row', () {
      final actions = actionsOf(null);
      expect(actions, contains(DeliveryAction.commit));
      expect(actions, contains(DeliveryAction.push));
      expect(actions, contains(DeliveryAction.openPullRequest));
      expect(actions, contains(DeliveryAction.runTests));
    });

    test('no remote withholds push and open-PR, not commit', () {
      final actions = actionsOf(const SessionDelivery(hasRemote: false));
      expect(actions, isNot(contains(DeliveryAction.push)));
      expect(actions, isNot(contains(DeliveryAction.openPullRequest)));
      expect(actions, contains(DeliveryAction.commit));
      expect(actions, contains(DeliveryAction.runTests));
    });

    test('the default branch has nothing to propose', () {
      expect(
        actionsOf(
          const SessionDelivery(
            branch: 'main',
            defaultBranch: 'main',
            hasRemote: true,
          ),
        ),
        isNot(contains(DeliveryAction.openPullRequest)),
      );
    });

    test('provably nothing ahead withholds open-PR', () {
      expect(
        actionsOf(
          const SessionDelivery(
            branch: 'work',
            hasRemote: true,
            aheadOfBase: 0,
          ),
        ),
        isNot(contains(DeliveryAction.openPullRequest)),
      );
    });

    test('an open PR replaces open-PR with view and merge', () {
      final actions = actionsOf(
        const SessionDelivery(hasRemote: true, pullRequest: pr),
      );
      expect(actions, isNot(contains(DeliveryAction.openPullRequest)));
      expect(actions, contains(DeliveryAction.viewPullRequest));
      expect(actions, contains(DeliveryAction.merge));
    });

    test('a PR with no link offers nothing to view', () {
      final actions = actionsOf(
        const SessionDelivery(
          hasRemote: true,
          pullRequest: PullRequestSnapshot(
            number: 7,
            state: PullRequestState.open,
          ),
        ),
      );
      expect(actions, isNot(contains(DeliveryAction.viewPullRequest)));
      expect(actions, isNot(contains(DeliveryAction.viewChecks)));
    });
  });

  group('blocked steps are shown, with the reason', () {
    OfferedAction merge(PullRequestSnapshot snapshot) => entryFor(
      SessionDelivery(hasRemote: true, dirtyFiles: 0, pullRequest: snapshot),
      DeliveryAction.merge,
    )!;

    test('failing checks disable merge and say so', () {
      final entry = merge(
        const PullRequestSnapshot(
          number: 7,
          state: PullRequestState.open,
          url: 'u',
          mergeable: true,
          checks: ChecksSummary(failed: 1),
        ),
      );
      expect(entry.isEnabled, isFalse);
      expect(entry.disabledReason, 'Checks are failing.');
      // The stage is checks-failing, so looking at them is what comes next.
      expect(entry.isPrimary, isFalse);
    });

    test(
      'a blocked step still becomes the primary one, carrying its reason',
      () {
        // Green checks, so merging is next — but a reviewer stands in the way.
        // Promoting an unrelated button instead would hide the blocker.
        final entry = merge(
          const PullRequestSnapshot(
            number: 7,
            state: PullRequestState.open,
            url: 'u',
            mergeable: true,
            checks: ChecksSummary(passed: 2),
            reviewDecision: ReviewDecision.changesRequested,
          ),
        );
        expect(entry.isPrimary, isTrue);
        expect(entry.disabledReason, 'A reviewer asked for changes.');
      },
    );

    test('requested changes disable merge', () {
      expect(
        merge(
          const PullRequestSnapshot(
            number: 7,
            state: PullRequestState.open,
            mergeable: true,
            reviewDecision: ReviewDecision.changesRequested,
          ),
        ).disabledReason,
        'A reviewer asked for changes.',
      );
    });

    test('a conflict disables merge', () {
      expect(
        merge(
          const PullRequestSnapshot(
            number: 7,
            state: PullRequestState.open,
            mergeable: false,
          ),
        ).disabledReason,
        'GitHub reports a merge conflict.',
      );
    });

    test('a draft disables merge', () {
      expect(
        merge(
          const PullRequestSnapshot(
            number: 7,
            state: PullRequestState.open,
            mergeable: true,
            isDraft: true,
          ),
        ).disabledReason,
        'The pull request is still a draft.',
      );
    });

    test('unknown mergeability does not disable it — offer it anyway', () {
      expect(
        merge(
          const PullRequestSnapshot(number: 7, state: PullRequestState.open),
        ).isEnabled,
        isTrue,
      );
    });

    test('a live agent disables archiving its worktree', () {
      final entry = entryFor(
        const SessionDelivery(hasWorktree: true, agentRunning: true),
        DeliveryAction.archive,
      )!;
      expect(entry.isEnabled, isFalse);
      expect(entry.disabledReason, contains('still running'));
    });

    test('no worktree, nothing to archive', () {
      expect(
        actionsOf(const SessionDelivery(hasWorktree: false)),
        isNot(contains(DeliveryAction.archive)),
      );
    });
  });

  test('an archived session offers no prompts — its worktree is gone', () {
    final offered = deliveryActionsFor(
      const SessionDelivery(
        archived: true,
        hasWorktree: true,
        hasRemote: true,
        pullRequest: pr,
      ),
    );
    expect(offered.every((o) => !o.action.isPrompt), isTrue);
    expect(
      offered.map((o) => o.action),
      contains(DeliveryAction.viewPullRequest),
    );
  });

  test('exactly the four agent steps are prompts', () {
    expect(DeliveryAction.values.where((a) => a.isPrompt).toSet(), {
      DeliveryAction.commit,
      DeliveryAction.push,
      DeliveryAction.openPullRequest,
      DeliveryAction.merge,
      DeliveryAction.runTests,
    });
  });

  test('the row keeps the pipeline order after the primary one', () {
    final order = deliveryActionsFor(
      const SessionDelivery(
        branch: 'work',
        hasRemote: true,
        dirtyFiles: 0,
        aheadOfBase: 3,
        hasWorktree: true,
      ),
    ).map((o) => o.action).toList();
    expect(order.first, DeliveryAction.push);
    expect(order.sublist(1), [
      DeliveryAction.commit,
      DeliveryAction.openPullRequest,
      DeliveryAction.runTests,
      DeliveryAction.archive,
    ]);
  });
}
