import '../../workspaces/data/workspace_data.dart';
import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show ForgeReadingChanged, PullRequestReading;
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_git/git.dart' show RemoteRepo;
import 'package:karmashala_git/github.dart';
import '../../git/data/git_data.dart';
import '../../../core/data/data_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'observed_deliveries.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// The **local** half of a checkout's delivery state, keyed by the checkout
/// and not the session — read at the server, which measures a worktree
/// against the repository it came from. Read again when the server says the
/// checkout was touched (a write, a worktree, a turn ending there) or the
/// workspace moves; never throws.
final checkoutDeliveryProvider = FutureProvider.autoDispose
    .family<SessionDelivery, Checkout>((ref, checkout) async {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.workspace,
      });
      ref.watchCheckout(checkout.path);
      final git = ref.read(gitDataProvider);
      final delivery =
          await _orNull(
            () => git.delivery(checkout.path, repository: checkout.repository),
          ) ??
          SessionDelivery.unknown;
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

/// A worktree's delivery state, measured against the repository it came
/// from. Shared by its sessions.
final worktreeDeliveryProvider = FutureProvider.autoDispose
    .family<
      SessionDelivery,
      ({EnvironmentPath repo, EnvironmentPath worktree})
    >(
      (ref, key) => ref.watch(
        checkoutDeliveryProvider(
          Checkout(key.worktree, repository: key.repo),
        ).future,
      ),
    );

/// What the forge says about a checkout's branch — its pull request and
/// checks, the merge settings and review threads, the base's protection when
/// a merge is `BLOCKED` — as **the server's own delivery poll** last read it
/// (slice 5c: every two minutes and whenever a turn ends there, app or no
/// app). No timer here: a new reading arrives as `ForgeReadingChanged` and
/// this reads it again. Only a checkout the server has not read yet is asked
/// once (`github.pullRequest`), never polled. A failure is
/// [PullRequestReading.none].
final checkoutForgeProvider = FutureProvider.autoDispose
    .family<PullRequestReading, Checkout>((ref, checkout) async {
      final client = ref.watch(dataClientProvider);
      final path = checkout.path;
      final changes = client.attentionChanges.listen((change) {
        if (change is ForgeReadingChanged && change.checkout == path) {
          ref.invalidateSelf();
        }
      });
      ref.onDispose(changes.cancel);
      final told = client.forgeReadings[path];
      if (told != null) return told;
      final local = await ref.watch(checkoutDeliveryProvider(checkout).future);
      final branch = local.branch;
      if (branch == null || local.hasRemote != true) {
        return PullRequestReading.none;
      }
      return await _orNull(
            () => ref.read(gitDataProvider).pullRequest(path, branch: branch),
          ) ??
          PullRequestReading.none;
    });

/// The pull request for a checkout's branch, and its checks. Null is "no pull
/// request" and "could not tell" alike.
final checkoutPullRequestProvider = FutureProvider.autoDispose
    .family<PullRequestSnapshot?, Checkout>(
      (ref, checkout) async =>
          (await ref.watch(checkoutForgeProvider(checkout).future)).pullRequest,
    );

/// The **local** delivery state of the place one session works. No `gh`: the
/// Explorer draws one per visible row, a price a tree could not otherwise pay.
final sessionLocalDeliveryProvider = FutureProvider.autoDispose
    .family<SessionDelivery, String>((ref, sessionId) async {
      // One of these per drawn row. Only this session's own row decides what it
      // says; the git behind it is [checkoutDeliveryProvider]'s to invalidate.
      ref.watchSession(sessionId);
      final session = ref.read(sessionsDataProvider).getById(sessionId);
      if (session == null) return SessionDelivery.unknown;
      final repository = ref
          .read(workspaceDataProvider)
          .repository(session.repositoryId);
      if (repository == null) return SessionDelivery.unknown;

      final worktree = session.worktree;
      if (session.worktreeRemoved) {
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
      final session = ref.read(sessionsDataProvider).getById(sessionId);
      final repository = session == null
          ? null
          : ref.read(workspaceDataProvider).repository(session.repositoryId);
      // Nothing to ask `gh` about and nothing to file; the local provider has
      // already made the same three decisions.
      if (session == null || repository == null || session.worktreeRemoved) {
        return await local;
      }
      final directory = session.worktree ?? repository.path;
      final forge = await ref.watch(
        checkoutForgeProvider(Checkout(directory)).future,
      );
      final delivery = (await local).copyWith(
        pullRequest: forge.pullRequest,
        mergeStrategies: forge.strategies,
        branchProtection: forge.protection,
        agentRunning:
            ref.read(sessionLauncherProvider).livePaneFor(sessionId) != null,
      );

      // Kept for the Explorer's sections, which read what rows already paid
      // for. Deferred, because Riverpod forbids writing to another provider
      // while one is building. What is news is the server's to file.
      unawaited(
        Future<void>.microtask(() {
          try {
            ref
                .read(observedDeliveriesProvider.notifier)
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
