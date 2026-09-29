import '../../workspaces/data/workspace_data.dart';
import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_ui/rows.dart';
import 'agent_state_providers.dart';
import 'project_working.dart';

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
    for (final repository in ref.read(workspaceDataProvider).repositories)
      repository.id: repository.projectId,
  };
  // Two columns per row, not a decoded session: parsing an ISO timestamp per
  // row is 8% of the app's CPU under load (see `dateFromIso`).
  return Map.unmodifiable({
    for (final entry
        in ref.read(sessionsDataProvider).repositoryIdsById().entries)
      entry.key: ?repositories[entry.value],
    for (final entry
        in ref.read(importedSessionsProvider).repositoryIdsById().entries)
      entry.key: ?repositories[entry.value],
  });
});

/// The sessions waiting on the user, grouped by project — the same set the
/// Sessions badge counts, so a project's shield and "2 need you" never count
/// a finished turn. Headers select their own integer out of this, so one ask
/// leaves unrelated headers asleep.
final projectAttentionCountsProvider = Provider<Map<String, int>>((ref) {
  final waiting = ref.watch(needsYouProvider);
  if (waiting.isEmpty) return const {};
  final projectIds = ref.watch(sessionProjectIdsProvider);
  final counts = <String, int>{};
  for (final openId in waiting.keys) {
    final projectId = projectIds[openId];
    if (projectId != null) counts[projectId] = (counts[projectId] ?? 0) + 1;
  }
  return Map.unmodifiable(counts);
});

/// How many sessions are *working* — in a turn right now — in each project.
/// Headers select their own integer, so a turn starting wakes one row; with
/// nothing working it reads no table at all.
final projectWorkingCountsProvider = Provider<Map<String, int>>((ref) {
  final working = ref.watch(workingSessionsProvider);
  if (working.isEmpty) return const {};
  final projectIds = ref.watch(sessionProjectIdsProvider);
  final counts = <String, int>{};
  for (final id in working) {
    final projectId = projectIds[id];
    if (projectId != null) counts[projectId] = (counts[projectId] ?? 0) + 1;
  }
  return Map.unmodifiable(counts);
});

/// One project's repositories, read once for its header and shared with the
/// branch its row reads from `HEAD`. A session's status is not a repository
/// fact, so a status tick re-reads nothing here.
final projectRepositoriesProvider = Provider.autoDispose
    .family<List<Repository>, String>((ref, projectId) {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.placement,
        SessionChangeKind.workspace,
      });
      return ref.read(workspaceDataProvider).repositoriesOf(projectId);
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
      final repositories = ref.watch(projectRepositoriesProvider(projectId));
      final sessionDao = ref.read(sessionsDataProvider);
      final importedDao = ref.read(importedSessionsProvider);
      // The one attention count in the app, narrowed rather than recomputed.
      // Selecting the integer keeps one waiting session from waking them all.
      final needsAttention = ref.watch(
        projectAttentionCountsProvider.select(
          (counts) => counts[projectId] ?? 0,
        ),
      );
      // Whether the running mark turns. The same narrowing, for the same reason.
      final working = ref.watch(
        projectWorkingCountsProvider.select((counts) => counts[projectId] ?? 0),
      );

      // Two statements for the whole project and no session decoded. Over eight
      // repositories the old per-repository shape cost 8 × 661 planner steps and
      // eight temp b-tree sorts at 100 sessions; the aggregate costs 903.
      final ids = [for (final repository in repositories) repository.id];
      final counts = sessionDao.countsByRepositories(ids);
      final sessions = counts.sessions + importedDao.countByRepositories(ids);
      final running = counts.running;

      int? changed;
      int? ahead;
      String? branch;
      for (final repository in repositories) {
        // The shared producer rather than this file's projection: cards, the
        // delivery strip and the Changes panel all warm this one.
        final checkout = Checkout(repository.path);
        final provider = checkoutDeliveryProvider(checkout);
        // Woken when anyone's reading of this checkout arrives, which
        // `exists` alone would never report.
        ref.watch(checkoutReadingsProvider.select((r) => r[checkout]));
        if (!ref.exists(provider)) continue;
        final delivery = ref.watch(provider).asData?.value;
        if (delivery == null) continue;
        final files = delivery.dirtyFiles;
        if (files != null) changed = (changed ?? 0) + files;
        final commits = delivery.aheadOfBase;
        if (commits != null) ahead = (ahead ?? 0) + commits;
        // One repository has one branch; several have no branch that is the
        // project's, and naming the first would be a guess.
        if (repositories.length == 1) branch = delivery.branch;
      }
      return ProjectSummary(
        sessions: sessions,
        changedFiles: changed,
        running: running,
        working: working,
        needsAttention: needsAttention,
        branch: branch,
        commitsAhead: ahead,
      );
    });
