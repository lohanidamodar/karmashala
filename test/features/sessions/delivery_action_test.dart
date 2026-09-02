import 'package:karmashala/src/features/github/domain/merge_strategies.dart';
import 'package:karmashala/src/features/github/domain/pull_request_snapshot.dart';
import 'package:karmashala/src/features/sessions/domain/delivery_action.dart';
import 'package:karmashala/src/features/sessions/domain/session_delivery.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the delivery strip offers, and which one it highlights.
///
/// Three biases, and they do not all point the same way. A **pipeline** prompt
/// — commit, push, open a PR — is withheld only on an established fact, because
/// a wasted click costs one sentence in the transcript while a missing button
/// hides the feature. An **exception** prompt — resolve conflicts, address
/// review, update — is offered only on an established fact, because it is a
/// claim about the branch rather than an offer, and because the ordering below
/// lets any exception outrank the true next step. And a blocked step is *shown
/// disabled* with its reason, because the user needs to see that something is
/// in the way.
///
/// The other property under test throughout is that the strip stays **one next
/// step**. Thirteen actions can be offered and exactly one is ever primary; the
/// tests below assert which one, state by state, because a row that promotes
/// the wrong thing is indistinguishable from a menu.
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
        // Green checks, so merging is next — but GitHub is refusing for a rule
        // it will not name. There is no action that fixes an unnamed
        // branch-protection rule, so promoting an unrelated button would leave
        // the row saying nothing at all about why the merge cannot happen.
        //
        // The scenario used to be a changes-requested verdict, which now has
        // an action of its own and is tested as one below. That is the rule
        // working, not an exception to it: a blocker is drawn on `Merge` when
        // it is all we can say, and promoted to its own primary action when
        // there is something the agent can actually do about it.
        final entry = merge(
          const PullRequestSnapshot(
            number: 7,
            state: PullRequestState.open,
            url: 'u',
            mergeable: true,
            mergeStateStatus: MergeStateStatus.blocked,
            checks: ChecksSummary(passed: 2),
          ),
        );
        expect(entry.isPrimary, isTrue);
        expect(entry.disabledReason, contains('GitHub is blocking'));
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

  test('the prompts are exactly the steps with something to decide', () {
    // The list is asserted whole rather than per action, so adding a state
    // forces a decision about which side of the line it falls on. Every entry
    // here names work whose *content* a model has to invent — a commit
    // message, which side of a conflict hunk lives, what a reviewer meant.
    expect(DeliveryAction.values.where((a) => a.isPrompt).toSet(), {
      DeliveryAction.commit,
      DeliveryAction.push,
      DeliveryAction.openPullRequest,
      DeliveryAction.resolveConflicts,
      DeliveryAction.addressRequestedChanges,
      DeliveryAction.resolveReviewComments,
      DeliveryAction.merge,
      DeliveryAction.runTests,
    });
  });

  test('the app owns the operations with nothing to decide', () {
    // The complement of the test above, spelled out rather than derived, so
    // that a new action cannot be added to neither list and quietly become a
    // button that does nothing.
    expect(DeliveryAction.values.where((a) => !a.isPrompt).toSet(), {
      DeliveryAction.viewPullRequest,
      DeliveryAction.viewChecks,
      DeliveryAction.updateFromBase,
      DeliveryAction.markReady,
      DeliveryAction.archive,
    });
  });

  group('behind the base branch', () {
    SessionDelivery behind({
      int? behindBase = 2,
      String? base = 'origin/main',
      int dirty = 0,
      bool? agentRunning,
      PullRequestSnapshot? pullRequest,
    }) => SessionDelivery(
      branch: 'work',
      baseBranch: base,
      hasRemote: true,
      dirtyFiles: dirty,
      aheadOfBase: 2,
      behindBase: behindBase,
      upstream: 'origin/work',
      unpushed: 0,
      agentRunning: agentRunning,
      pullRequest: pullRequest,
    );

    test('a local count above zero offers Update, and makes it primary', () {
      expect(primaryOf(behind()), DeliveryAction.updateFromBase);
    });

    test("GitHub's own BEHIND is enough on its own", () {
      // The local count is a positive zero here — this clone has fetched
      // nothing since the base moved — so only the forge knows.
      expect(
        primaryOf(
          behind(
            behindBase: 0,
            pullRequest: const PullRequestSnapshot(
              number: 7,
              state: PullRequestState.open,
              url: 'u',
              mergeStateStatus: MergeStateStatus.behind,
              checks: ChecksSummary(passed: 1),
            ),
          ),
        ),
        DeliveryAction.updateFromBase,
      );
    });

    test('nothing established leaves Update off the row entirely', () {
      expect(
        actionsOf(behind(behindBase: 0)),
        isNot(contains(DeliveryAction.updateFromBase)),
      );
    });

    test('no local base ref means nothing to merge, so no button', () {
      // GitHub says behind; this clone has no origin/HEAD to merge from. A
      // button whose only outcome is "unknown revision" is worse than none.
      expect(
        actionsOf(
          behind(
            base: null,
            behindBase: 0,
            pullRequest: const PullRequestSnapshot(
              number: 7,
              state: PullRequestState.open,
              mergeStateStatus: MergeStateStatus.behind,
            ),
          ),
        ),
        isNot(contains(DeliveryAction.updateFromBase)),
      );
    });

    test('a live agent disables Update rather than hiding it', () {
      final entry = entryFor(
        behind(agentRunning: true),
        DeliveryAction.updateFromBase,
      )!;
      expect(entry.isEnabled, isFalse);
      expect(entry.disabledReason, contains('still running'));
      // Still primary: the user needs to see that this is the next step and
      // why it cannot happen yet.
      expect(entry.isPrimary, isTrue);
    });

    test('uncommitted work disables Update — and Commit takes the lead', () {
      final delivery = behind(dirty: 3);
      expect(
        entryFor(delivery, DeliveryAction.updateFromBase)!.disabledReason,
        contains('uncommitted'),
      );
      expect(primaryOf(delivery), DeliveryAction.commit);
    });

    test('being behind disables Merge and says which way to fix it', () {
      expect(
        entryFor(
          behind(
            pullRequest: const PullRequestSnapshot(
              number: 7,
              state: PullRequestState.open,
              url: 'u',
              mergeable: true,
              checks: ChecksSummary(passed: 2),
            ),
          ),
          DeliveryAction.merge,
        )!.disabledReason,
        'The base branch has moved on; update this branch first.',
      );
    });
  });

  group('merge conflicts', () {
    SessionDelivery conflicted({
      bool? mergeable = false,
      MergeStateStatus? mergeState,
      int? behindBase,
    }) => SessionDelivery(
      branch: 'work',
      baseBranch: 'origin/main',
      hasRemote: true,
      dirtyFiles: 0,
      aheadOfBase: 2,
      behindBase: behindBase,
      pullRequest: PullRequestSnapshot(
        number: 7,
        state: PullRequestState.open,
        url: 'u',
        mergeable: mergeable,
        mergeStateStatus: mergeState,
        checks: const ChecksSummary(passed: 2),
      ),
    );

    test('a conflict makes resolving it the next thing', () {
      expect(primaryOf(conflicted()), DeliveryAction.resolveConflicts);
    });

    test('DIRTY alone establishes it, without mergeable', () {
      expect(
        primaryOf(
          conflicted(mergeable: null, mergeState: MergeStateStatus.dirty),
        ),
        DeliveryAction.resolveConflicts,
      );
    });

    test('a clean pull request is never offered it', () {
      expect(
        actionsOf(conflicted(mergeable: true)),
        isNot(contains(DeliveryAction.resolveConflicts)),
      );
    });

    test('unknown mergeability is not a conflict', () {
      // The one that would have hurt: GitHub answers UNKNOWN until it has
      // computed, and reading that as a conflict would put "Resolve
      // conflicts" on top of every freshly opened pull request.
      expect(
        actionsOf(conflicted(mergeable: null)),
        isNot(contains(DeliveryAction.resolveConflicts)),
      );
    });

    test('a conflict outranks being behind, and disables Update', () {
      final delivery = conflicted(behindBase: 4);
      expect(primaryOf(delivery), DeliveryAction.resolveConflicts);
      expect(
        entryFor(delivery, DeliveryAction.updateFromBase)!.disabledReason,
        contains('resolve that first'),
      );
    });
  });

  group('review', () {
    SessionDelivery reviewed({
      ReviewDecision? decision,
      int? unresolved,
      int? behindBase,
    }) => SessionDelivery(
      branch: 'work',
      baseBranch: 'origin/main',
      hasRemote: true,
      dirtyFiles: 0,
      aheadOfBase: 2,
      behindBase: behindBase,
      pullRequest: PullRequestSnapshot(
        number: 7,
        state: PullRequestState.open,
        url: 'u',
        mergeable: true,
        reviewDecision: decision,
        unresolvedReviewThreads: unresolved,
        checks: const ChecksSummary(passed: 2),
      ),
    );

    test('requested changes become the next step, not a disabled Merge', () {
      expect(
        primaryOf(reviewed(decision: ReviewDecision.changesRequested)),
        DeliveryAction.addressRequestedChanges,
      );
    });

    test('open conversations become the next step', () {
      expect(
        primaryOf(reviewed(unresolved: 2)),
        DeliveryAction.resolveReviewComments,
      );
    });

    test('never both at once — the verdict wins', () {
      final actions = actionsOf(
        reviewed(decision: ReviewDecision.changesRequested, unresolved: 3),
      );
      expect(actions, contains(DeliveryAction.addressRequestedChanges));
      expect(actions, isNot(contains(DeliveryAction.resolveReviewComments)));
    });

    test('a thread count of zero is an answer, and offers nothing', () {
      // Zero means "asked, and everything is resolved". It must not read the
      // same as null, which means the query was never made.
      final actions = actionsOf(reviewed(unresolved: 0));
      expect(actions, isNot(contains(DeliveryAction.resolveReviewComments)));
      expect(actions, isNot(contains(DeliveryAction.addressRequestedChanges)));
    });

    test('an unasked thread count offers nothing either', () {
      expect(
        actionsOf(reviewed()),
        isNot(contains(DeliveryAction.resolveReviewComments)),
      );
    });

    test('open conversations disable Merge and count themselves', () {
      expect(
        entryFor(reviewed(unresolved: 1), DeliveryAction.merge)!.disabledReason,
        '1 review conversation is still open.',
      );
      expect(
        entryFor(reviewed(unresolved: 3), DeliveryAction.merge)!.disabledReason,
        '3 review conversations are still open.',
      );
    });

    test('a waiting reviewer outranks a stale base', () {
      // Every other blocker is a machine that will still be there in an hour;
      // the reviewer has already spent their attention.
      expect(
        primaryOf(
          reviewed(decision: ReviewDecision.changesRequested, behindBase: 5),
        ),
        DeliveryAction.addressRequestedChanges,
      );
    });
  });

  group('draft to ready', () {
    SessionDelivery draft({
      ChecksSummary checks = ChecksSummary.none,
      bool isDraft = true,
      int? behindBase,
    }) => SessionDelivery(
      branch: 'work',
      baseBranch: 'origin/main',
      hasRemote: true,
      dirtyFiles: 0,
      aheadOfBase: 2,
      behindBase: behindBase,
      pullRequest: PullRequestSnapshot(
        number: 7,
        state: PullRequestState.open,
        url: 'u',
        isDraft: isDraft,
        mergeable: true,
        checks: checks,
      ),
    );

    test('a green draft is asked to go ready', () {
      expect(
        primaryOf(draft(checks: const ChecksSummary(passed: 2))),
        DeliveryAction.markReady,
      );
    });

    test('a draft with no checks at all is asked too', () {
      expect(primaryOf(draft()), DeliveryAction.markReady);
    });

    test('a red draft is left alone — fix the build first', () {
      final delivery = draft(checks: const ChecksSummary(failed: 1));
      expect(primaryOf(delivery), DeliveryAction.viewChecks);
      // Offered, just not promoted: the author may still want to publish it.
      expect(actionsOf(delivery), contains(DeliveryAction.markReady));
    });

    test('a draft with checks still running is left alone', () {
      expect(
        primaryOf(draft(checks: const ChecksSummary(pending: 2))),
        DeliveryAction.viewChecks,
      );
    });

    test('a stale base is fixed before the draft is published', () {
      expect(
        primaryOf(
          draft(checks: const ChecksSummary(passed: 2), behindBase: 3),
        ),
        DeliveryAction.updateFromBase,
      );
    });

    test('a pull request that is not a draft is never offered it', () {
      expect(
        actionsOf(draft(isDraft: false)),
        isNot(contains(DeliveryAction.markReady)),
      );
    });
  });

  group('merge strategy', () {
    OfferedAction mergeWith(MergeStrategies strategies) => entryFor(
      SessionDelivery(
        hasRemote: true,
        dirtyFiles: 0,
        mergeStrategies: strategies,
        pullRequest: const PullRequestSnapshot(
          number: 7,
          state: PullRequestState.open,
          url: 'u',
          mergeable: true,
          checks: ChecksSummary(passed: 2),
        ),
      ),
      DeliveryAction.merge,
    )!;

    test('a squash-only repository is never asked for a merge commit', () {
      final entry = mergeWith(
        const MergeStrategies(mergeCommit: false, squash: true, rebase: false),
      );
      expect(entry.prompt, 'Merge the pull request with a squash merge.');
      expect(entry.prompt, isNot(contains('merge commit')));
    });

    test('a rebase-only repository is asked for a rebase', () {
      expect(
        mergeWith(
          const MergeStrategies(
            mergeCommit: false,
            squash: false,
            rebase: true,
          ),
        ).prompt,
        'Merge the pull request with a rebase merge.',
      );
    });

    test('an unasked repository keeps the sentence it always sent', () {
      // The important direction: knowing nothing must never make the strip
      // guess. gh falls back to the repository's own default.
      expect(mergeWith(MergeStrategies.unknown).prompt,
          'Merge the pull request.');
    });

    test('a repository that allows nothing disables Merge', () {
      final entry = mergeWith(
        const MergeStrategies(mergeCommit: false, squash: false, rebase: false),
      );
      expect(entry.isEnabled, isFalse);
      expect(entry.disabledReason, contains('no merge strategy'));
    });
  });

  test('every action has a place in the row', () {
    // A value missing from the pipeline list is offered by the rules above and
    // then silently dropped on the way out, which is a bug with no symptom
    // other than a button nobody can find.
    final drawn = deliveryActionsFor(
      const SessionDelivery(
        branch: 'work',
        baseBranch: 'origin/main',
        hasRemote: true,
        dirtyFiles: 1,
        aheadOfBase: 2,
        behindBase: 1,
        hasWorktree: true,
        pullRequest: PullRequestSnapshot(
          number: 7,
          state: PullRequestState.open,
          url: 'u',
          isDraft: true,
          mergeable: false,
          reviewDecision: ReviewDecision.changesRequested,
          checks: ChecksSummary(failed: 1),
        ),
      ),
    ).map((o) => o.action).toSet();
    // Everything except the two that this one state rules out: `Open PR`
    // (there is one already) and `Reply to review` (the verdict won).
    expect(drawn, hasLength(DeliveryAction.values.length - 2));
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
