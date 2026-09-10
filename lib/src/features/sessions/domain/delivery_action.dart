import 'delivery_stage.dart';
import 'session_delivery.dart';
import 'package:karmashala_git/github.dart';

/// The delivery strip's actions: one line from a working tree to an archived
/// worktree, with the next sensible step drawn as the primary one.
///
/// Which kind an action is turns on one question: is there anything to decide?
/// A prompt names work whose *content* a model has to invent — a commit message,
/// which side of a conflict hunk survives — and is sent into the session
/// verbatim; an app-owned action is a fixed operation with nothing to decide,
/// where the app can offer a precondition check and a refusal instead.
enum DeliveryAction {
  /// Ungated: an empty index costs one line in the transcript, and gating it on
  /// the working tree would make the button flicker while the agent edits.
  commit(label: 'Commit', prompt: 'Commit the changes.'),

  push(label: 'Push', prompt: 'Push this branch.'),

  openPullRequest(
    label: 'Open PR',
    prompt: 'Push this branch and open a pull request.',
  ),

  /// Ours: the PR's page, opened in the browser.
  viewPullRequest(label: 'View PR'),

  /// Ours: the PR's checks tab.
  viewChecks(label: 'Checks'),

  /// A prompt, and the clearest case for why: a conflict is a question about
  /// *meaning*, `--ours` and `--theirs` are both usually wrong, and the app
  /// could not do this if it wanted to.
  resolveConflicts(
    label: 'Resolve conflicts',
    prompt: 'Resolve the merge conflicts with the base branch.',
  ),

  /// Ours, and the counterpart to [resolveConflicts]: one git command with no
  /// decision in it, where the interesting part is entirely the preconditions.
  /// Fails closed — see `DeliveryUpdateService`.
  updateFromBase(label: 'Update'),

  /// A prompt: acting on "a reviewer asked for changes" means reading the
  /// review and writing different code. Nothing about that is mechanical.
  addressRequestedChanges(
    label: 'Address review',
    prompt: 'Address the changes the reviewer requested.',
  ),

  /// A prompt, and kept separate from [addressRequestedChanges] because the two
  /// ask for different work — a blocking verdict versus threads that may each
  /// want a reply. Never offered together; see [deliveryActionsFor].
  resolveReviewComments(
    label: 'Reply to review',
    prompt: 'Address the unresolved review comments.',
  ),

  /// Ours: `gh pr ready`. A boolean with no content to author, and *which* pull
  /// request gets flipped is an argument the app knows and a prompt would guess.
  markReady(label: 'Ready for review'),

  merge(label: 'Merge', prompt: 'Merge the pull request.'),

  /// Ungated: the agent knows the repository's test command, and "there are no
  /// tests" is a useful answer in the transcript.
  runTests(label: 'Run tests', prompt: 'Run the tests.'),

  /// Ours, and confirmed: removes the session's worktree directory and nothing
  /// else. The transcript, review notes and checkpoints stay.
  archive(label: 'Archive worktree');

  const DeliveryAction({required this.label, this.prompt});

  final String label;

  /// The text sent into the session, **verbatim**, or null when the app does
  /// this itself. Read it through [OfferedAction.prompt] rather than directly:
  /// [merge] varies its wording with what the forge allows.
  final String? prompt;

  bool get isPrompt => prompt != null;
}

/// One action as the strip should draw it.
class OfferedAction {
  const OfferedAction(
    this.action, {
    this.isPrimary = false,
    this.disabledReason,
    this.promptOverride,
  });

  final DeliveryAction action;

  /// Whether this is the next sensible thing to do. Exactly one offered action
  /// is primary, or none when there is nothing sensible left.
  final bool isPrimary;

  /// Why this cannot be pressed, in a sentence the user can act on. Null when
  /// it can; only **established** facts disable an action.
  final String? disabledReason;

  /// A sentence that replaces [DeliveryAction.prompt] for this one offering.
  /// Exists for [DeliveryAction.merge], whose prompt names the strategy the
  /// repository actually allows: the enum is const, and the tooltip must show
  /// the exact sentence that will be sent.
  final String? promptOverride;

  /// What pressing this sends, or null when the app does it itself.
  String? get prompt => promptOverride ?? action.prompt;

  bool get isEnabled => disabledReason == null;

  @override
  bool operator ==(Object other) =>
      other is OfferedAction &&
      other.action == action &&
      other.isPrimary == isPrimary &&
      other.disabledReason == disabledReason &&
      other.promptOverride == promptOverride;

  @override
  int get hashCode =>
      Object.hash(action, isPrimary, disabledReason, promptOverride);

  @override
  String toString() =>
      'OfferedAction(${action.name}${isPrimary ? ', primary' : ''}'
      '${disabledReason == null ? '' : ', disabled: $disabledReason'})';
}

/// The order actions are drawn in after the primary one — the delivery line
/// itself, so the row reads the same whichever step is highlighted.
///
/// Every value of [DeliveryAction] must appear here exactly once: one missing
/// is silently never drawn, and `delivery_action_test` asserts they stay in
/// step.
const _pipeline = [
  DeliveryAction.commit,
  DeliveryAction.push,
  DeliveryAction.openPullRequest,
  DeliveryAction.viewPullRequest,
  DeliveryAction.viewChecks,
  DeliveryAction.resolveConflicts,
  DeliveryAction.updateFromBase,
  DeliveryAction.addressRequestedChanges,
  DeliveryAction.resolveReviewComments,
  DeliveryAction.markReady,
  DeliveryAction.merge,
  DeliveryAction.runTests,
  DeliveryAction.archive,
];

/// The exception states, in the order one blocks another, richest first.
///
/// Conflicts first, because nothing else can proceed through one; then the two
/// where a *person* is waiting; then behind-the-base, which is cheap to repeat
/// but still comes before the stage machine, because every signal after it is
/// measured against the old base. Agrees with GitHub's own dirty → blocked →
/// behind → unstable, except that GitHub's "blocked" is one bucket and this
/// splits it into the parts an agent can act on.
const _blockers = [
  DeliveryAction.resolveConflicts,
  DeliveryAction.addressRequestedChanges,
  DeliveryAction.resolveReviewComments,
  DeliveryAction.updateFromBase,
];

/// What the strip offers for [delivery], primary first.
///
/// Pipeline prompts **over**-offer: a withheld one hides the feature, an
/// unnecessary one costs a click and one sentence in the transcript. Exception
/// prompts **under**-offer, because `Resolve conflicts` on a branch with no
/// conflict is a false statement about the branch — and an exception offered
/// speculatively would outrank the true next step. Ours fail closed: disabled
/// with a readable reason rather than hidden.
///
/// An archived session offers no prompts and none of the app's own writes — its
/// worktree is gone. Only the two browser links survive.
List<OfferedAction> deliveryActionsFor(SessionDelivery? state) {
  final delivery = state ?? SessionDelivery.unknown;
  final pr = delivery.pullRequest;
  final archived = delivery.archived;
  final openPr = pr != null && pr.isOpen ? pr : null;

  final reasons = <DeliveryAction, String?>{};
  final prompts = <DeliveryAction, String>{};
  if (!archived) {
    reasons[DeliveryAction.commit] = null;
    if (delivery.hasRemote != false) reasons[DeliveryAction.push] = null;
    if (_offersOpenPullRequest(delivery)) {
      reasons[DeliveryAction.openPullRequest] = null;
    }
    if (delivery.hasConflict) reasons[DeliveryAction.resolveConflicts] = null;
    if (_offersUpdateFromBase(delivery)) {
      reasons[DeliveryAction.updateFromBase] = _updateBlocker(delivery);
    }
    if (openPr != null) {
      // Never both: two readings of the same "a human wants something changed",
      // and the verdict wins because it is the one that blocks the merge.
      if (openPr.wantsChanges) {
        reasons[DeliveryAction.addressRequestedChanges] = null;
      } else if (openPr.hasUnresolvedReviewComments) {
        reasons[DeliveryAction.resolveReviewComments] = null;
      }
      if (openPr.isDraft) reasons[DeliveryAction.markReady] = null;
      reasons[DeliveryAction.merge] = _mergeBlocker(delivery, openPr);
      prompts[DeliveryAction.merge] = _mergePrompt(delivery);
    }
    reasons[DeliveryAction.runTests] = null;
  }
  if (pr?.url != null) {
    reasons[DeliveryAction.viewPullRequest] = null;
    if (pr!.checks.total > 0) reasons[DeliveryAction.viewChecks] = null;
  }
  if (delivery.hasWorktree && !archived) {
    reasons[DeliveryAction.archive] = delivery.agentRunning == true
        ? 'The agent is still running in this worktree.'
        : null;
  }

  final primary = _primaryFor(delivery, reasons);
  return [
    for (final action in [?primary, ..._pipeline.where((a) => a != primary)])
      if (reasons.containsKey(action))
        OfferedAction(
          action,
          isPrimary: action == primary,
          disabledReason: reasons[action],
          promptOverride: prompts[action],
        ),
  ];
}

/// Loop 33's `canOpenPr`, plus the one fact it could not know: a pull request
/// that is already open needs viewing, not opening.
bool _offersOpenPullRequest(SessionDelivery delivery) {
  final pr = delivery.pullRequest;
  if (pr != null && pr.isOpen) return false;
  if (delivery.hasRemote == false) return false;
  if (delivery.isOnDefaultBranch) return false;
  if (delivery.aheadOfBase == 0) return false;
  return true;
}

/// Whether there is a base to update *from* and evidence the branch needs it.
///
/// The local base check is not a formality: `isBehindBase` can fire on GitHub's
/// word alone, and GitHub's base is a name on the remote. With no local base the
/// button's only possible outcome is "unknown revision".
bool _offersUpdateFromBase(SessionDelivery delivery) =>
    delivery.baseBranch != null && delivery.isBehindBase;

/// Why updating from the base would not be safe, or null when it is. All three
/// are checks the app can make and a prompt could not be trusted to, ordered by
/// what the user can do something about first.
String? _updateBlocker(SessionDelivery delivery) {
  if (delivery.hasConflict) {
    return 'The branch already conflicts with its base; resolve that first.';
  }
  if (delivery.agentRunning == true) {
    return 'The agent is still running in this worktree.';
  }
  if (delivery.isDirty) {
    return 'Commit or discard the uncommitted changes first.';
  }
  return null;
}

/// The sentence `Merge` sends, naming a strategy the repository allows.
///
/// Naming nothing is the safe answer and stays the default: when the forge did
/// not tell us, `gh pr merge` falls back to the repository's own default.
/// Naming `squash` at a repository with squash merging off fails on the forge
/// after the agent has already spent a turn on it.
String _mergePrompt(SessionDelivery delivery) {
  final strategy = delivery.mergeStrategies.preferredLabel;
  if (strategy == null) return DeliveryAction.merge.prompt!;
  return 'Merge the pull request with a $strategy.';
}

/// Why merging would not work, or null when nothing established says so.
///
/// Only one reason is ever shown, so the order is the whole of the decision.
/// `BLOCKED` is read *last*: it covers every branch-protection rule GitHub has
/// and names none of them, and every open pull request in a protected
/// repository reports it (all three of `cli/cli`'s open PRs, 2026-09-02).
String? _mergeBlocker(SessionDelivery delivery, PullRequestSnapshot pr) {
  if (pr.isDraft) return 'The pull request is still a draft.';
  if (pr.hasConflict) return 'GitHub reports a merge conflict.';
  if (pr.wantsChanges) return 'A reviewer asked for changes.';
  if (pr.hasUnresolvedReviewComments) {
    final open = pr.unresolvedReviewThreads!;
    return '$open review conversation${open == 1 ? ' is' : 's are'} still '
        'open.';
  }
  if (pr.checks.state == ChecksState.failing) return 'Checks are failing.';
  if (delivery.isBehindBase) {
    return 'The base branch has moved on; update this branch first.';
  }
  if (delivery.mergeStrategies.noneAllowed) {
    return 'This repository allows no merge strategy.';
  }
  if (pr.mergeStateStatus == MergeStateStatus.blocked) {
    // `BLOCKED` names no rule, so a second call asks the base branch's
    // protection which rules it carries. A token without admin rights gets a
    // 403 on `/protection` — the ordinary case, not an error — and falls back.
    return delivery.branchProtection.describeFor(pr) ??
        'GitHub is blocking this merge; open the pull request to see why.';
  }
  return null;
}

/// The next sensible step, given how far the work has got.
///
/// Uncommitted work beats everything; then the exception states in [_blockers]'
/// order, because the stage machine below reads how far the work travelled and
/// has no way to ask what is in the way. A step that is offered but **blocked**
/// still becomes primary — a disabled `Merge` says both what comes next and why.
DeliveryAction? _primaryFor(
  SessionDelivery delivery,
  Map<DeliveryAction, String?> reasons,
) {
  bool offered(DeliveryAction? action) =>
      action != null && reasons.containsKey(action);

  if (delivery.isDirty && offered(DeliveryAction.commit)) {
    return DeliveryAction.commit;
  }

  for (final blocker in _blockers) {
    if (offered(blocker)) return blocker;
  }

  // Draft → ready, deliberately after everything above: a draft's one benefit
  // is that nobody is asked to look yet, so this fires only once nothing is
  // left to fix — green checks, or a repository with no checks at all.
  final checks = delivery.pullRequest?.checks.state;
  if (offered(DeliveryAction.markReady) &&
      (checks == ChecksState.passing || checks == ChecksState.none)) {
    return DeliveryAction.markReady;
  }

  final wanted = switch (delivery.stage) {
    DeliveryStage.working => DeliveryAction.commit,
    DeliveryStage.committed => DeliveryAction.push,
    DeliveryStage.pushed => DeliveryAction.openPullRequest,
    DeliveryStage.prOpen =>
      offered(DeliveryAction.viewChecks)
          ? DeliveryAction.viewChecks
          : DeliveryAction.viewPullRequest,
    DeliveryStage.checksFailing => DeliveryAction.viewChecks,
    DeliveryStage.checksPassing => DeliveryAction.merge,
    DeliveryStage.merged => DeliveryAction.archive,
    DeliveryStage.archived => null,
  };
  if (offered(wanted)) return wanted;

  // Nothing is next once the work has landed and its worktree is gone.
  if (delivery.stage.order >= DeliveryStage.merged.order) return null;

  // The step the stage asked for is not offered at all — no remote, so no push.
  // Fall forward to the first thing that is, rather than leaving no emphasis.
  for (final action in _pipeline) {
    if (offered(action) && reasons[action] == null) return action;
  }
  return null;
}
