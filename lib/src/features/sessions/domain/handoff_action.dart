/// Handoff actions: the one-click follow-ups a session offers once the agent has
/// done some work — commit it, propose it, check it.
///
/// **Every action is a prompt.** Pressing one sends [HandoffAction.prompt]
/// verbatim into the session, exactly as if the user had typed it. Nothing here
/// runs `git` or `gh`. That is the whole design, borrowed from dray's
/// `handoff.ts`, and it buys three things:
///
/// * The agent writes the commit message (or the PR body) with the context it
///   just worked in, so there is no second, worse write path beside it.
/// * There is no confirm dialog: the prompt is visible in the transcript the
///   instant it is sent, and the agent will say what it is about to do.
/// * There is no error surface. Whatever goes wrong — dirty index, no upstream,
///   a rejected push — is reported in the transcript like any other tool
///   failure, by the thing that actually knows what happened.
///
/// dray removed a direct-execution `push` button for exactly this reason: it
/// needed its own spinner, error banner and forced status re-read, which is
/// "machinery for one button in a row with no room for it".
///
/// Prompts are kept to one short sentence on purpose. The model already knows
/// how to commit and whether the branch has an upstream; spelling it out turns
/// the button into a spec competing with the repository's own instructions
/// (`CLAUDE.md`, `AGENTS.md`, commit-message conventions).
library;

/// The repository facts [isHandoffActionOffered] gates on, read from the
/// session's working directory.
///
/// Every field is nullable and **`null` always means "could not tell"**, never
/// "no". A probe that failed, an environment that is gone, `gh` not being
/// installed — all of them arrive here as `null` and are read as *offer it
/// anyway*. See [isHandoffActionOffered] for why.
class HandoffRepoState {
  const HandoffRepoState({
    this.branch,
    this.hasRemote,
    this.defaultBranch,
    this.commitsAhead,
  });

  /// The checked-out branch; `null` when detached or unreadable.
  final String? branch;

  /// Whether the repository has an `origin` remote. `false` is a definite "no
  /// remote" straight from `git`; `null` means git could not be asked.
  final bool? hasRemote;

  /// The remote's default branch, per `gh repo view`. `null` when `gh` is
  /// missing, unauthenticated, or the repository is not on GitHub — all of
  /// which are "could not tell", not "there isn't one".
  final String? defaultBranch;

  /// Commits on the current branch that are not on the remote default branch.
  /// `null` when the base ref is not fetched locally or the count failed.
  final int? commitsAhead;

  @override
  String toString() =>
      'HandoffRepoState(branch: $branch, hasRemote: $hasRemote, '
      'defaultBranch: $defaultBranch, commitsAhead: $commitsAhead)';
}

/// A one-click follow-up, offered as a short prompt.
enum HandoffAction {
  /// Hand the work to the agent to record. Ungated: an empty index costs one
  /// line in the transcript, and gating it on the working tree would make the
  /// button flicker in and out while the agent edits files.
  commit(label: 'Commit', prompt: 'Commit the changes.'),

  /// Propose the branch. The only gated action — see [isHandoffActionOffered].
  pullRequest(
    label: 'Open PR',
    prompt: 'Push this branch and open a pull request.',
  ),

  /// Check the work. Ungated: the agent knows the repository's test command,
  /// and "there are no tests" is a useful answer in the transcript.
  runTests(label: 'Run tests', prompt: 'Run the tests.');

  const HandoffAction({required this.label, required this.prompt});

  /// The button's caption.
  final String label;

  /// The text sent into the session, **verbatim**.
  final String prompt;
}

/// Whether [action] should be offered for [state].
///
/// Only [HandoffAction.pullRequest] is gated, and it is withheld only on facts
/// we positively established:
///
/// * the repository has no `origin` remote, so no default branch can resolve;
/// * the current branch *is* the default branch, so there is nothing to propose
///   it against;
/// * the branch is provably zero commits ahead of the remote default branch.
///
/// Anything unknown — [state] itself `null`, a probe that threw, `gh` absent,
/// a base ref that is not fetched — is offered. This is dray's `canOpenPr`
/// bias, and it is the right one **here specifically**: over-offering costs a
/// wasted click whose only consequence is one prompt in the transcript that the
/// agent answers with "this branch has nothing to propose", while under-offering
/// silently hides the action with no way for the user to discover why. The bias
/// is only defensible because the button is a prompt. A direct-execution button
/// should fail closed instead — an unnecessary `gh pr create` is a real remote
/// side effect, not a sentence in a log.
///
/// The cost of the bias, honestly: while the probe is in flight the state is
/// unknown, so the PR button is offered and may disappear a moment later once
/// the facts land. Appearing-then-vanishing is the failure mode we accept.
bool isHandoffActionOffered(HandoffAction action, HandoffRepoState? state) {
  if (action != HandoffAction.pullRequest) return true;
  if (state == null) return true;
  if (state.hasRemote == false) return false;
  if (state.branch != null && state.branch == state.defaultBranch) return false;
  if (state.commitsAhead == 0) return false;
  return true;
}

/// The actions offered for [state], in row order.
List<HandoffAction> handoffActionsFor(HandoffRepoState? state) => [
  for (final action in HandoffAction.values)
    if (isHandoffActionOffered(action, state)) action,
];
