import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../environments/domain/environment_path.dart';
import '../../explorer/application/checkout.dart';
import '../../git/application/changes_providers.dart';
import '../../git/domain/remote_repo.dart';
import '../../github/application/github_providers.dart';
import '../../github/domain/pull_request_snapshot.dart';
import '../../notifications/application/notification_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../domain/delivery_action.dart';
import '../domain/session_delivery.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_ui_providers.dart';

/// How often the pull request and its checks are re-read while the app is in
/// front. A provider so a test can make it long enough never to fire.
///
/// Two minutes because the answer costs a `gh` process per checkout and nothing
/// downstream is time-critical: a check that went red is worth knowing about
/// within a couple of minutes, not within a second.
final deliveryPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(minutes: 2),
);

/// Ticks when the remote half of delivery state should be re-read.
///
/// **One timer for the whole app**, not one per session: twenty rows watching
/// this share a tick, and each of their `gh` calls is already deduplicated by
/// [checkoutPullRequestProvider]'s checkout key.
///
/// It does not tick while the window is unfocused — nobody is reading — and
/// bumps once when focus comes back, so returning to the app shows current
/// state without having polled through lunch.
class DeliveryPollController extends Notifier<int> {
  Timer? _timer;

  @override
  int build() {
    final interval = ref.watch(deliveryPollIntervalProvider);
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) {
      if (ref.read(windowFocusedProvider)) state++;
    });
    ref.onDispose(() => _timer?.cancel());
    ref.listen(windowFocusedProvider, (previous, next) {
      if (next && previous == false) state++;
    });
    return 0;
  }
}

final deliveryPollProvider = NotifierProvider<DeliveryPollController, int>(
  DeliveryPollController.new,
);

/// The **local** half of a checkout's delivery state: branch, upstream, dirty
/// files, `+N −M`, and how far it stands from its base. No network, no `gh`.
///
/// Keyed by the checkout for the same reason Loop 50's `checkoutStatProvider`
/// is: twenty sessions in a repository with no worktrees are twenty rows
/// describing *one* working tree, and keying by session would run git twenty
/// times for one answer.
///
/// Costs three to five processes: one `git status --porcelain=v1 --branch`
/// (branch, upstream, divergence and the file list together), one `git remote
/// get-url`, and — when there is a remote — `rev-parse origin/HEAD` plus a
/// `rev-list` and a `diff --numstat` against it. Recomputed when the workspace
/// mutates, which is the signal the rest of the Explorer already rebuilds on.
///
/// Never throws: a folder that is not a repository is a row with nothing to
/// say, not an error banner in a tree.
final checkoutDeliveryProvider = FutureProvider.autoDispose
    .family<SessionDelivery, Checkout>((ref, checkout) async {
      ref.watch(sessionsRevisionProvider);
      final changes = ref.read(changesServiceProvider);
      final dir = checkout.path;

      final status = await _orNull(() => changes.statusWithBranch(dir));
      if (status == null) return SessionDelivery.unknown;

      final remoteUrl = await _orNull(() => changes.remoteUrl(dir));
      final hasRemote = remoteUrl != null;
      final base = hasRemote
          ? await _orNull(() => changes.originHead(dir))
          : null;

      // Both against the same base, and started together: they are two
      // processes that do not need each other's answer.
      final aheadBehind = base == null
          ? null
          : await _orNull(() => changes.aheadBehind(dir, base: base));
      final lines = await _orNull(() => changes.diffStat(dir, base: base));

      return SessionDelivery(
        branch: status.branch,
        baseBranch: base,
        upstream: status.upstream,
        hasRemote: hasRemote,
        remote: RemoteRepo.parse(remoteUrl),
        defaultBranch: _branchOf(base),
        dirtyFiles: status.changes.length,
        lines: lines,
        aheadOfBase: aheadBehind?.ahead,
        behindBase: aheadBehind?.behind,
        unpushed: status.aheadOfUpstream,
      );
    });

/// A worktree's delivery state, measured against the repository it came from
/// when the remote's default branch is not recorded locally.
///
/// Shared by every session inside one worktree, so a worktree with four
/// sessions costs the same as a worktree with one.
final worktreeDeliveryProvider = FutureProvider.autoDispose
    .family<
      SessionDelivery,
      ({EnvironmentPath repo, EnvironmentPath worktree})
    >((ref, key) async {
      // Both watches are taken before the first await: `ref.watch` after an
      // await is a documented Riverpod hazard, and taking them together runs
      // the two checkouts' git concurrently rather than in series.
      final own = ref.watch(
        checkoutDeliveryProvider(Checkout(key.worktree)).future,
      );
      final parent = ref.watch(
        checkoutDeliveryProvider(Checkout(key.repo)).future,
      );
      final delivery = await own;
      if (delivery.baseBranch != null) return delivery;

      // No `origin/HEAD` to measure against. Fall back to what the repository
      // itself has checked out — Loop 50's answer, and a local question with a
      // local answer rather than a network call per row.
      final base = (await parent).branch;
      if (base == null || base == delivery.branch) return delivery;

      final changes = ref.read(changesServiceProvider);
      final aheadBehind = await _orNull(
        () => changes.aheadBehind(key.worktree, base: base),
      );
      final lines = await _orNull(
        () => changes.diffStat(key.worktree, base: base),
      );
      return delivery.copyWith(
        baseBranch: base,
        aheadOfBase: aheadBehind?.ahead,
        behindBase: aheadBehind?.behind,
        lines: lines,
      );
    });

/// The pull request for a checkout's branch, and its checks.
///
/// The **remote** half, and the only part that costs network. Polled on
/// [deliveryPollProvider] rather than on every rebuild, keyed by checkout so
/// sessions sharing a working tree share one `gh` call, and `autoDispose` so a
/// row nobody is looking at costs nothing at all.
///
/// A failure is null, the same as "this branch has no pull request". The stage
/// machine reads null as "no PR" and falls back to local facts, which is the
/// safe direction: the app never claims a pull request exists.
final checkoutPullRequestProvider = FutureProvider.autoDispose
    .family<PullRequestSnapshot?, Checkout>((ref, checkout) async {
      ref.watch(deliveryPollProvider);
      final local = await ref.watch(checkoutDeliveryProvider(checkout).future);
      final branch = local.branch;
      if (branch == null || local.hasRemote != true) return null;
      return _orNull(
        () => ref
            .read(gitHubReviewServiceProvider)
            .pullRequestFor(checkout.path, branch: branch),
      );
    });

/// Everything one session's row and strip need: the local git facts of the
/// place it works, its pull request, and what the database knows.
///
/// This is the provider the Explorer's rows and the session view both read.
final sessionDeliveryProvider = FutureProvider.autoDispose
    .family<SessionDelivery, String>((ref, sessionId) async {
      ref.watch(sessionsRevisionProvider);
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      if (session == null) return SessionDelivery.unknown;
      final repository = ref
          .read(repositoryDaoProvider)
          .getById(session.repositoryId);
      if (repository == null) return SessionDelivery.unknown;

      final worktree = session.worktree;
      final directory = worktree ?? repository.path;
      final local = worktree == null
          ? ref.watch(
              checkoutDeliveryProvider(Checkout(repository.path)).future,
            )
          : ref.watch(
              worktreeDeliveryProvider((
                repo: repository.path,
                worktree: worktree,
              )).future,
            );
      final pullRequest = ref.watch(
        checkoutPullRequestProvider(Checkout(directory)).future,
      );

      final delivery = await local;
      return delivery.copyWith(
        pullRequest: await pullRequest,
        hasWorktree: worktree != null,
        agentRunning:
            ref.read(sessionLauncherProvider).livePaneFor(sessionId) != null,
        archived: session.isArchived,
      );
    });

/// A repository's delivery state — what an imported session's row shows, since
/// an imported conversation has no checkout of its own.
final repositoryDeliveryProvider = FutureProvider.autoDispose
    .family<SessionDelivery, String>((ref, repositoryId) async {
      final repository = ref.read(repositoryDaoProvider).getById(repositoryId);
      if (repository == null) return SessionDelivery.unknown;
      return ref.watch(
        checkoutDeliveryProvider(Checkout(repository.path)).future,
      );
    });

/// Where a repository's `origin` points, as a page. What turns a commit sha in
/// a list into a link.
final repositoryRemoteProvider = Provider.autoDispose
    .family<RemoteRepo?, String>((ref, repositoryId) {
      final repository = ref.read(repositoryDaoProvider).getById(repositoryId);
      if (repository == null) return null;
      return ref
          .watch(checkoutDeliveryProvider(Checkout(repository.path)))
          .asData
          ?.value
          .remote;
    });

/// The actions the strip should draw for a session, primary first.
///
/// `asData?.value` folds "still loading" and "the probe threw" into the same
/// null the domain reads as "could not tell" — deliberately, so a slow git or a
/// missing `gh` never withholds an action.
final sessionDeliveryActionsProvider = Provider.autoDispose
    .family<List<OfferedAction>, String>(
      (ref, sessionId) => deliveryActionsFor(
        ref.watch(sessionDeliveryProvider(sessionId)).asData?.value,
      ),
    );

/// `origin/main` → `main`. What `gh repo view` would call the default branch,
/// without asking it.
String? _branchOf(String? remoteRef) {
  if (remoteRef == null) return null;
  final slash = remoteRef.indexOf('/');
  return slash < 0 ? remoteRef : remoteRef.substring(slash + 1);
}

/// Runs [probe], turning any failure into null ("could not tell").
Future<T?> _orNull<T>(Future<T?> Function() probe) async {
  try {
    return await probe();
  } catch (_) {
    return null;
  }
}
