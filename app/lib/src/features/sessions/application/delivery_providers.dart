import '../../workspaces/data/workspace_data.dart';
import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import '../../git/application/changes_providers.dart';
import '../../git/application/checkout_probe_queue.dart';
import 'package:karmashala_git/git.dart';
import '../../github/application/github_providers.dart';
import 'package:karmashala_git/github.dart';
import '../../../core/util/clock_provider.dart';
import '../../notifications/application/delivery_attention.dart';
import '../../notifications/application/notification_providers.dart';
import '../../repositories/application/repository_identity_recorder.dart';
import 'package:karmashala_session/delivery.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// How often the pull request and its checks are re-read while the app is in
/// front — two minutes, because each answer is a `gh` process. Zero for tests.
final deliveryPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(minutes: 2),
);

/// The shortest gap between two **focus-driven** re-reads: ten alt-tabs inside
/// one second cost ten `gh` processes and ten git passes.
const Duration kDeliveryFocusRefreshInterval = Duration(seconds: 30);

/// Ticks when the remote half of delivery state should be re-read: one timer
/// for the whole app, stopped while unfocused and rate-limited on regain.
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

/// What a clone records about `origin`, once per repository — asking it per
/// checkout made a dozen worktrees answer the same two questions 13 times.
final repositoryOriginProvider = FutureProvider.autoDispose
    .family<RepositoryOrigin, Checkout>((ref, repository) async {
      // Read before the first await, like every other seam in this file.
      final changes = ref.read(changesServiceProvider);
      final workspace = ref.read(workspaceDataProvider);
      final probe = _probeOn(ref);
      final facts =
          await probe(() => changes.originFacts(repository.path)) ??
          RepositoryOrigin.none;
      // The one place a repository's `origin` is learned, so the one place its
      // canonical identity can be refreshed without a sweep of its own.
      recordRepositoryIdentity(workspace, repository.path, facts);
      return facts;
    });

/// The **local** half of a checkout's delivery state, keyed by the checkout and
/// not the session. Never throws, and no git of its own runs inside the frame.
final checkoutDeliveryProvider = FutureProvider.autoDispose
    .family<SessionDelivery, Checkout>((ref, checkout) async {
      // The working tree moves when an agent starts or stops and when the
      // workspace changes — never because a row was renamed or a mode was set.
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.status,
        SessionChangeKind.workspace,
      });
      final changes = ref.read(changesServiceProvider);
      // Read before the first await, like every other seam in this file.
      final probe = _probeOn(ref);
      final dir = checkout.path;
      // Wrapped in [_orNull] at the watch, not the await: the line below may
      // return without awaiting it, and an errored future nobody awaits throws.
      final origin = _orNull(
        () => ref.watch(
          repositoryOriginProvider(checkout.forRepository()).future,
        ),
      );

      final status = await probe(() => changes.statusWithBranch(dir));
      if (status == null) return SessionDelivery.unknown;

      final facts = await origin ?? RepositoryOrigin.none;
      final base = facts.head;

      // Both against the same base and started together: `diff --numstat` used
      // to wait for `rev-list`, and every reader of this paid the wasted half.
      final (aheadBehind, lines) = await (
        base == null
            ? Future<AheadBehind?>.value()
            : probe(() => changes.aheadBehind(dir, base: base)),
        probe(() => changes.diffStat(dir, base: base)),
      ).wait;

      final delivery = SessionDelivery(
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
      if (ref.mounted) {
        ref.read(checkoutReadingsProvider.notifier).arrived(checkout);
      }
      return delivery;
    });

/// How many readings of each checkout have arrived. A reader that only
/// *borrows* warm readings — `ref.exists`, never `ref.watch`, which would run
/// git for it — cannot be told by `exists` that one has become warm; selecting
/// its own checkout's count out of this tells it.
class CheckoutReadings extends Notifier<Map<Checkout, int>> {
  @override
  Map<Checkout, int> build() => const {};

  void arrived(Checkout checkout) =>
      state = {...state, checkout: (state[checkout] ?? 0) + 1};
}

final checkoutReadingsProvider =
    NotifierProvider<CheckoutReadings, Map<Checkout, int>>(
      CheckoutReadings.new,
    );

/// A worktree's delivery state, measured against the repository it came from
/// when no default branch is recorded locally. Shared by its sessions.
final worktreeDeliveryProvider = FutureProvider.autoDispose
    .family<
      SessionDelivery,
      ({EnvironmentPath repo, EnvironmentPath worktree})
    >((ref, key) async {
      // Both watches before the first await: `ref.watch` after one is a
      // documented Riverpod hazard, and together the two gits run concurrently.
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

/// The pull request for a checkout's branch, and its checks — the only part
/// that costs network. A failure is null, the same as "no pull request".
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

/// The repository's merge settings and open review threads — the second `gh`
/// process, watched by the strip alone. A failure is [kUnknownForgePolicy].
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

/// What the base branch's protection requires — the third `gh` process, and it
/// spawns nothing unless this tick's pull request already said `BLOCKED`.
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

/// The **local** delivery state of the place one session works. No `gh`: the
/// Explorer draws one per visible row, a price a tree could not otherwise pay.
final sessionLocalDeliveryProvider = FutureProvider.autoDispose
    .family<SessionDelivery, String>((ref, sessionId) async {
      // One of these per drawn row. Only this session's own row decides what it
      // says; the git behind it is [checkoutDeliveryProvider]'s to invalidate.
      ref.watchSession(sessionId);
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      if (session == null) return SessionDelivery.unknown;
      final repository = ref
          .read(workspaceDataProvider)
          .repository(session.repositoryId);
      if (repository == null) return SessionDelivery.unknown;

      final worktree = session.worktree;
      if (session.isArchived) {
        // The directory is gone: asking git would cost two failed processes per
        // archived row, and might describe one someone else created there.
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

/// Everything one session's strip needs: the local reading plus the pull
/// request. The Explorer's rows read the local one, so a project opens no `gh`.
final sessionDeliveryProvider = FutureProvider.autoDispose
    .family<SessionDelivery, String>((ref, sessionId) async {
      // Every watch before the first await, and the local half started before
      // the pull request so the two run together rather than in series.
      final local = ref.watch(sessionLocalDeliveryProvider(sessionId).future);
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      final repository = session == null
          ? null
          : ref.read(workspaceDataProvider).repository(session.repositoryId);
      // Nothing to ask `gh` about and nothing to file; the local provider has
      // already made the same three decisions.
      if (session == null || repository == null || session.isArchived) {
        return await local;
      }
      final directory = session.worktree ?? repository.path;
      final pullRequest = ref.watch(
        checkoutPullRequestProvider(Checkout(directory)).future,
      );
      // Watched before the first await: the policy provider already chains off
      // the pull request one, so starting it now costs nothing extra.
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

      // Filed from readings the row already paid for. Deferred, because
      // Riverpod forbids writing to another provider while one is building.
      unawaited(
        Future<void>.microtask(() {
          try {
            ref
                .read(deliveryAttentionProvider.notifier)
                .observe(sessionId, delivery);
          } catch (_) {}
        }),
      );
      return delivery;
    });

/// A repository's delivery state — what an imported session's row shows, since
/// an imported conversation has no checkout of its own.
final repositoryDeliveryProvider = FutureProvider.autoDispose
    .family<SessionDelivery, String>((ref, repositoryId) async {
      final repository = ref
          .read(workspaceDataProvider)
          .repository(repositoryId);
      if (repository == null) return SessionDelivery.unknown;
      return ref.watch(
        checkoutDeliveryProvider(Checkout(repository.path)).future,
      );
    });

/// Where a repository's `origin` points, as a page. What turns a commit sha in
/// a list into a link.
final repositoryRemoteProvider = Provider.autoDispose
    .family<RemoteRepo?, String>((ref, repositoryId) {
      final repository = ref
          .read(workspaceDataProvider)
          .repository(repositoryId);
      if (repository == null) return null;
      // `.value` rather than `.asData?.value`: a link should not disappear
      // because the delivery state behind it is being refreshed.
      return ref
          .watch(checkoutDeliveryProvider(Checkout(repository.path)))
          .value
          ?.remote;
    });

/// The actions the strip should draw, primary first. Reads `.value`, so a
/// refresh keeps the previous answer instead of blinking on every focus.
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

/// Starts a git subprocess on the shared checkout queue, never throwing. Not
/// applied to the `gh` providers: a network trip would starve local probes.
Future<T?> Function<T>(Future<T?> Function()) _probeOn(Ref ref) {
  final queue = ref.read(checkoutProbeQueueProvider);
  return <T>(run) => queue.run(() => _orNull(run));
}
