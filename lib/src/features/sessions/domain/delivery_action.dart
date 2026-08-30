import 'delivery_stage.dart';
import 'session_delivery.dart';
import '../../github/domain/pull_request_snapshot.dart';

/// The delivery strip's actions: one line from a working tree to an archived
/// worktree, with the next sensible step drawn as the primary one.
///
/// **The ones the agent should do are prompts.** Pressing `Commit`, `Push`,
/// `Open PR` or `Merge` sends [DeliveryAction.prompt] verbatim into the session
/// exactly as if the user had typed it; nothing here runs `git` or `gh`. That
/// is Loop 33's design, taken from dray, and it still buys the same three
/// things: the agent writes the commit message with the context it just worked
/// in, there is no confirm dialog, and whatever goes wrong — a dirty index, a
/// missing upstream, a rejected push — is reported in the transcript by the
/// thing that actually knows what happened.
///
/// The ones that are **ours** have no prompt: opening a page in the browser is
/// not work an agent should do, and archiving a worktree is a destructive local
/// operation that must ask first. Those two carry their own feedback because
/// they are the app's to get right.
///
/// Prompts stay one short sentence. The model knows how to commit and whether
/// the branch has an upstream; spelling it out turns the button into a spec
/// competing with the repository's own instructions.
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
  /// this itself.
  final String? prompt;

  bool get isPrompt => prompt != null;
}

/// One action as the strip should draw it.
class OfferedAction {
  const OfferedAction(
    this.action, {
    this.isPrimary = false,
    this.disabledReason,
  });

  final DeliveryAction action;

  /// Whether this is the next sensible thing to do. Exactly one offered action
  /// is primary, or none when there is nothing sensible left.
  final bool isPrimary;

  /// Why this cannot be pressed, in a sentence the user can act on. Null when
  /// it can. Only **established** facts disable an action — see
  /// [deliveryActionsFor].
  final String? disabledReason;

  bool get isEnabled => disabledReason == null;

  @override
  bool operator ==(Object other) =>
      other is OfferedAction &&
      other.action == action &&
      other.isPrimary == isPrimary &&
      other.disabledReason == disabledReason;

  @override
  int get hashCode => Object.hash(action, isPrimary, disabledReason);

  @override
  String toString() =>
      'OfferedAction(${action.name}${isPrimary ? ', primary' : ''}'
      '${disabledReason == null ? '' : ', disabled: $disabledReason'})';
}

/// The order actions are drawn in after the primary one — the delivery line
/// itself, so the row reads the same whichever step is highlighted.
const _pipeline = [
  DeliveryAction.commit,
  DeliveryAction.push,
  DeliveryAction.openPullRequest,
  DeliveryAction.viewPullRequest,
  DeliveryAction.viewChecks,
  DeliveryAction.merge,
  DeliveryAction.runTests,
  DeliveryAction.archive,
];

/// What the strip offers for [delivery], primary first.
///
/// Two biases, and they point in opposite directions on purpose:
///
/// * **Prompts over-offer.** A withheld prompt hides the feature with no way to
///   discover why; an unnecessary one costs a wasted click and one sentence in
///   the transcript that the agent answers with "there is nothing to push". So
///   `Open PR` is withheld only on facts we positively established — no
///   remote, already on the default branch, provably nothing ahead, a pull
///   request already open — and everything unknown is offered.
/// * **Ours fail closed.** `Merge`, though a prompt, is disabled on an
///   established blocker rather than hidden, because the user should see *that*
///   there is a blocker. `Archive` is disabled while an agent is live in the
///   worktree: deleting the directory a running agent is working in is not
///   cleanup.
///
/// An archived session offers no prompts at all — its worktree is gone, so
/// every one of them would run somewhere that no longer exists.
List<OfferedAction> deliveryActionsFor(SessionDelivery? state) {
  final delivery = state ?? SessionDelivery.unknown;
  final pr = delivery.pullRequest;
  final archived = delivery.archived;

  final reasons = <DeliveryAction, String?>{};
  if (!archived) {
    reasons[DeliveryAction.commit] = null;
    if (delivery.hasRemote != false) reasons[DeliveryAction.push] = null;
    if (_offersOpenPullRequest(delivery)) {
      reasons[DeliveryAction.openPullRequest] = null;
    }
    if (pr != null && pr.isOpen) {
      reasons[DeliveryAction.merge] = _mergeBlocker(pr);
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

/// Why merging would not work, or null when nothing established says so.
String? _mergeBlocker(PullRequestSnapshot pr) {
  if (pr.isDraft) return 'The pull request is still a draft.';
  if (pr.mergeable == false) return 'GitHub reports a merge conflict.';
  if (pr.reviewDecision == ReviewDecision.changesRequested) {
    return 'A reviewer asked for changes.';
  }
  if (pr.checks.state == ChecksState.failing) return 'Checks are failing.';
  return null;
}

/// The next sensible step, given how far the work has got.
///
/// Uncommitted work beats everything: a session with an open pull request and
/// an unsaved edit needs the edit recorded before anything else is worth doing.
///
/// A step that is offered but **blocked** still becomes the primary one — a
/// disabled `Merge` carrying "Checks are failing." says both what comes next
/// and why it cannot happen yet, which is more use than promoting an unrelated
/// button.
DeliveryAction? _primaryFor(
  SessionDelivery delivery,
  Map<DeliveryAction, String?> reasons,
) {
  bool offered(DeliveryAction? action) =>
      action != null && reasons.containsKey(action);

  if (delivery.isDirty && offered(DeliveryAction.commit)) {
    return DeliveryAction.commit;
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
  // Fall forward to the first thing that is, rather than leaving the row with
  // no emphasis.
  for (final action in _pipeline) {
    if (offered(action) && reasons[action] == null) return action;
  }
  return null;
}
