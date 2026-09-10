import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import 'package:karmashala_session/delivery.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../notifications/application/attention_inbox.dart';
import 'package:karmashala_session/session.dart';
import 'checkout.dart';

/// How much work a session has produced, in the terms a row can show — a
/// projection of [SessionDelivery], never a second measurement of its own.
class SessionDiffStat {
  const SessionDiffStat({
    this.branch,
    this.changedFiles,
    this.commitsAhead,
    this.added,
    this.removed,
  });

  /// What a row shows of [delivery]. An *empty* numstat is dropped rather than
  /// shown as `+0 −0`: `--numstat` sees no untracked file.
  factory SessionDiffStat.from(SessionDelivery delivery) {
    final lines = delivery.lines;
    final counted = lines != null && !lines.isEmpty;
    return SessionDiffStat(
      branch: delivery.branch,
      changedFiles: delivery.dirtyFiles,
      commitsAhead: delivery.aheadOfBase,
      added: counted ? lines.added : null,
      removed: counted ? lines.removed : null,
    );
  }

  /// Nothing is known — git could not answer, or there is no checkout.
  static const unknown = SessionDiffStat();

  /// The branch checked out where this session works.
  final String? branch;

  /// Files with working-tree changes.
  final int? changedFiles;

  /// Commits this checkout has that its base does not — `origin/HEAD`, else the
  /// owning repository's branch. Null when git could not say.
  final int? commitsAhead;

  /// Lines added / removed against the same base, committed and uncommitted
  /// alike. Null when the numstat was empty or could not be read.
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

/// The branch and change count of one checkout, keyed by the *checkout*: twenty
/// sessions in one working tree would otherwise run `git status` twenty times.
/// Never throws — [checkoutDeliveryProvider] folds failure into silence.
final checkoutStatProvider = FutureProvider.autoDispose
    .family<SessionDiffStat, Checkout>(
      (ref, checkout) async => SessionDiffStat.from(
        await ref.watch(checkoutDeliveryProvider(checkout).future),
      ),
    );

/// What one worktree of [repo] has, shared by the worktree row and every
/// session card in it, so four sessions cost what none do.
final worktreeStatProvider = FutureProvider.autoDispose
    .family<
      SessionDiffStat,
      ({EnvironmentPath repo, EnvironmentPath worktree})
    >(
      (ref, key) async => SessionDiffStat.from(
        await ref.watch(worktreeDeliveryProvider(key).future),
      ),
    );

/// The stat for a native session: its worktree's, else its repository's, both
/// delegated. [sessionLocalDeliveryProvider] rather than the full one, which
/// would add a `gh` process per visible checkout.
final sessionDiffStatProvider = FutureProvider.autoDispose
    .family<SessionDiffStat, String>(
      (ref, sessionId) async => SessionDiffStat.from(
        await ref.watch(sessionLocalDeliveryProvider(sessionId).future),
      ),
    );

/// The stat for a repository — what an imported session's row shows, since an
/// imported conversation has no checkout of its own.
final repositoryDiffStatProvider = FutureProvider.autoDispose
    .family<SessionDiffStat, String>(
      (ref, repositoryId) async => SessionDiffStat.from(
        await ref.watch(repositoryDeliveryProvider(repositoryId).future),
      ),
    );

/// What a project header reports on its right-hand side.
class ProjectSummary {
  const ProjectSummary({
    required this.sessions,
    this.changedFiles,
    this.running = 0,
    this.needsAttention = 0,
  });

  final int sessions;

  /// Changed files across the project's repositories, or null while unknown.
  final int? changedFiles;

  /// Sessions whose lifecycle is [SessionStatus.running] — the row's record of
  /// what it started, not a claim that a process is alive.
  final int running;

  /// Unseen attention-inbox items belonging to this project's sessions.
  final int needsAttention;

  /// The header's right-hand label, or null when there is nothing to say.
  /// [running] and [needsAttention] are drawn as badges instead, not folded in.
  String? get label {
    if (sessions == 0) return null;
    final files = changedFiles;
    return [
      '$sessions session${sessions == 1 ? '' : 's'}',
      if (files != null && files > 0) '$files changed',
    ].join(' · ');
  }

  /// How the attention count reads beside [label]. Worded exactly as the status
  /// bar words it, because it is the same number.
  String? get attentionLabel => switch (needsAttention) {
    0 => null,
    1 => '1 needs you',
    final n => '$n need you',
  };

  @override
  bool operator ==(Object other) =>
      other is ProjectSummary &&
      other.sessions == sessions &&
      other.changedFiles == changedFiles &&
      other.running == running &&
      other.needsAttention == needsAttention;

  @override
  int get hashCode =>
      Object.hash(sessions, changedFiles, running, needsAttention);
}

/// The project containing each native or imported session row. Kept apart from
/// the inbox projection, which changes on every status cycle.
final sessionProjectIdsProvider = Provider<Map<String, String>>((ref) {
  // Three unfiltered table scans, so narrowing the watch matters most here: a
  // rename is not a placement change (`session_signal_cost_test.dart`).
  ref.watchSessionKinds(const {
    SessionChangeKind.membership,
    SessionChangeKind.placement,
    SessionChangeKind.workspace,
  });
  final repositories = {
    for (final repository in ref.read(repositoryDaoProvider).getAll())
      repository.id: repository.projectId,
  };
  // Two columns per row, not a decoded session: parsing an ISO timestamp per
  // row is 8% of the app's CPU under load (see `dateFromIso`).
  return Map.unmodifiable({
    for (final entry in ref.read(sessionDaoProvider).repositoryIdsById().entries)
      entry.key: ?repositories[entry.value],
    for (final entry
        in ref.read(importedSessionDaoProvider).repositoryIdsById().entries)
      entry.key: ?repositories[entry.value],
  });
});

/// Unseen attention items grouped by project. Headers select their own integer
/// out of this, so one notification leaves unrelated headers asleep.
final projectAttentionCountsProvider = Provider<Map<String, int>>((ref) {
  final projectIds = ref.watch(sessionProjectIdsProvider);
  final counts = <String, int>{};
  final countedSessions = <String>{};
  for (final item in ref.watch(attentionInboxProvider).pending) {
    if (!countedSessions.add(item.session.openId)) continue;
    final projectId = projectIds[item.session.openId];
    if (projectId != null) counts[projectId] = (counts[projectId] ?? 0) + 1;
  }
  return Map.unmodifiable(counts);
});

/// Sessions, changed files, running sessions and waiting work under one
/// project. `ref.exists`, never `ref.watch`, which on an autoDispose family
/// *creates*: that once ran 345 git processes for an unexpanded header.
final projectSummaryProvider = Provider.autoDispose
    .family<ProjectSummary, String>((ref, projectId) {
      // A header counts sessions, never names one, so a rename leaves every
      // header asleep. Placement counts: a row can move between checkouts.
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.status,
        SessionChangeKind.placement,
        SessionChangeKind.workspace,
      });
      final repositories = ref
          .read(repositoryDaoProvider)
          .getByProject(projectId);
      final sessionDao = ref.read(sessionDaoProvider);
      final importedDao = ref.read(importedSessionDaoProvider);
      // The one attention count in the app, narrowed rather than recomputed.
      // Selecting the integer keeps one waiting session from waking them all.
      final needsAttention = ref.watch(
        projectAttentionCountsProvider.select(
          (counts) => counts[projectId] ?? 0,
        ),
      );

      // Two statements for the whole project and no session decoded. Over eight
      // repositories the old per-repository shape cost 8 × 661 planner steps and
      // eight temp b-tree sorts at 100 sessions; the aggregate costs 903.
      final ids = [for (final repository in repositories) repository.id];
      final counts = sessionDao.countsByRepositories(ids);
      final sessions = counts.sessions + importedDao.countByRepositories(ids);
      final running = counts.running;

      int? changed;
      for (final repository in repositories) {
        // The shared producer rather than this file's projection: cards, the
        // delivery strip and the Changes panel all warm this one.
        final provider = checkoutDeliveryProvider(Checkout(repository.path));
        if (!ref.exists(provider)) continue;
        final files = ref.watch(provider).asData?.value.dirtyFiles;
        if (files != null) changed = (changed ?? 0) + files;
      }
      return ProjectSummary(
        sessions: sessions,
        changedFiles: changed,
        running: running,
        needsAttention: needsAttention,
      );
    });
