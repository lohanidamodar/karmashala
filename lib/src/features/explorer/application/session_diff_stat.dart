import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../environments/domain/environment_path.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../cli_detection/application/cli_detection_providers.dart';

/// How much work a session has produced, in the terms a row can show.
///
/// **The line counts are a declared seam, not an oversight.** MonoCode's cards
/// read `+949 −10` and that is the shape this type is built for; what the app
/// can answer *today* from `git status` is how many files changed, and from
/// `git rev-list` how many commits are ahead. [added] and [removed] stay null
/// until something computes a numstat — the delivery-lifecycle work in backlog
/// item 2 owns `git/`, and filling these two fields is all it has to do. The
/// card already lays out for them, so nothing moves when they arrive.
class SessionDiffStat {
  const SessionDiffStat({
    this.branch,
    this.changedFiles,
    this.commitsAhead,
    this.added,
    this.removed,
  });

  /// Nothing is known — git could not answer, or there is no checkout.
  static const unknown = SessionDiffStat();

  /// The branch checked out where this session works.
  final String? branch;

  /// Files with working-tree changes.
  final int? changedFiles;

  /// Commits this checkout has that the repository's branch does not. Only
  /// meaningful for a session in its own worktree; null otherwise, because a
  /// checkout is never ahead of itself.
  final int? commitsAhead;

  /// Lines added / removed. See the class comment: nothing sets these yet.
  final int? added;
  final int? removed;

  bool get hasLineCounts => added != null || removed != null;

  /// Whether there is anything worth drawing on the card's third line.
  bool get isEmpty =>
      !hasLineCounts &&
      (changedFiles == null || changedFiles == 0) &&
      (commitsAhead == null || commitsAhead == 0);

  SessionDiffStat copyWith({
    String? branch,
    int? changedFiles,
    int? commitsAhead,
    int? added,
    int? removed,
  }) => SessionDiffStat(
    branch: branch ?? this.branch,
    changedFiles: changedFiles ?? this.changedFiles,
    commitsAhead: commitsAhead ?? this.commitsAhead,
    added: added ?? this.added,
    removed: removed ?? this.removed,
  );

  @override
  bool operator ==(Object other) =>
      other is SessionDiffStat &&
      other.branch == branch &&
      other.changedFiles == changedFiles &&
      other.commitsAhead == commitsAhead &&
      other.added == added &&
      other.removed == removed;

  @override
  int get hashCode =>
      Object.hash(branch, changedFiles, commitsAhead, added, removed);

  @override
  String toString() =>
      'SessionDiffStat($branch, $changedFiles changed, ahead $commitsAhead)';
}

/// The branch and change count of one checkout.
///
/// **Keyed by the checkout, not by the session**, and that is the whole reason
/// this provider exists separately: twenty sessions in a repository that has no
/// worktrees are twenty rows describing *one* working tree, and keying by
/// session would run `git status` twenty times for one answer. Riverpod's
/// family cache does the deduplication for free once the key is the thing being
/// measured.
///
/// Never throws: a folder that is not a repository, or a git that is not
/// installed, is a row with nothing to say — not an error banner in a tree.
final checkoutStatProvider = FutureProvider.autoDispose
    .family<SessionDiffStat, EnvironmentPath>((ref, dir) async {
      // Recomputed when the workspace mutates, which is the same signal the
      // rest of the Explorer rebuilds on. No polling: a status that is only as
      // fresh as the last workspace change is honest, and cheap.
      ref.watch(sessionsRevisionProvider);
      final changes = ref.read(changesServiceProvider);
      try {
        final files = await changes.changes(dir);
        final branch = await changes.currentBranch(dir);
        return SessionDiffStat(branch: branch, changedFiles: files.length);
      } catch (_) {
        return SessionDiffStat.unknown;
      }
    });

/// The stat for a native session: its worktree's when it has one, otherwise the
/// repository's.
final sessionDiffStatProvider = FutureProvider.autoDispose
    .family<SessionDiffStat, String>((ref, sessionId) async {
      ref.watch(sessionsRevisionProvider);
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      if (session == null) return SessionDiffStat.unknown;
      final repository = ref
          .read(repositoryDaoProvider)
          .getById(session.repositoryId);
      if (repository == null) return SessionDiffStat.unknown;

      final worktree = session.worktree;
      if (worktree == null) {
        return ref.watch(checkoutStatProvider(repository.path).future);
      }

      // Both watches are taken before the first await: `ref.watch` after an
      // await is a documented Riverpod hazard, and taking them together also
      // runs the two checkouts' `git status` concurrently rather than in series.
      final own = ref.watch(checkoutStatProvider(worktree).future);
      final base = ref.watch(checkoutStatProvider(repository.path).future);
      final stat = await own;
      final baseBranch = (await base).branch;
      if (baseBranch == null || baseBranch == stat.branch) return stat;

      // Ahead of what the repository itself has checked out — a local question
      // with a local answer. Comparing against `origin/<default>` would mean a
      // network call per row, which a tree cannot afford.
      try {
        final ahead = await ref
            .read(changesServiceProvider)
            .commitsAhead(worktree, base: baseBranch);
        return stat.copyWith(commitsAhead: ahead);
      } catch (_) {
        return stat;
      }
    });

/// The stat for a repository — what an imported session's row shows, since an
/// imported conversation has no checkout of its own.
final repositoryDiffStatProvider = FutureProvider.autoDispose
    .family<SessionDiffStat, String>((ref, repositoryId) async {
      final repository = ref.read(repositoryDaoProvider).getById(repositoryId);
      if (repository == null) return SessionDiffStat.unknown;
      return ref.watch(checkoutStatProvider(repository.path).future);
    });

/// What a project header reports on its right-hand side.
class ProjectSummary {
  const ProjectSummary({required this.sessions, this.changedFiles});

  final int sessions;

  /// Changed files across the project's repositories, or null while unknown.
  final int? changedFiles;

  /// The header's right-hand label, or null when there is nothing to say.
  String? get label {
    if (sessions == 0) return null;
    final files = changedFiles;
    return [
      '$sessions session${sessions == 1 ? '' : 's'}',
      if (files != null && files > 0) '$files changed',
    ].join(' · ');
  }

  @override
  bool operator ==(Object other) =>
      other is ProjectSummary &&
      other.sessions == sessions &&
      other.changedFiles == changedFiles;

  @override
  int get hashCode => Object.hash(sessions, changedFiles);
}

/// Sessions and changed files under one project.
///
/// The session count is synchronous (it is two DAO reads); the change count is
/// whatever the per-checkout providers have already answered, so a header never
/// waits on git and never starts a second wave of it.
final projectSummaryProvider = Provider.autoDispose
    .family<ProjectSummary, String>((ref, projectId) {
      ref.watch(sessionsRevisionProvider);
      final repositories = ref
          .read(repositoryDaoProvider)
          .getByProject(projectId);
      final sessionDao = ref.read(sessionDaoProvider);
      final importedDao = ref.read(importedSessionDaoProvider);

      var sessions = 0;
      int? changed;
      for (final repository in repositories) {
        sessions += sessionDao.getByRepository(repository.id).length;
        sessions += importedDao.getByRepository(repository.id).length;
        final stat = ref
            .watch(checkoutStatProvider(repository.path))
            .asData
            ?.value;
        final files = stat?.changedFiles;
        if (files != null) changed = (changed ?? 0) + files;
      }
      return ProjectSummary(sessions: sessions, changedFiles: changed);
    });
