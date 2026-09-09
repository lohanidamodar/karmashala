import 'delivery_stage.dart';
import 'session_delivery.dart';
import '../../github/domain/pull_request_snapshot.dart';

/// The delivery strip's actions: one line from a working tree to an archived
/// worktree, with the next sensible step drawn as the primary one.
///
/// **The ones the agent should do are prompts.** Pressing `Commit`, `Push`,
/// `Open PR` or `Merge` sends [OfferedAction.prompt] verbatim into the session
/// exactly as if the user had typed it; nothing here runs `git` or `gh`. That
/// is Loop 33's design, taken from dray, and it still buys the same three
/// things: the agent writes the commit message with the context it just worked
/// in, there is no confirm dialog, and whatever goes wrong — a dirty index, a
/// missing upstream, a rejected push — is reported in the transcript by the
/// thing that actually knows what happened.
///
/// The ones that are **ours** have no prompt: opening a page in the browser is
/// not work an agent should do, and archiving a worktree is a destructive local
/// operation that must ask first. Those carry their own feedback because they
/// are the app's to get right.
///
/// **The test for which kind an action is: is there anything to decide?** Every
/// prompt here names work whose *content* the model has to invent — a commit
/// message, which side of a conflict hunk survives, what a reviewer's comment
/// is actually asking for. Every app-owned action is a fixed operation with no
/// content at all: open a URL, flip a draft flag, merge one named ref into
/// another, delete a directory. An operation with nothing to decide gains
/// nothing from a round trip through a language model and loses the two things
/// the app can offer instead — a precondition check, and a refusal the user can
/// read. That is why [updateFromBase] and [markReady] arrived as ours rather
/// than as two more sentences: "update this branch" has exactly one meaning.
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

  /// A prompt, and the clearest case in the enum for why. A conflict is a
  /// question about *meaning* — two people changed the same lines and someone
  /// has to decide what the combined code should say. There is no mechanical
  /// answer, `--ours` and `--theirs` are both usually wrong, and the agent has
  /// just been working in exactly the code the conflict is in. The app could
  /// not do this if it wanted to.
  resolveConflicts(
    label: 'Resolve conflicts',
    prompt: 'Resolve the merge conflicts with the base branch.',
  ),

  /// Ours, and the counterpart to [resolveConflicts]: merging the base into
  /// this branch is one git command with no decision in it, and the interesting
  /// part is entirely in the preconditions — a clean tree, no live agent, no
  /// known conflict. Those are checks with definite answers, which is precisely
  /// what an app is better at than a prompt. It fails closed: see
  /// `DeliveryUpdateService`, which refuses rather than guesses and aborts the
  /// merge rather than leaving a half-merged index behind.
  updateFromBase(label: 'Update'),

  /// A prompt. "A reviewer asked for changes" is a pointer at prose someone
  /// wrote, and acting on it means reading the review, understanding the
  /// objection and writing different code. Nothing about that is mechanical.
  addressRequestedChanges(
    label: 'Address review',
    prompt: 'Address the changes the reviewer requested.',
  ),

  /// A prompt, for the same reason as [addressRequestedChanges], and kept
  /// separate from it rather than folded in because the two ask for different
  /// work: a changes-requested verdict blocks the merge and names one
  /// reviewer's position, while open conversations are threads that may each
  /// want a reply, a change, or nothing. The two are never offered together —
  /// see [deliveryActionsFor] — so this costs a second enum value and no extra
  /// room in the row.
  resolveReviewComments(
    label: 'Reply to review',
    prompt: 'Address the unresolved review comments.',
  ),

  /// Ours: `gh pr ready`. A boolean on the forge with no content to author, and
  /// the one place a mistake matters is *which* pull request gets flipped —
  /// which is an argument the app knows and a prompt would have to re-derive.
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
  /// this itself.
  ///
  /// Read through [OfferedAction.prompt] rather than directly: one action —
  /// [merge] — varies its wording with what the forge allows, and a caller that
  /// reads this field instead would send the generic sentence.
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
  /// it can. Only **established** facts disable an action — see
  /// [deliveryActionsFor].
  final String? disabledReason;

  /// A sentence that replaces [DeliveryAction.prompt] for this one offering.
  ///
  /// Exists for [DeliveryAction.merge], whose prompt names the strategy the
  /// repository actually allows. That could not live on the enum, which is
  /// const and knows nothing about a repository; and it could not be assembled
  /// at the press site either, because the tooltip shows the user the exact
  /// sentence that will be sent and the two must not be able to disagree.
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
/// The five states added after Loop 33 sit between "look at the pull request"
/// and "merge it", which is where they happen: you see the PR, you see what its
/// checks said, you deal with whatever is in the way, and then it lands. Every
/// value of [DeliveryAction] must appear here exactly once — an action missing
/// from this list is silently never drawn, and `delivery_action_test` asserts
/// the two stay in step.
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
/// This is the whole of the "what is in the way" question and it is a list
/// rather than a chain of `if`s so the ordering argument can be read in one
/// place:
///
/// 1. **Conflicts** first because nothing else can proceed through one. An
///    update cannot apply, a merge cannot run, and checks that did run were run
///    on a merge commit GitHub can no longer produce.
/// 2. **A reviewer's requested changes**, then **open conversations**, because
///    they are the only entries here where a *person* is blocked. Every other
///    state is a machine that will still be there in an hour; a reviewer who
///    has already spent their attention is waiting on this branch now, and
///    making them wait through a CI fix and a base update first is how a review
///    round turns into a day.
/// 3. **Behind the base** last of the four. It is one mechanical click, it is
///    cheap to repeat, and doing it earlier would re-trigger CI in the middle
///    of the work above — but it comes before the ordinary stage machine
///    (checks, merge) because every signal after it is measured against the old
///    base and may be answering a question that no longer exists.
///
/// GitHub resolves its own `mergeStateStatus` as dirty → blocked → behind →
/// unstable, which agrees with this everywhere the two overlap; the difference
/// is that GitHub's "blocked" is one bucket and this splits it into the parts
/// an agent can actually act on.
const _blockers = [
  DeliveryAction.resolveConflicts,
  DeliveryAction.addressRequestedChanges,
  DeliveryAction.resolveReviewComments,
  DeliveryAction.updateFromBase,
];

/// What the strip offers for [delivery], primary first.
///
/// Three biases, and they do not all point the same way:
///
/// * **Pipeline prompts over-offer.** A withheld prompt hides the feature with
///   no way to discover why; an unnecessary one costs a wasted click and one
///   sentence in the transcript that the agent answers with "there is nothing
///   to push". So `Open PR` is withheld only on facts we positively established
///   — no remote, already on the default branch, provably nothing ahead, a pull
///   request already open — and everything unknown is offered.
/// * **Exception prompts under-offer, and this is the opposite rule on
///   purpose.** `Resolve conflicts`, `Address review`, `Reply to review` and
///   `Update` appear *only* on a fact something positively established. The
///   asymmetry is not inconsistency: `Commit` on a clean tree is a wasted
///   click, but `Resolve conflicts` on a branch with no conflict is a false
///   statement about the branch — the strip's whole value is that its primary
///   action is the next real thing, and an exception offered speculatively
///   would outrank the true next step every time, because that is exactly what
///   the ordering below does with it. Under-offering costs the user nothing:
///   the states these cover are all visible on the pull request page, which is
///   one button away in the same row.
/// * **Ours fail closed.** `Merge`, though a prompt, is disabled on an
///   established blocker rather than hidden, because the user should see *that*
///   there is a blocker. `Update` is disabled while an agent is live in the
///   worktree or while the tree is dirty — merging under either would fold a
///   base branch into work nobody has recorded. `Archive` is disabled while an
///   agent is live: deleting the directory a running agent is working in is not
///   cleanup.
///
/// An archived session offers no prompts at all — its worktree is gone, so
/// every one of them would run somewhere that no longer exists — and none of
/// the app's own write operations either, for the same reason. Only the two
/// browser links survive.
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
      // Never both. They are two readings of the same thing — a human wants
      // something changed — and a strip that draws `Address review` beside
      // `Reply to review` is asking the user to work out the difference
      // between two buttons that will produce the same next twenty minutes of
      // work. The verdict wins because it is the one that blocks the merge.
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
/// The base-branch check is not a formality. `SessionDelivery.isBehindBase` can
/// fire on GitHub's word alone, and GitHub's base is a name on the remote,
/// while the merge this button performs takes a ref that exists on this disk.
/// Offering an update with no local base would produce a button whose only
/// possible outcome is "unknown revision", which is worse than no button.
bool _offersUpdateFromBase(SessionDelivery delivery) =>
    delivery.baseBranch != null && delivery.isBehindBase;

/// Why updating from the base would not be safe, or null when it is.
///
/// All three are refusals rather than attempts, and all three are checks the
/// app can make and a prompt could not be trusted to. The order is the order
/// the user can do something about them in.
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
/// **Naming nothing is the safe answer and stays the default.** When the forge
/// did not tell us — an unauthenticated `gh`, a token without settings access,
/// or simply a row that never paid for the second query — the prompt is the one
/// this strip has always sent, and `gh pr merge` falls back to the repository's
/// own default. The failure this avoids is the opposite one: naming `squash` at
/// a repository that has squash merging turned off, which fails on the forge
/// after the agent has already spent a turn on it and teaches the user that the
/// button is guessing.
String _mergePrompt(SessionDelivery delivery) {
  final strategy = delivery.mergeStrategies.preferredLabel;
  if (strategy == null) return DeliveryAction.merge.prompt!;
  return 'Merge the pull request with a $strategy.';
}

/// Why merging would not work, or null when nothing established says so.
///
/// Ordered by what the user would want named first, which is not the same as
/// the order they will be fixed in: a draft is a thing the author chose, a
/// conflict is a thing they must fix, and everything below that is a thing
/// somebody else is doing. Only one reason is ever shown, so the order is the
/// whole of the decision.
///
/// The last entry is the interesting one. `mergeStateStatus: BLOCKED` covers
/// every branch-protection rule GitHub has and does not say which — required
/// reviews, required conversations, a required check that never reported, a
/// CODEOWNERS approval, a deployment gate. Every open pull request in a
/// protected repository reports it (observed on all three of `cli/cli`'s open
/// PRs, 2026-09-02), so it is read *last*, only once the ordinary explanations
/// above have been ruled out, and it sends the user to the page rather than
/// pretending to know the rule.
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
    // The rule, when it could be read. `BLOCKED` names none of them, so a
    // second call goes and asks the base branch's protection which rules it
    // carries — and, for the two the pull request can settle on its own, which
    // one is unmet. When the reading says nothing, so does this: a token
    // without admin rights gets a 403 on `/protection`, which is the ordinary
    // case rather than an error, and the old sentence is what it falls back
    // to.
    return delivery.branchProtection.describeFor(pr) ??
        'GitHub is blocking this merge; open the pull request to see why.';
  }
  return null;
}

/// The next sensible step, given how far the work has got.
///
/// Uncommitted work beats everything: a session with an open pull request and
/// an unsaved edit needs the edit recorded before anything else is worth doing.
///
/// Then the exception states, in [_blockers]' order, because they are answers
/// to "what is in the way" and the stage machine below has no way to ask that —
/// it reads how far the work travelled, and a branch that conflicts with its
/// base has travelled exactly as far as one that does not.
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

  for (final blocker in _blockers) {
    if (offered(blocker)) return blocker;
  }

  // Draft → ready, and deliberately *after* everything above rather than as
  // soon as the draft flag is seen.
  //
  // A draft is a state the author chose, and the one thing it buys them is
  // that nobody is asked to look yet. Suggesting they give that up while
  // checks are red — or still running — would push a branch in front of a
  // reviewer at exactly the moment its author is still finding out whether it
  // works. So this fires only once nothing is left to fix: green checks, or a
  // repository with no checks at all, which is the same "nothing says this is
  // broken" with less evidence behind it.
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
  // Fall forward to the first thing that is, rather than leaving the row with
  // no emphasis.
  for (final action in _pipeline) {
    if (offered(action) && reasons[action] == null) return action;
  }
  return null;
}
