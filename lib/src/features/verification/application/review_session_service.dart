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
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import '../domain/review_brief.dart';

/// One installation that could check another session's work. Shaped like
/// `HandoffTarget` so two answers about the same rows cannot drift apart.
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

  /// What this review launches under — capped, never carried up.
  final ReviewCarry permission;

  /// A second installation of the *same* agent: still an
  /// [VerdictAttribution.independent] verdict, but the same model's blind spots.
  final bool isSameAgent;

  /// Why this agent cannot be handed a review, or null when it can.
  final String? refusal;

  bool get canReview => refusal == null;
}

/// Whether a session's work can be independently checked, and by whom.
class ReviewOffer {
  const ReviewOffer({required this.targets, this.refusal});

  /// Every installation but the one that did the work, refusals included.
  final List<ReviewTarget> targets;

  /// Why no review can be started, null when one can — always a sentence: a
  /// greyed-out button with no reason reads as a broken feature.
  final String? refusal;

  bool get isPossible => refusal == null && targets.any((t) => t.canReview);

  /// The reviewer to offer first: a different agent where there is one.
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

/// Starts sessions whose job is to check another session's work. Everything
/// ends at [SessionLauncher.launch]: a review is an ordinary session row, made
/// one by its brief and its cap alone.
class ReviewSessionService {
  ReviewSessionService(this._ref);

  final Ref _ref;

  /// Who could review [sessionId]'s work, or why nobody can.
  ReviewOffer offerFor(String sessionId) {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) {
      return const ReviewOffer(
        targets: [],
        refusal:
            'This session no longer exists, so there is nothing to review.',
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

    // The spawn cap, checked before the button is offered, not on press.
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
    // The one scale every agent shares: a mode's vocabulary cannot cross.
    final risk = effective?.descriptor?.launch.permission.riskOf(
      effective.selection,
    );

    final targets = <ReviewTarget>[];
    for (final installation in installations.getByEnvironment(
      repo.path.environmentId,
    )) {
      // A session cannot grade itself. By installation, not agent: two
      // installations are two processes, which is what attribution means.
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
          for (final target in targets)
            '${target.agentName}: ${target.refusal}',
        ].join(' '),
      );
    }
    return ReviewOffer(targets: targets);
  }

  /// Why [descriptor] cannot be handed a brief, or null. The brief is the
  /// agent's opening prompt, so one that takes none would launch blank.
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

  /// What the reviewer is told about [sessionId], apart from the launch so it
  /// can be rendered and tested. Nothing throws; a failure becomes null.
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

  /// Starts a session whose job is to check [sessionId]'s work and record a
  /// verdict. It runs in the same directory, under [carryReviewPermission],
  /// which is never more permissive; the reviewed session is not touched.
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
            // An existing link kind: one session causing another to exist
            // is what `spawn` has always meant.
            parentLink: SessionLink.spawn,
            // Never a new worktree: a different checkout is different code.
            existingWorktree: session.worktree,
            workingDirectory: session.workingDirectory,
            permissionOverride: permission.selection,
          ),
        );
  }

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
      // Null, not empty: "could not be asked" is not "the tree is clean".
      return null;
    }
  }

  /// Both diffs — an agent that ran `git add` has an empty unstaged one.
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
      // The one state that is not the user's own edit: a stopped merge.
      FileChangeType.conflicted =>
        'conflicted (${(change.conflict ?? MergeConflict.unrecorded).words})',
      FileChangeType.unknown => 'changed (unrecognised git status)',
    };
    // Never "staged": git put both sides in the index, not the user.
    if (change.type == FileChangeType.conflicted) return kind;
    if (change.staged && change.unstaged) return '$kind, staged and unstaged';
    if (change.staged) return '$kind, staged';
    return kind;
  }
}

final reviewSessionServiceProvider = Provider<ReviewSessionService>(
  (ref) => ReviewSessionService(ref),
);

/// Who could review one session's work. A provider, not a call in `build`: it
/// reads three rows a widget would otherwise re-read every rebuild.
final sessionReviewOfferProvider = Provider.autoDispose
    .family<ReviewOffer, String>((ref, sessionId) {
      // Narrowed to the row; an untargeted bump still reaches it.
      ref.watchSession(sessionId);
      return ref.watch(reviewSessionServiceProvider).offerFor(sessionId);
    });
