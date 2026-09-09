import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import '../../git/application/changes_providers.dart';
import 'package:karmashala_git/git.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../sessions/domain/handoff_packet.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_launch.dart';
import '../../sessions/domain/session_lineage.dart';
import '../domain/review_brief.dart';

/// One installation that could check another session's work.
///
/// Shaped like `HandoffTarget` on purpose: the two answer the same question
/// about the same rows, and a second shape for "an agent you could send this
/// to" would drift from the first the moment either gained a refusal the other
/// did not.
class ReviewTarget {
  const ReviewTarget({
    required this.installation,
    required this.descriptor,
    required this.agentName,
    required this.permission,
    required this.isSameAgent,
    this.refusal,
  });

  final AgentInstallation installation;
  final AgentDescriptor? descriptor;
  final String agentName;

  /// What this review will actually be launched under — capped, never carried
  /// up from the session being reviewed.
  final ReviewCarry permission;

  /// Whether this is a second installation of the *same* agent as the one that
  /// did the work.
  ///
  /// Still a real review — a different process, a different session, and
  /// therefore an [VerdictAttribution.independent] verdict — but it is the same
  /// model reading its own kind of mistake, and a surface that offered it
  /// without saying so would oversell what was bought.
  final bool isSameAgent;

  /// Why this agent cannot be handed a review, or null when it can.
  final String? refusal;

  bool get canReview => refusal == null;
}

/// Whether a session's work can be independently checked, and by whom.
class ReviewOffer {
  const ReviewOffer({required this.targets, this.refusal});

  /// Every installation that is not the one that did the work, in registry
  /// order, including any that cannot receive a brief and say why.
  final List<ReviewTarget> targets;

  /// Why no review can be started at all. Null when one can.
  ///
  /// Always a sentence naming the actual state — "only Claude Code is
  /// installed here" — because the affordance this backs is disabled far more
  /// often than it is pressed, and a greyed-out button with no reason reads as
  /// a broken feature rather than as a machine with one agent on it.
  final String? refusal;

  bool get isPossible => refusal == null && targets.any((t) => t.canReview);

  /// The reviewer to offer first: a different agent where there is one,
  /// because a second opinion from a different model is worth more than a
  /// second opinion from the same one.
  ReviewTarget? get preferred {
    ReviewTarget? sameAgent;
    for (final target in targets) {
      if (!target.canReview) continue;
      if (!target.isSameAgent) return target;
      sameAgent ??= target;
    }
    return sameAgent;
  }
}

/// Starts sessions whose job is to check another session's work.
///
/// Everything here ends at [SessionLauncher.launch], which is the whole point:
/// a review session is an **ordinary session row** — it resumes, renames,
/// forks, hands off and draws in the side panel like any other — and the only
/// things that make it a review are the brief in `firstMessage` and the capped
/// permission it launches under. That is the lesson `SessionHandoffService`
/// already learned and the reason there is no `SessionLink.review`: a new link
/// kind would be a new session kind wearing a smaller name, and every surface
/// that switches on the kind would have to learn about it.
class ReviewSessionService {
  ReviewSessionService(this._ref);

  final Ref _ref;

  // --- what can be offered ---------------------------------------------------

  /// Who could review [sessionId]'s work, or why nobody can.
  ReviewOffer offerFor(String sessionId) {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) {
      return const ReviewOffer(
        targets: [],
        refusal: 'This session no longer exists, so there is nothing to review.',
      );
    }
    final repo = _ref.read(repositoryDaoProvider).getById(session.repositoryId);
    if (repo == null) {
      return const ReviewOffer(
        targets: [],
        refusal:
            'This session\'s repository is no longer available, so its work '
            'cannot be read.',
      );
    }

    // The same cap that governs a spawn, checked *before* the affordance is
    // offered rather than at launch: a review is a spawn, and a button that
    // fails on press has already cost the user the press.
    final depth = _ref.read(sessionLauncherProvider).depthForChildOf(sessionId);
    if (!depth.isAllowed) {
      return ReviewOffer(targets: const [], refusal: depth.refusal);
    }

    final installations = _ref.read(agentInstallationDaoProvider);
    final registry = _ref.read(agentRegistryProvider);
    final own = installations.getById(session.agentInstallationId);
    final ownName = own == null
        ? 'the agent that ran it'
        : registry.displayNameFor(own.agentId);
    final effective = _ref
        .read(sessionLauncherProvider)
        .effectivePermissionFor(sessionId);
    // How permissive the reviewed session is, on the one scale every agent
    // shares. Its own vocabulary cannot cross to another CLI; the rung can.
    final risk = effective?.descriptor?.launch.permission.riskOf(
      effective.selection,
    );

    final targets = <ReviewTarget>[];
    for (final installation in installations.getByEnvironment(
      repo.path.environmentId,
    )) {
      // The one hard rule: a session cannot grade itself. Compared by
      // *installation*, not by agent, because two installations of one agent
      // are two processes and two sessions — which is what
      // `VerdictAttribution` actually measures.
      if (installation.id == session.agentInstallationId) continue;
      final descriptor = registry.byId(installation.agentId);
      final name = registry.displayNameFor(installation.agentId);
      targets.add(
        ReviewTarget(
          installation: installation,
          descriptor: descriptor,
          agentName: name,
          permission: carryReviewPermission(
            sessionRisk: risk ?? reviewPermissionCeiling,
            target: descriptor,
            targetName: name,
          ),
          isSameAgent: own != null && installation.agentId == own.agentId,
          refusal: _refusalFor(descriptor, name),
        ),
      );
    }

    if (targets.isEmpty) {
      return ReviewOffer(
        targets: const [],
        refusal:
            '$ownName is the only agent installed here, and a session cannot '
            'check its own work. Install a second agent with "Discover '
            'agents" in Settings to get an independent verdict.',
      );
    }
    if (!targets.any((target) => target.canReview)) {
      return ReviewOffer(
        targets: targets,
        refusal: [
          'No other installed agent can be handed a review brief.',
          for (final target in targets) '${target.agentName}: ${target.refusal}',
        ].join(' '),
      );
    }
    return ReviewOffer(targets: targets);
  }

  /// Why [descriptor] cannot be handed a brief, or null.
  ///
  /// The same single requirement a handoff has, for the same reason: the brief
  /// is delivered as the agent's **opening prompt argument**, so an agent that
  /// takes none would be launched into the right directory having been told
  /// nothing — a blank session wearing a review's name, whose silence would
  /// then read as "nothing found".
  String? _refusalFor(AgentDescriptor? descriptor, String name) {
    if (descriptor == null) {
      return 'Karmashala has no descriptor for this agent, so it cannot be '
          'told what to review.';
    }
    if (!descriptor.launch.acceptsPromptArgument) {
      return '$name takes no opening prompt, so the review brief could not be '
          'delivered — the session would start knowing nothing.';
    }
    return null;
  }

  // --- the brief -------------------------------------------------------------

  /// Assembles what the reviewer will be told about [sessionId].
  ///
  /// Separate from the launch so a caller can render it, and so it can be
  /// tested without starting a process. Every input is gathered best-effort and
  /// a failure becomes the null the brief renders as an admission — nothing
  /// here throws for a git that would not answer.
  Future<ReviewBrief> buildBrief({
    required String sessionId,
    required String targetAgentName,
    String? claim,
    String? permissionSummary,
    ReviewDiffBudget budget = const ReviewDiffBudget(),
  }) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) throw StateError('This session no longer exists.');
    final registry = _ref.read(agentRegistryProvider);
    final authorAgentId = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    final directory = _directoryOf(session);

    final branch = directory == null ? null : await _branchOf(directory);
    final base = await _baseBranch(session);
    final ahead = directory == null || base == null
        ? null
        : await _commitsAhead(directory, base);
    final changes = directory == null ? null : await _changesIn(directory);
    final diff = directory == null ? null : await _diffIn(directory);
    final trimmed = diff == null ? null : trimReviewDiff(diff, budget);

    return ReviewBrief(
      authorAgentName: authorAgentId == null
          ? 'a previous agent'
          : registry.displayNameFor(authorAgentId),
      reviewerAgentName: targetAgentName,
      subjectTitle: session.title,
      // Karmashala's own id, deliberately — see [ReviewBrief.subjectSessionId].
      subjectSessionId: session.id,
      claim: claim?.trim().isEmpty ?? true ? null : claim!.trim(),
      workingDirectory: directory?.path,
      branch: branch,
      baseBranch: base,
      commitsAhead: ahead,
      changes: changes,
      diff: trimmed?.text,
      diffOmittedCharacters: trimmed?.omitted ?? 0,
      permissionSummary: permissionSummary,
    );
  }

  // --- starting the review ---------------------------------------------------

  /// Starts a session whose job is to check [sessionId]'s work and record a
  /// verdict against it.
  ///
  /// The reviewer runs in the **same directory** as the work — that is what
  /// makes `git diff` and the tests mean anything — and under
  /// [carryReviewPermission], which can only ever be less permissive than the
  /// session it is checking.
  ///
  /// The old session is not touched: not ended, not marked, not told. A review
  /// is an observation, and an observation that changes its subject is not one.
  Future<SessionLaunchResult> startReview({
    required String sessionId,
    required String targetInstallationId,
    String? claim,
  }) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) throw StateError('This session no longer exists.');
    if (targetInstallationId == session.agentInstallationId) {
      throw StateError(
        'A session cannot check its own work — that is the self-graded exam an '
        'independent review exists to replace. Pick a different installation.',
      );
    }
    final repository = _ref
        .read(repositoryDaoProvider)
        .getById(session.repositoryId);
    if (repository == null) {
      throw StateError('This session\'s repository is no longer available.');
    }
    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(targetInstallationId);
    if (installation == null) {
      throw StateError(
        'That agent is not installed any more. Run "Discover agents" in '
        'Settings.',
      );
    }
    final registry = _ref.read(agentRegistryProvider);
    final descriptor = registry.byId(installation.agentId);
    final name = registry.displayNameFor(installation.agentId);
    final refusal = _refusalFor(descriptor, name);
    if (refusal != null) throw StateError(refusal);

    final source = _ref
        .read(sessionLauncherProvider)
        .effectivePermissionFor(sessionId);
    final permission = carryReviewPermission(
      sessionRisk:
          source?.descriptor?.launch.permission.riskOf(source.selection) ??
          reviewPermissionCeiling,
      target: descriptor,
      targetName: name,
    );
    final brief = await buildBrief(
      sessionId: sessionId,
      targetAgentName: name,
      claim: claim,
      permissionSummary: permission.summary,
    );

    return _ref
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository,
            installation: installation,
            title: 'Review · ${session.title}',
            purpose: SessionPurpose.newSession,
            firstMessage: brief.render(),
            parentSessionId: sessionId,
            // An existing link kind, not a new one. A review is a session one
            // session caused another to exist for, which is exactly what
            // `spawn` has always meant.
            parentLink: SessionLink.spawn,
            // Never a new worktree: a review of a different checkout is a
            // review of different code.
            existingWorktree: session.worktree,
            workingDirectory: session.workingDirectory,
            permissionOverride: permission.selection,
          ),
        );
  }

  // --- reading the work ------------------------------------------------------

  EnvironmentPath? _directoryOf(Session session) {
    final recorded = session.workingDirectory ?? session.worktree;
    if (recorded != null) return recorded;
    return _ref.read(repositoryDaoProvider).getById(session.repositoryId)?.path;
  }

  Future<String?> _branchOf(EnvironmentPath directory) async {
    try {
      return await _ref.read(changesServiceProvider).currentBranch(directory);
    } on Object {
      return null;
    }
  }

  Future<String?> _baseBranch(Session session) async {
    final repo = _ref.read(repositoryDaoProvider).getById(session.repositoryId);
    if (repo == null) return null;
    try {
      return await _ref.read(changesServiceProvider).currentBranch(repo.path);
    } on Object {
      return null;
    }
  }

  Future<int?> _commitsAhead(EnvironmentPath directory, String base) async {
    try {
      return await _ref
          .read(changesServiceProvider)
          .commitsAhead(directory, base: base);
    } on Object {
      return null;
    }
  }

  Future<List<HandoffChange>?> _changesIn(EnvironmentPath directory) async {
    try {
      final changes = await _ref
          .read(changesServiceProvider)
          .changes(directory);
      return [
        for (final change in changes)
          HandoffChange(
            path: change.path,
            state: _stateWords(change),
            originalPath: change.originalPath,
          ),
      ];
    } on Object {
      // Null, not empty: "git could not be asked" and "the tree is clean" are
      // opposite answers to a reviewer, and only one of them is a reason to
      // stop reading.
      return null;
    }
  }

  /// The staged and unstaged diffs together.
  ///
  /// Both, because an agent that ran `git add` and stopped there has an empty
  /// unstaged diff and a full change in the index — and a review that read only
  /// the unstaged half would report on a diff nobody wrote.
  Future<String?> _diffIn(EnvironmentPath directory) async {
    final changes = _ref.read(changesServiceProvider);
    try {
      final unstaged = await changes.diff(directory);
      var staged = '';
      try {
        staged = await changes.diff(directory, staged: true);
      } on Object {
        // The unstaged half has already been read and is worth showing.
      }
      return [
        if (staged.trim().isNotEmpty) staged.trimRight(),
        if (unstaged.trim().isNotEmpty) unstaged.trimRight(),
      ].join('\n');
    } on Object {
      return null;
    }
  }

  String _stateWords(FileChange change) {
    final kind = switch (change.type) {
      FileChangeType.added => 'added',
      FileChangeType.modified => 'modified',
      FileChangeType.deleted => 'deleted',
      FileChangeType.renamed => 'renamed',
      FileChangeType.copied => 'copied',
      FileChangeType.untracked => 'untracked',
      // Named, because it is the one state that is not the user's own
      // edit: a merge stopped here and both sides are still in the index.
      FileChangeType.conflicted =>
        'conflicted (${(change.conflict ?? MergeConflict.unrecorded).words})',
      FileChangeType.unknown => 'changed (unrecognised git status)',
    };
    // A conflict is never described as staged: both sides sit in the index
    // because git put them there, and "staged" would read as work the user did.
    if (change.type == FileChangeType.conflicted) return kind;
    if (change.staged && change.unstaged) return '$kind, staged and unstaged';
    if (change.staged) return '$kind, staged';
    return kind;
  }
}

final reviewSessionServiceProvider = Provider<ReviewSessionService>(
  (ref) => ReviewSessionService(ref),
);

/// Who could review one session's work.
///
/// A provider rather than a service call in `build`, for the same reason
/// `sessionContinuationProvider` is one: the answer comes from three rows the
/// widget would otherwise re-read on every rebuild.
final sessionReviewOfferProvider = Provider.autoDispose
    .family<ReviewOffer, String>((ref, sessionId) {
      // The session's row and the installed agents both move under this.
      // Narrowed to the row, for the reason `sessionContinuationProvider`
      // gives: an untargeted bump still reaches it.
      ref.watchSession(sessionId);
      return ref.watch(reviewSessionServiceProvider).offerFor(sessionId);
    });
