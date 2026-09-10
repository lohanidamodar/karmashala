import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import '../../explorer/application/checkout.dart';
import '../../git/application/changes_providers.dart';
import '../../git/application/checkout_probe_queue.dart';
import 'package:karmashala_git/git.dart';
import '../../github/application/github_providers.dart';
import '../../github/data/github_service.dart';
import 'package:karmashala_git/github.dart';
import '../../../core/util/clock_provider.dart';
import '../../notifications/application/delivery_attention.dart';
import '../../notifications/application/notification_providers.dart';
import '../../repositories/application/repository_identity_recorder.dart';
import '../../repositories/application/repository_providers.dart';
import '../domain/delivery_action.dart';
import '../domain/session_delivery.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// How often the pull request and its checks are re-read while the app is in
/// front, or [Duration.zero] for never — two minutes, because the answer costs
/// a `gh` process per checkout and nothing downstream is time-critical. Zero is
/// for the widget tests, where a real periodic timer outlives the widget tree
/// and trips `flutter_test`'s pending-timer check.
final deliveryPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(minutes: 2),
);

/// The shortest gap between two **focus-driven** re-reads. Focus is not a rare
/// event — a tiling window manager crosses it dozens of times a minute, and ten
/// alt-tabs inside one second cost ten `gh` processes and ten git passes.
const Duration kDeliveryFocusRefreshInterval = Duration(seconds: 30);

/// Ticks when the remote half of delivery state should be re-read. **One timer
/// for the whole app**: every row shares a tick, and their `gh` calls are
/// already deduplicated by [checkoutPullRequestProvider]'s checkout key. It
/// does not tick while the window is unfocused and bumps when focus comes back,
/// rate-limited to [kDeliveryFocusRefreshInterval].
class DeliveryPollController extends Notifier<int> {
  Timer? _timer;

  /// When the last re-read was asked for, from whichever source; mounting
  /// counts.
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

/// What a clone records about `origin`, **once per repository** rather than
/// once per working tree: both facts live in the clone's git directory, so
/// asking per checkout made a repository with a dozen `wt-*` folders answer the
/// same two questions thirteen times a pass. [Checkout] carries the repository
/// so the family key is known *before* the first await, which is what folds
/// every worktree's ask onto one entry. Nothing invalidates the cache,
/// deliberately: a `git remote set-url` or a fetch that moves `origin/HEAD` is
/// not noticed.
final repositoryOriginProvider = FutureProvider.autoDispose
    .family<RepositoryOrigin, Checkout>((ref, repository) async {
      // Read before the first await, like every other seam in this file.
      final changes = ref.read(changesServiceProvider);
      final repositories = ref.read(repositoryDaoProvider);
      final probe = _probeOn(ref);
      final facts =
          await probe(() => changes.originFacts(repository.path)) ??
          RepositoryOrigin.none;
      // The one place a repository's `origin` is learned, so the one place its
      // canonical identity can be refreshed without a sweep of its own.
      recordRepositoryIdentity(repositories, repository.path, facts);
      return facts;
    });

/// The **local** half of a checkout's delivery state: branch, upstream, dirty
/// files, `+N −M`, and how far it stands from its base. No network, no `gh`.
/// Keyed by the checkout and not the session, because twenty sessions in a
/// repository with no worktrees describe *one* working tree. Every process goes
/// through [checkoutProbeQueueProvider] and then the worker isolate, so none
/// starts in the frame that asked: a row paints with no branch chip and fills
/// in once the window is up. Never throws — a folder that is not a repository
/// is a row with nothing to say.
final checkoutDeliveryProvider = FutureProvider.autoDispose
    .family<SessionDelivery, Checkout>((ref, checkout) async {
      // The working tree can move when an agent starts or stops and when the
      // workspace itself changes; it cannot move because a row was renamed or a
      // permission mode was set, and paying five processes per checkout for
      // either was the bill `checkout_scale_cost_test.dart` was written for.
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.status,
        SessionChangeKind.workspace,
      });
      final changes = ref.read(changesServiceProvider);
      // Read before the first await, like every other seam in this file.
      final probe = _probeOn(ref);
      final dir = checkout.path;
      // Watched before the first await and awaited below, so the repository's
      // two questions overlap this checkout's `status` instead of queueing
      // behind it. Wrapped in [_orNull] **at the watch**, not at the await: the
      // line below may return without awaiting it, and an errored future nobody
      // awaits is an unhandled async error.
      final origin = _orNull(
        () => ref
            .watch(repositoryOriginProvider(checkout.forRepository()).future),
      );

      final status = await probe(() => changes.statusWithBranch(dir));
      if (status == null) return SessionDelivery.unknown;

      final facts = await origin ?? RepositoryOrigin.none;
      final base = facts.head;

      // Both against the same base and started together: two processes that do
      // not need each other's answer. `diff --numstat` used to wait for
      // `rev-list`, and every reader of this provider paid the wasted half.
      final (aheadBehind, lines) = await (
        base == null
            ? Future<AheadBehind?>.value()
            : probe(() => changes.aheadBehind(dir, base: base)),
        probe(() => changes.diffStat(dir, base: base)),
      ).wait;

      return SessionDelivery(
        branch: status.branch,
        baseBranch: base,
        upstream: status.upstream,
        hasRemote: facts.hasRemote,
        remote: RemoteRepo.parse(facts.url),
        defaultBranch: facts.defaultBranch,
        dirtyFiles: status.changes.length,
        lines: lines,
        aheadOfBase: aheadBehind?.ahead,
        behindBase: aheadBehind?.behind,
        unpushed: status.aheadOfUpstream,
      );
    });

/// A worktree's delivery state, measured against the repository it came from
/// when the remote's default branch is not recorded locally. Shared by every
/// session inside one worktree.
final worktreeDeliveryProvider = FutureProvider.autoDispose
    .family<
      SessionDelivery,
      ({EnvironmentPath repo, EnvironmentPath worktree})
    >((ref, key) async {
      // Both watches are taken before the first await: `ref.watch` after an
      // await is a documented Riverpod hazard, and taking them together runs
      // the two checkouts' git concurrently. The worktree is named **with the
      // repository it came from**, which is how [repositoryOriginProvider]
      // folds every worktree of one clone onto one entry.
      final own = ref.watch(
        checkoutDeliveryProvider(
          Checkout(key.worktree, repository: key.repo),
        ).future,
      );
      final parent = ref.watch(
        checkoutDeliveryProvider(Checkout(key.repo)).future,
      );
      final probe = _probeOn(ref);
      final delivery = await own;
      if (delivery.baseBranch != null) return delivery;

      // No `origin/HEAD` to measure against: fall back to what the repository
      // itself has checked out — a local question with a local answer.
      final base = (await parent).branch;
      if (base == null || base == delivery.branch) return delivery;

      final changes = ref.read(changesServiceProvider);
      final aheadBehind = await probe(
        () => changes.aheadBehind(key.worktree, base: base),
      );
      final lines = await probe(
        () => changes.diffStat(key.worktree, base: base),
      );
      return delivery.copyWith(
        baseBranch: base,
        aheadOfBase: aheadBehind?.ahead,
        behindBase: aheadBehind?.behind,
        lines: lines,
      );
    });

/// The pull request for a checkout's branch, and its checks — the **remote**
/// half, and the only part that costs network. Polled on [deliveryPollProvider]
/// and keyed by checkout, so sessions sharing a working tree share one `gh`
/// call. A failure is null, the same as "no pull request": the app never claims
/// one exists.
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

/// The repository's merge settings and the open review conversations on its
/// pull request, for one checkout — **the second `gh` process**, watched by
/// [sessionDeliveryProvider] alone and never by the per-row
/// [sessionLocalDeliveryProvider], which would make twenty rows twenty GraphQL
/// queries. It short-circuits when there is no open pull request, and chains
/// off [checkoutPullRequestProvider] so it queries the number the strip is
/// showing. A failure is [kUnknownForgePolicy] — "offer what you would have
/// anyway".
final checkoutForgePolicyProvider = FutureProvider.autoDispose
    .family<ForgePolicy, Checkout>((ref, checkout) async {
      final pr = await ref.watch(checkoutPullRequestProvider(checkout).future);
      if (pr == null || !pr.isOpen) return kUnknownForgePolicy;
      return await _orNull(
            () => ref
                .read(gitHubReviewServiceProvider)
                .forgePolicyFor(checkout.path, number: pr.number),
          ) ??
          kUnknownForgePolicy;
    });

/// What the base branch's protection requires — the sentence behind a disabled
/// `Merge` that GitHub would only call `BLOCKED`. **The third `gh` process**,
/// and it spawns nothing unless the pull request this tick already read says
/// `BLOCKED`. A failure is [BranchProtection.unknown], never an error:
/// downstream reads that as "keep the sentence you had".
final checkoutMergeProtectionProvider = FutureProvider.autoDispose
    .family<BranchProtection, Checkout>((ref, checkout) async {
      final pr = await ref.watch(checkoutPullRequestProvider(checkout).future);
      if (pr == null || !pr.isOpen) return BranchProtection.unknown;
      // The one state this call can explain. Every other one already has a
      // sentence that does not need a process.
      if (pr.mergeStateStatus != MergeStateStatus.blocked) {
        return BranchProtection.unknown;
      }
      final base = pr.baseRefName;
      if (base == null) return BranchProtection.unknown;
      return await _orNull(
            () => ref
                .read(gitHubReviewServiceProvider)
                .branchProtectionFor(checkout.path, branch: base),
          ) ??
          BranchProtection.unknown;
    });

/// The **local** delivery state of the place one session works: its branch, its
/// change count, `+N −M`, and how far it stands from its base. No `gh` — the
/// Explorer draws one of these per visible row, and a `gh` process per checkout
/// is a price a tree cannot pay; the strip, which exists for one session, can.
final sessionLocalDeliveryProvider = FutureProvider.autoDispose
    .family<SessionDelivery, String>((ref, sessionId) async {
      // One of these per drawn row. Only this session's own row decides what it
      // says; the git behind it is [checkoutDeliveryProvider]'s to invalidate.
      ref.watchSession(sessionId);
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      if (session == null) return SessionDelivery.unknown;
      final repository = ref
          .read(repositoryDaoProvider)
          .getById(session.repositoryId);
      if (repository == null) return SessionDelivery.unknown;

      final worktree = session.worktree;
      if (session.isArchived) {
        // The directory this session worked in is gone. Asking git would cost
        // two failed processes per archived row on every workspace change, and
        // could one day describe a directory someone else created at that path.
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
/// the pull request, whether an agent is live, and the attention it files. The
/// Explorer's rows read the local provider, so opening a project starts no
/// `gh`.
final sessionDeliveryProvider = FutureProvider.autoDispose
    .family<SessionDelivery, String>((ref, sessionId) async {
      // Every watch before the first await, and the local half started before
      // the pull request so the two run together rather than in series.
      final local = ref.watch(sessionLocalDeliveryProvider(sessionId).future);
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      final repository = session == null
          ? null
          : ref.read(repositoryDaoProvider).getById(session.repositoryId);
      // Nothing to ask `gh` about and nothing to file; the local provider has
      // already made the same three decisions.
      if (session == null || repository == null || session.isArchived) {
        return await local;
      }
      final directory = session.worktree ?? repository.path;
      final pullRequest = ref.watch(
        checkoutPullRequestProvider(Checkout(directory)).future,
      );
      // Watched here, before the first await: the policy provider already
      // chains off the pull request one, so starting it now costs nothing
      // extra.
      final policy = ref.watch(
        checkoutForgePolicyProvider(Checkout(directory)).future,
      );
      // Same shape, same reason: it chains off the pull request too, so
      // starting it here overlaps rather than serialises.
      final protection = ref.watch(
        checkoutMergeProtectionProvider(Checkout(directory)).future,
      );

      final snapshot = await pullRequest;
      final forge = await policy;
      final delivery = (await local).copyWith(
        pullRequest: snapshot?.withUnresolvedReviewThreads(
          forge.unresolvedReviewThreads,
        ),
        mergeStrategies: forge.strategies,
        branchProtection: await protection,
        agentRunning:
            ref.read(sessionLauncherProvider).livePaneFor(sessionId) != null,
      );

      // Filed from the readings a row already paid for, so nothing polls `gh`
      // twice. Deferred out of this build because Riverpod forbids writing to
      // another provider while one is building — and by the time the microtask
      // runs this provider may have been disposed, which is not an error.
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
      // `.value` rather than `.asData?.value`: a link should not disappear
      // because the delivery state behind it is being refreshed.
      return ref
          .watch(checkoutDeliveryProvider(Checkout(repository.path)))
          .value
          ?.remote;
    });

/// The actions the strip should draw for a session, primary first. Reads
/// `.value`, not `asData?.value`, so a refresh keeps the **previous** answer —
/// reading an `AsyncLoading` as null is what made the strip blink on every
/// window focus.
final sessionDeliveryActionsProvider = Provider.autoDispose
    .family<List<OfferedAction>, String>(
      (ref, sessionId) => deliveryActionsFor(
        ref.watch(sessionDeliveryProvider(sessionId)).value,
      ),
    );

/// Runs [probe], turning any failure into null ("could not tell").
Future<T?> _orNull<T>(Future<T?> Function() probe) async {
  try {
    return await probe();
  } catch (_) {
    return null;
  }
}

/// How this file starts a git subprocess: on the shared checkout queue, and
/// never throwing. Taken as a closure **before** the first await, because a
/// `ref.read` after one may reach into a provider that has been disposed.
/// Deliberately not applied to the two `gh` providers — a network round trip
/// holding a slot in a queue sized for local processes would starve every
/// visible row's branch chip behind it.
Future<T?> Function<T>(Future<T?> Function()) _probeOn(Ref ref) {
  final queue = ref.read(checkoutProbeQueueProvider);
  return <T>(run) => queue.run(() => _orNull(run));
}
