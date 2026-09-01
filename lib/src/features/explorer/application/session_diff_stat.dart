import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../environments/domain/environment_path.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../sessions/domain/session_delivery.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../notifications/application/attention_inbox.dart';
import '../../sessions/domain/session_status.dart';
import 'checkout.dart';

/// How much work a session has produced, in the terms a row can show.
///
/// **A projection of [SessionDelivery], not a second measurement.** Until Loop
/// 67 this type had its own providers running their own `git status`, and its
/// [added]/[removed] were never filled — so MonoCode's `+949 −10`, which is the
/// shape the card was built for, could not render outside a widget test while
/// [SessionDelivery.lines] held exactly that number a provider away. There is
/// now one producer of a checkout's local git facts (`checkoutDeliveryProvider`
/// and friends) and this is the narrow view of it a tree row draws.
class SessionDiffStat {
  const SessionDiffStat({
    this.branch,
    this.changedFiles,
    this.commitsAhead,
    this.added,
    this.removed,
  });

  /// What a row shows of [delivery].
  ///
  /// An **empty** numstat is dropped rather than shown as `+0 −0`: git's
  /// `--numstat` sees no untracked file, so a checkout whose only change is a
  /// new file reports zero lines over zero files, and the card's "N changed"
  /// fallback is the truer sentence for it. Same rule as
  /// [SessionDelivery.lineLabel].
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

  /// Commits this checkout has that its base does not — `origin/HEAD` when the
  /// clone recorded one, otherwise the branch the owning repository has checked
  /// out. Null when git could not say, or there is nothing to measure against.
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

/// The branch and change count of one checkout.
///
/// **Keyed by the checkout, not by the session**, and that is the whole reason
/// this provider exists separately: twenty sessions in a repository that has no
/// worktrees are twenty rows describing *one* working tree, and keying by
/// session would run `git status` twenty times for one answer. Riverpod's
/// family cache does the deduplication for free once the key is the thing being
/// measured.
///
/// The key is a [Checkout] rather than a bare [EnvironmentPath] because the
/// three places a path reaches this tree from spell the same directory three
/// ways — see [Checkout]. Since Loop 57 a repository row, its worktree row and
/// every card under either share one answer whichever spelling arrived first.
///
/// Since Loop 67 the measurement itself is [checkoutDeliveryProvider]'s, on the
/// same key: one producer, so a row and the strip beside it cannot disagree.
/// Never throws — that provider folds every failure into "nothing to say".
final checkoutStatProvider = FutureProvider.autoDispose
    .family<SessionDiffStat, Checkout>(
      (ref, checkout) async => SessionDiffStat.from(
        await ref.watch(checkoutDeliveryProvider(checkout).future),
      ),
    );

/// What one worktree of [repo] has: its own branch and change count, plus how
/// far ahead it is of its base.
///
/// Shared by a worktree *row* and by every session card inside it, so a
/// worktree with four sessions costs the same as a worktree with none.
final worktreeStatProvider = FutureProvider.autoDispose
    .family<
      SessionDiffStat,
      ({EnvironmentPath repo, EnvironmentPath worktree})
    >(
      (ref, key) async => SessionDiffStat.from(
        await ref.watch(worktreeDeliveryProvider(key).future),
      ),
    );

/// The stat for a native session: its worktree's when it has one, otherwise the
/// repository's. Both cases delegate, so a card never asks git anything a row
/// above it has not already asked.
///
/// [sessionLocalDeliveryProvider] rather than `sessionDeliveryProvider`: a tree
/// row wants the local facts, and the full provider would add a `gh` process
/// per visible checkout.
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

  /// Sessions whose lifecycle is [SessionStatus.running]. The row's own record
  /// of what it started — deliberately not a claim that a process is alive,
  /// which only `SessionWhereabouts` may make.
  final int running;

  /// Unseen attention-inbox items belonging to this project's sessions.
  final int needsAttention;

  /// The header's right-hand label, or null when there is nothing to say.
  ///
  /// [running] and [needsAttention] are **not** in here: they are counts that
  /// mean something, so they are drawn as semantic badges rather than folded
  /// into a grey clause where a stuck agent reads like a word.
  String? get label {
    if (sessions == 0) return null;
    final files = changedFiles;
    return [
      '$sessions session${sessions == 1 ? '' : 's'}',
      if (files != null && files > 0) '$files changed',
    ].join(' · ');
  }

  /// How the attention count reads beside [label], or null when nothing is
  /// waiting. Worded exactly as the status bar words it, because they are the
  /// same number and a user who sees "1 needs you" in one place and "1 need
  /// you" in another has to wonder whether they are two counts.
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

/// The project containing each native or imported session row.
///
/// Kept apart from the inbox projection because session placement changes on a
/// workspace mutation, while attention can change on every status cycle. The
/// latter must not turn into a database sweep.
final sessionProjectIdsProvider = Provider<Map<String, String>>((ref) {
  // Three unfiltered table scans, so this is the watcher it matters most to
  // narrow. A row's *name* is not its placement, and neither is its status:
  // only rows appearing, going away, or moving to another repository can
  // change this map. `session_signal_cost_test.dart` pins it at zero reads for
  // a rename.
  ref.watchSessionKinds(const {
    SessionChangeKind.membership,
    SessionChangeKind.placement,
    SessionChangeKind.workspace,
  });
  final repositories = {
    for (final repository in ref.read(repositoryDaoProvider).getAll())
      repository.id: repository.projectId,
  };
  return Map.unmodifiable({
    for (final session in ref.read(sessionDaoProvider).getAll())
      session.id: ?repositories[session.repositoryId],
    for (final session in ref.read(importedSessionDaoProvider).getAll())
      session.id: ?repositories[session.repositoryId],
  });
});

/// Unseen attention items grouped by project.
///
/// The inbox is capped, so projecting it is bounded. Project headers select
/// their own integer from this map; a notification in one project therefore
/// leaves every unrelated header asleep.
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

/// Sessions, changed files, running sessions and waiting work under one project.
///
/// The counts are synchronous (DAO reads and one already-computed inbox); the
/// change count is whatever the per-checkout providers have already answered, so
/// a header never waits on git and never starts a second wave of it.
///
/// **That last clause used to be false, and it was the app's worst cost.**
/// `ref.watch` on an `autoDispose` family does not read a provider, it *creates*
/// one — so this loop was starting [checkoutDeliveryProvider] for every
/// repository in the project, at five git subprocesses each. A project the
/// owner had rescanned into 69 checkouts therefore ran **345 git processes to
/// draw a project header the user had not even expanded**, on WSL paths over
/// 9p. `ref.exists` is the read the comment always described, and it is the
/// same rule `_changeRank` in `checkout_default.dart` already holds itself to:
/// read the cache somebody else filled, never fill it.
///
/// The consequence is that a header shows a change count only once something
/// that legitimately measures a checkout — the delivery strip, the Changes
/// panel — has measured it. That is the honest version: a number nobody has
/// asked for is not a number worth 345 subprocesses.
final projectSummaryProvider = Provider.autoDispose
    .family<ProjectSummary, String>((ref, projectId) {
      // A header counts sessions and running sessions; it never names one. So
      // a rename leaves every project header asleep — the same rule the
      // attention count above already holds. Placement is on the list because
      // the count is per repository: a row moving between checkouts moves it
      // from one header to another.
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
      // The one attention count in the app, narrowed to this project rather
      // than recomputed: a second definition of "needs you" is a second number
      // that can disagree with the tray. Selecting the integer is important:
      // one waiting session must not wake every project header.
      final needsAttention = ref.watch(
        projectAttentionCountsProvider.select(
          (counts) => counts[projectId] ?? 0,
        ),
      );

      var sessions = 0;
      var running = 0;
      int? changed;
      for (final repository in repositories) {
        for (final session in sessionDao.getByRepository(repository.id)) {
          sessions++;
          if (session.status == SessionStatus.running) running++;
        }
        sessions += importedDao.getByRepository(repository.id).length;
        // The shared producer rather than this file's projection of it: a
        // session card, the delivery strip and the Changes panel all funnel
        // into `checkoutDeliveryProvider`, so that is the one most likely to be
        // warm by the time a header asks.
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
