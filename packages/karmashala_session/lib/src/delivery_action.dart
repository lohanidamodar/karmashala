import 'delivery_stage.dart';
import 'session_delivery.dart';
import 'package:karmashala_git/github.dart';

/// The delivery strip's actions, working tree to archived worktree. Which kind
/// an action is turns on one question: is there anything to decide?
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
  /// *meaning*, and the app could not answer it if it wanted to.
  resolveConflicts(
    label: 'Resolve conflicts',
    prompt: 'Resolve the merge conflicts with the base branch.',
  ),

  /// Ours, and the counterpart to [resolveConflicts]: one git command with no
  /// decision in it. Fails closed — see `DeliveryUpdateService`.
  updateFromBase(label: 'Update'),

  /// A prompt: acting on "a reviewer asked for changes" means reading the
  /// review and writing different code. Nothing about that is mechanical.
  addressRequestedChanges(
    label: 'Address review',
    prompt: 'Address the changes the reviewer requested.',
  ),

  /// A prompt, kept separate from [addressRequestedChanges]: a blocking verdict
  /// and open threads are different work. Never offered together.
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
  archive(label: 'Delete worktree');

  const DeliveryAction({required this.label, this.prompt});

  final String label;

  /// The text sent into the session, **verbatim**, or null when the app does
  /// this itself. Read it through [OfferedAction.prompt], which [merge] varies.
  final String? prompt;

  bool get isPrompt => prompt != null;

  /// [label] where there is room to say who does the work: a prompt action is
  /// "Ask agent to commit", so it is not mistaken for the Changes panel's own
  /// Commit, which runs git itself. The app's own actions keep [label].
  String get askLabel => isPrompt
      ? 'Ask agent to ${label[0].toLowerCase()}${label.substring(1)}'
      : label;
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

  /// A sentence that replaces [DeliveryAction.prompt] for this one offering —
  /// [DeliveryAction.merge], whose prompt names the strategy the forge allows.
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

/// The order actions are drawn in after the primary one. Every [DeliveryAction]
/// must appear here exactly once; one missing is silently never drawn.
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

/// The exception states, in the order one blocks another, richest first — the
/// two where a *person* waits outrank behind-the-base, which is cheap to redo.
const _blockers = [
  DeliveryAction.resolveConflicts,
  DeliveryAction.addressRequestedChanges,
  DeliveryAction.resolveReviewComments,
  DeliveryAction.updateFromBase,
];

/// What the strip offers for [delivery], primary first. Pipeline prompts
/// over-offer; exception prompts under-offer, a false one outranking the truth.
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
/// GitHub's base is a name on the remote; with no local ref the merge cannot run.
bool _offersUpdateFromBase(SessionDelivery delivery) =>
    delivery.baseBranch != null && delivery.isBehindBase;

/// Why updating from the base would not be safe, or null when it is — three
/// checks the app can make and a prompt could not be trusted to.
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

/// The sentence `Merge` sends, naming a strategy the repository allows. Naming
/// nothing is the default: `squash` at a repo with it off fails after a turn.
String _mergePrompt(SessionDelivery delivery) {
  final strategy = delivery.mergeStrategies.preferredLabel;
  if (strategy == null) return DeliveryAction.merge.prompt!;
  return 'Merge the pull request with a $strategy.';
}

/// Why merging would not work, or null when nothing established says so. Only
/// one reason ever shows, and `BLOCKED` is read last — it names no rule.
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
    // `BLOCKED` names no rule, so a second call asks the base branch's own
    // protection. A 403 there is the ordinary case, and falls back.
    return delivery.branchProtection.describeFor(pr) ??
        'GitHub is blocking this merge; open the pull request to see why.';
  }
  return null;
}

/// The next sensible step, given how far the work has got. A step that is
/// offered but **blocked** still becomes primary, reason and all.
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
  // is that nobody is asked to look yet, so nothing may be left to fix.
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
