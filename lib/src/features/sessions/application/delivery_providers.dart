import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../environments/domain/environment_path.dart';
import '../../explorer/application/checkout.dart';
import '../../git/application/changes_providers.dart';
import '../../git/application/checkout_probe_queue.dart';
import '../../git/domain/diff_stat.dart';
import '../../git/domain/remote_repo.dart';
import '../../git/domain/repository_origin.dart';
import '../../github/application/github_providers.dart';
import '../../github/data/github_service.dart';
import '../../github/domain/pull_request_snapshot.dart';
import '../../../core/util/clock_provider.dart';
import '../../notifications/application/delivery_attention.dart';
import '../../notifications/application/notification_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../domain/delivery_action.dart';
import '../domain/session_delivery.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_signals.dart';

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

/// What a clone records about `origin`, **once per repository** rather than
/// once per working tree.
///
/// `origin`'s URL and `origin/HEAD` are properties of the repository: they
/// live in `.git/config` and `refs/remotes/origin/HEAD`, and a worktree's
/// `.git` is a file pointing at the clone's git directory, so every worktree of
/// one clone has the same answer. Asking them per *checkout* meant a
/// repository with a dozen `wt-*` folders answered the same two questions
/// thirteen times on every pass — measured, and asserted against, in
/// `checkout_scale_cost_test.dart`'s `worktrees of one repository` group.
///
/// **Keyed by the repository, and that is the whole point.** Every worktree
/// reading maps onto one entry through [Checkout.forRepository], so Riverpod
/// answers the second and subsequent asks from the first one's future. The key
/// has to be available *before* the first await for that to work, which is why
/// [Checkout] carries the repository rather than this provider discovering it:
/// `ref.watch` after an await is the hazard this file keeps naming, and a
/// repository discovered by reading `.git` could only be watched after one.
///
/// **It caches for its own lifetime and nothing invalidates it**, deliberately.
/// `autoDispose`, so it is collected once no row is watching — but while rows
/// are, a `git remote set-url` or a fetch that moves `origin/HEAD` is not
/// noticed. Both are rare, neither is watched today either, and the alternative
/// is a watcher on two files or a re-read trigger: machinery for a fact that
/// changes about once in the life of a clone.
/// **Two file reads and no subprocess**, in the ordinary case.
/// `ChangesService.originFacts` reads `remote.origin.url` out of `.git/config`
/// and `origin/HEAD` out of `refs/remotes/origin/HEAD`, and falls back to `git
/// remote get-url` / `git rev-parse` for whichever the files could not answer.
/// Still on the probe queue, because a fallback can spawn and because a read
/// across `\\wsl.localhost` is cheaper than a process rather than free.
final repositoryOriginProvider = FutureProvider.autoDispose
    .family<RepositoryOrigin, Checkout>((ref, repository) async {
      // Read before the first await, like every other seam in this file.
      final changes = ref.read(changesServiceProvider);
      final probe = _probeOn(ref);
      return await probe(() => changes.originFacts(repository.path)) ??
          RepositoryOrigin.none;
    });

/// The **local** half of a checkout's delivery state: branch, upstream, dirty
/// files, `+N −M`, and how far it stands from its base. No network, no `gh`.
///
/// Keyed by the checkout for the same reason Loop 50's `checkoutStatProvider`
/// is: twenty sessions in a repository with no worktrees are twenty rows
/// describing *one* working tree, and keying by session would run git twenty
/// times for one answer.
///
/// Costs **one to three processes of its own**: one `git status --porcelain=v1
/// --branch` (branch, upstream, divergence and the file list together) and —
/// when the repository has a default branch to measure against — a `rev-list`
/// and a `diff --numstat` against it. The other two, `remote get-url` and
/// `origin/HEAD`, are the repository's and are paid once for every worktree of
/// it by [repositoryOriginProvider]. Recomputed when the workspace mutates,
/// which is the signal the rest of the Explorer already rebuilds on.
///
/// **None of those processes starts in the frame that asked for them.** Every
/// one goes through [checkoutProbeQueueProvider], which waits for the frame to
/// finish first — see `checkout_probe_queue.dart` for why a `Process.run` is
/// charged to the frame that calls it. So a row paints with no branch chip and
/// no `+N −M`, and fills in once the window is up; `SessionDiffStat` already
/// reads a missing answer as "not measured", never as "no branch".
///
/// Never throws: a folder that is not a repository is a row with nothing to
/// say, not an error banner in a tree.
final checkoutDeliveryProvider = FutureProvider.autoDispose
    .family<SessionDelivery, Checkout>((ref, checkout) async {
      // One to three git subprocesses of its own, one instance per visible
      // checkout, plus the repository's two — paid once for every worktree of
      // it. The working tree can move when an agent starts or stops and when
      // the workspace itself changes; it cannot move because a row was renamed
      // or a permission mode was set, and paying five processes per checkout
      // for either was the bill `checkout_scale_cost_test.dart` was written
      // for.
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.status,
        SessionChangeKind.workspace,
      });
      final changes = ref.read(changesServiceProvider);
      // Read before the first await, like every other seam in this file.
      final probe = _probeOn(ref);
      final dir = checkout.path;
      // Watched before the first await, and awaited below: the repository's
      // two questions now overlap this checkout's `status` instead of queueing
      // behind it, so a row's own chain is three round trips deep rather than
      // four. And for the second and later worktrees of one clone there is
      // nothing to overlap — the answer is already there.
      //
      // Wrapped in [_orNull] **at the watch**, not at the await, because the
      // line below may return without awaiting it: a directory that is not a
      // repository has nothing to say and does not wait to be told what its
      // remote is. An errored future nobody awaits is an unhandled async
      // error; one that cannot error is safe to drop.
      final origin = _orNull(
        () => ref
            .watch(repositoryOriginProvider(checkout.forRepository()).future),
      );

      final status = await probe(() => changes.statusWithBranch(dir));
      if (status == null) return SessionDelivery.unknown;

      final facts = await origin ?? RepositoryOrigin.none;
      final base = facts.head;

      // Both against the same base, and started together: they are two
      // processes that do not need each other's answer.
      //
      // The comment said so from the day the line was written and the code did
      // not — `git diff --numstat` was not even started until `git rev-list`
      // had answered. This provider is the single producer of every checkout's
      // local git facts, read by every Explorer row, the delivery strip and
      // `delivery_status`, and recomputed on every workspace change, so the
      // wasted half was paid on all of them.
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
      //
      // The worktree is named **with the repository it came from**, which is
      // the one thing git would have to be asked for and the workspace already
      // knows: it is how [repositoryOriginProvider] folds every worktree of one
      // clone onto one entry. See [Checkout.repository] for why naming it does
      // not split the family key.
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

      // No `origin/HEAD` to measure against. Fall back to what the repository
      // itself has checked out — Loop 50's answer, and a local question with a
      // local answer rather than a network call per row.
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

/// The repository's merge settings and the open review conversations on its
/// pull request, for one checkout.
///
/// **The second `gh` process, and the only one in this file that is not paid by
/// every visible row.** It is watched by [sessionDeliveryProvider] alone — the
/// strip, which exists for one session at a time — and never by
/// [sessionLocalDeliveryProvider], which the Explorer draws per row. Twenty
/// rows in a repository would otherwise be twenty GraphQL queries for facts
/// nineteen of them do not draw.
///
/// It short-circuits before the process whenever there is no open pull request
/// to ask about, so a session that has not proposed anything yet costs nothing,
/// and it chains off [checkoutPullRequestProvider] rather than re-reading the
/// branch: the number it queries has to be the number the strip is showing.
///
/// A failure is [kUnknownForgePolicy], not an error. Everything downstream of
/// it treats "could not tell" as "offer what you would have offered anyway",
/// so a repository whose settings the token cannot read behaves exactly as it
/// did before this provider existed.
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

/// The **local** delivery state of the place one session works: its branch, its
/// change count, `+N −M`, and how far it stands from its base. No `gh`.
///
/// Split out of [sessionDeliveryProvider] because the Explorer draws one of
/// these per visible row. The full provider adds the pull request, and a `gh`
/// process per checkout is a price a tree cannot pay; a strip, which exists for
/// one session at a time, can.
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
      // Watched here, before the first await, and awaited below: the policy
      // provider already chains off the pull request one, so starting it now
      // costs nothing extra and its process overlaps the local git.
      final policy = ref.watch(
        checkoutForgePolicyProvider(Checkout(directory)).future,
      );

      final snapshot = await pullRequest;
      final forge = await policy;
      final delivery = (await local).copyWith(
        pullRequest: snapshot?.withUnresolvedReviewThreads(
          forge.unresolvedReviewThreads,
        ),
        mergeStrategies: forge.strategies,
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
/// never throwing.
///
/// Two policies in one call, because they are the same decision made twice —
/// *when* a row's git may run, and *what a row shows while it has not*. The
/// queue holds the first (see `checkout_probe_queue.dart`); [_orNull] holds the
/// second, and has since before the queue existed.
///
/// Returned as a closure taken **before** the first await, like every other
/// seam in this file: `ref.read` after an await is the hazard the comments
/// above keep naming, and a probe that read the queue late would be reaching
/// into a provider that may already have been disposed.
///
/// Deliberately not applied to the two `gh` providers in this file. A pull
/// request costs a network round trip, and letting one hold a slot in a queue
/// sized for local processes would starve every visible row's branch chip
/// behind it. They already chain off a local reading, so they are behind the
/// gate anyway.
Future<T?> Function<T>(Future<T?> Function()) _probeOn(Ref ref) {
  final queue = ref.read(checkoutProbeQueueProvider);
  return <T>(run) => queue.run(() => _orNull(run));
}
