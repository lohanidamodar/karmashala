import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../environments/domain/environment_path.dart';
import '../../explorer/application/checkout.dart';
import '../../git/application/changes_providers.dart';
import '../../git/domain/remote_repo.dart';
import '../../github/application/github_providers.dart';
import '../../github/domain/pull_request_snapshot.dart';
import '../../../core/util/clock_provider.dart';
import '../../notifications/application/delivery_attention.dart';
import '../../notifications/application/notification_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../domain/delivery_action.dart';
import '../domain/session_delivery.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_ui_providers.dart';

/// How often the pull request and its checks are re-read while the app is in
/// front, or [Duration.zero] for never.
///
/// Two minutes because the answer costs a `gh` process per checkout and nothing
/// downstream is time-critical: a check that went red is worth knowing about
/// within a couple of minutes, not within a second.
///
/// Zero exists for the widget tests: a real periodic timer outlives the widget
/// tree and trips `flutter_test`'s pending-timer check, which is the same
/// reason `scrollbackAutosaveFactoryProvider` is overridable. Tests turn it off
/// through `fakeTerminalOverrides`; nothing in the app ever sets it.
final deliveryPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(minutes: 2),
);

/// The shortest gap between two **focus-driven** re-reads.
///
/// Focus is not a rare event. A tiling window manager crosses it dozens of
/// times a minute, and the owner reported the app flickering as they moved
/// between GlazeWM workspaces; measured, ten alt-tabs inside one second cost
/// ten `gh` processes and ten git passes, because every regain bumped the
/// revision. Thirty seconds keeps the behaviour that matters — come back to
/// the app and it shows current state rather than what it knew before lunch —
/// while an alt-tab storm costs one refresh instead of one per tab.
const Duration kDeliveryFocusRefreshInterval = Duration(seconds: 30);

/// Ticks when the remote half of delivery state should be re-read.
///
/// **One timer for the whole app**, not one per session: twenty rows watching
/// this share a tick, and each of their `gh` calls is already deduplicated by
/// [checkoutPullRequestProvider]'s checkout key.
///
/// It does not tick while the window is unfocused — nobody is reading — and
/// bumps when focus comes back, so returning to the app shows current state
/// without having polled through lunch. That regain is rate-limited to
/// [kDeliveryFocusRefreshInterval]: a read that just happened is not worth
/// repeating because the window blinked.
class DeliveryPollController extends Notifier<int> {
  Timer? _timer;

  /// When the last re-read was asked for, from whichever source. Mounting
  /// counts: the providers below read as soon as they are first watched.
  DateTime? _lastAsked;

  @override
  int build() {
    final interval = ref.watch(deliveryPollIntervalProvider);
    final clock = ref.watch(clockProvider);
    _timer?.cancel();
    _timer = interval <= Duration.zero
        ? null
        : Timer.periodic(interval, (_) {
            if (ref.read(windowFocusedProvider)) _ask(clock.nowUtc());
          });
    ref.onDispose(() => _timer?.cancel());
    ref.listen(windowFocusedProvider, (previous, next) {
      if (!next || previous != false) return;
      final now = clock.nowUtc();
      final last = _lastAsked;
      if (last != null &&
          now.difference(last) < kDeliveryFocusRefreshInterval) {
        return;
      }
      _ask(now);
    });
    _lastAsked = clock.nowUtc();
    return 0;
  }

  void _ask(DateTime now) {
    _lastAsked = now;
    state++;
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

/// The **local** delivery state of the place one session works: its branch, its
/// change count, `+N −M`, and how far it stands from its base. No `gh`.
///
/// Split out of [sessionDeliveryProvider] because the Explorer draws one of
/// these per visible row. The full provider adds the pull request, and a `gh`
/// process per checkout is a price a tree cannot pay; a strip, which exists for
/// one session at a time, can.
final sessionLocalDeliveryProvider = FutureProvider.autoDispose
    .family<SessionDelivery, String>((ref, sessionId) async {
      ref.watch(sessionsRevisionProvider);
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      if (session == null) return SessionDelivery.unknown;
      final repository = ref
          .read(repositoryDaoProvider)
          .getById(session.repositoryId);
      if (repository == null) return SessionDelivery.unknown;

      final worktree = session.worktree;
      if (session.isArchived) {
        // The directory this session worked in is gone. Asking git about it
        // would cost two failed processes per archived row on every workspace
        // change, and could one day describe a directory someone else created
        // at the same path.
        return SessionDelivery(hasWorktree: worktree != null, archived: true);
      }
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
      return (await local).copyWith(hasWorktree: worktree != null);
    });

/// Everything one session's strip needs: [sessionLocalDeliveryProvider] plus
/// the pull request, whether an agent is live, and the attention it files.
///
/// This is what the session view reads. The Explorer's rows read the local
/// provider above, so opening a project never starts a `gh` per row.
final sessionDeliveryProvider = FutureProvider.autoDispose
    .family<SessionDelivery, String>((ref, sessionId) async {
      // Every watch before the first await, and the local half started before
      // the pull request so the two run together rather than in series.
      final local = ref.watch(sessionLocalDeliveryProvider(sessionId).future);
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      final repository = session == null
          ? null
          : ref.read(repositoryDaoProvider).getById(session.repositoryId);
      // Nothing to ask `gh` about and nothing to file: no session, no
      // repository, or a session whose directory has been archived away. The
      // local provider has already made the same three decisions.
      if (session == null || repository == null || session.isArchived) {
        return await local;
      }
      final directory = session.worktree ?? repository.path;
      final pullRequest = ref.watch(
        checkoutPullRequestProvider(Checkout(directory)).future,
      );

      final delivery = (await local).copyWith(
        pullRequest: await pullRequest,
        agentRunning:
            ref.read(sessionLauncherProvider).livePaneFor(sessionId) != null,
      );

      // Attention is filed from the readings a row already paid for, so nothing
      // polls `gh` twice. Deferred out of this build: the inbox is another
      // provider's state and Riverpod forbids writing to one while a provider
      // is building — and by the time the microtask runs, this provider may
      // have been disposed, which is not an error.
      Future<void>.microtask(() {
        try {
          ref
              .read(deliveryAttentionProvider.notifier)
              .observe(sessionId, delivery);
        } catch (_) {}
      });
      return delivery;
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
      // `.value` rather than `.asData?.value`, for the same reason as
      // [sessionDeliveryActionsProvider]: a link should not disappear because
      // the delivery state behind it is being refreshed.
      return ref
          .watch(checkoutDeliveryProvider(Checkout(repository.path)))
          .value
          ?.remote;
    });

/// The actions the strip should draw for a session, primary first.
///
/// `AsyncValue.value` folds "still loading" and "the probe threw" into the same
/// null the domain reads as "could not tell" — deliberately, so a slow git or a
/// missing `gh` never withholds an action — but keeps the **previous** answer
/// through a refresh. `asData?.value` did not, and that is what made the strip
/// blink on every window focus: a refresh is an `AsyncLoading` carrying the
/// value it already had, and reading it as null redrew the row as though the
/// app had never known anything.
final sessionDeliveryActionsProvider = Provider.autoDispose
    .family<List<OfferedAction>, String>(
      (ref, sessionId) =>
          deliveryActionsFor(ref.watch(sessionDeliveryProvider(sessionId)).value),
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
