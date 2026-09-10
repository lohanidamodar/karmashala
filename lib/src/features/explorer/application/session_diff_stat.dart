import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../notifications/application/attention_inbox.dart';
import 'package:karmashala_ui/rows.dart';
import 'checkout.dart';

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
