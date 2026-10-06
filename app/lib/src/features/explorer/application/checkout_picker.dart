import '../../workspaces/data/workspace_data.dart';
import 'package:agent_cli/process.dart';
import 'package:riverpod/riverpod.dart';

import '../../git/application/changes_providers.dart';
import '../../git/application/git_providers.dart';
import '../../git/data/git_data.dart';
import 'package:karmashala_git/git.dart';
import '../../projects/application/projects_controller.dart';
import 'package:karmashala_git/repositories.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import 'checkout_default.dart';
import 'picked_checkouts.dart';

/// The checkout the repository-scoped surfaces are currently describing. Reads
/// a *repository* row, so a session rename must not re-read it.
final selectedCheckoutProvider = Provider<Repository?>((ref) {
  ref.watchSessionKinds(const {SessionChangeKind.workspace});
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  return ref.read(workspaceDataProvider).repository(id);
});

/// The checkouts the followed session is working in, best first; empty when no
/// session is followed. Three indexed queries, no filesystem and no git, and
/// the change rank *reads* the delivery cache without watching it.
final sessionCheckoutsProvider = Provider<List<Repository>>((ref) {
  final sessionId = ref.watch(followedSessionProvider);
  if (sessionId == null) return const [];
  // Only the followed session's own row, plus whatever names no session — a
  // rescan can retire the checkout this is describing.
  ref.watchSession(sessionId);
  final session = ref.read(sessionsDataProvider).getById(sessionId);
  if (session == null) return const [];
  return sessionCheckouts(ref, session);
});

/// What the picker offers: the project's parent repositories, the active
/// session's leading, and no linked worktrees — those are level two,
/// [selectedCheckoutWorktreesProvider]. Worktree-ness is read, never asked.
final projectCheckoutsProvider = Provider<List<Repository>>((ref) {
  final selected = ref.watch(selectedCheckoutProvider);
  if (selected == null) return const [];
  return ref.watch(checkoutsInProjectProvider(selected.projectId));
});

/// [projectCheckoutsProvider] for a project the app is **not** pointed at —
/// what a surface offering a *destination*, like the New session dialog, needs.
final checkoutsInProjectProvider = Provider.family<List<Repository>, String>((
  ref,
  projectId,
) {
  ref.watchSessionKinds(const {SessionChangeKind.workspace});
  final labels = ref.exists(checkoutLabelsProvider(projectId))
      ? ref.watch(checkoutLabelsProvider(projectId)).asData?.value
      : null;
  // Unclassified is kept: "we have not asked git yet" is not "this is a
  // worktree", and hiding a clone would leave the user unable to reach it.
  bool isParent(Repository repository) =>
      labels?[repository.id]?.isWorktree != true;

  final byId = {
    for (final repository
        in ref.read(workspaceDataProvider).repositoriesOf(projectId))
      repository.id: repository,
  };

  /// The row this checkout should lead a parents-only picker with: itself, or
  /// the repository it is a worktree of.
  Repository? parentOf(Repository repository) {
    if (isParent(repository)) return repository;
    final owner = labels?[repository.id]?.ownerRepositoryId;
    // A worktree whose main checkout the workspace never recorded has no parent
    // to lead with, and inventing one points the panel at a missing repository.
    return owner == null ? null : byId[owner];
  }

  final leading = <Repository>[];
  final led = <String>{};
  for (final checkout in ref.watch(sessionCheckoutsProvider)) {
    if (checkout.projectId != projectId) continue;
    final parent = parentOf(checkout);
    if (parent == null || !led.add(parent.id)) continue;
    leading.add(parent);
  }

  final rest = byId.values.toList()
    ..sort((a, b) => a.path.path.compareTo(b.path.path));
  return [...leading, ...rest.where((r) => !led.contains(r.id) && isParent(r))];
});

/// Every repository row of the selected checkout's project, worktrees included
/// — [projectCheckoutsProvider] lists only parents.
final projectCheckoutRowsProvider = Provider<List<Repository>>((ref) {
  final selected = ref.watch(selectedCheckoutProvider);
  if (selected == null) return const [];
  return ref.watch(checkoutRowsInProjectProvider(selected.projectId));
});

/// [projectCheckoutRowsProvider] for a named project, worktrees included: the
/// worktrees of a chosen parent are these rows minus [checkoutsInProjectProvider].
final checkoutRowsInProjectProvider = Provider.family<List<Repository>, String>(
  (ref, projectId) {
    ref.watchSessionKinds(const {SessionChangeKind.workspace});
    return ref.read(workspaceDataProvider).repositoriesOf(projectId);
  },
);

/// Level two: the linked worktrees of the repository the picker has selected.
/// One `git worktree list` for one repository, only while something watches
/// this. The main worktree is dropped — it *is* the selected repository.
final selectedCheckoutWorktreesProvider =
    FutureProvider.autoDispose<List<GitWorktree>>((ref) async {
      // One `git worktree list` per workspace bump: watching the whole session
      // revision made a rename start git on a `\\wsl.localhost` path
      // (`session_signal_cost_test.dart`).
      ref.watchSessionKinds(const {SessionChangeKind.workspace});
      final selected = ref.watch(selectedCheckoutProvider);
      if (selected == null) return const [];
      ref.watchCheckout(selected.path);
      final listed = await ref
          .read(worktreeServiceProvider)
          .list(selected.path);
      return [
        for (final worktree in listed.skip(1))
          if (!worktree.isBare) worktree,
      ];
    });

/// Worktree-or-not and branch for every checkout in [projectId] — asked of
/// the server, which lists each repository *family* once. Read again when a
/// worktree of any of them comes or goes.
final checkoutLabelsProvider = FutureProvider.autoDispose
    .family<Map<String, CheckoutLabel>, String>((ref, projectId) async {
      final repositories = ref
          .read(workspaceDataProvider)
          .repositoriesOf(projectId);
      for (final repository in repositories) {
        ref.watchCheckout(repository.path);
      }
      if (repositories.isEmpty) return const {};
      return ref.read(gitDataProvider).labels([
        for (final repository in repositories) repository.id,
      ]);
    });

/// Points the repository-scoped surfaces at a checkout the user picked, and
/// remembers it against the session — see [PickedCheckouts] for why.
class CheckoutPicker {
  const CheckoutPicker(this._ref);

  final Ref _ref;

  void select(Repository repository) {
    final sessionId = _ref.read(followedSessionProvider);
    if (sessionId != null) {
      _ref
          .read(pickedCheckoutsProvider.notifier)
          .remember(sessionId, repository.id);
    }
    // Only when it differs: selecting a project kicks off a CLI-store scan.
    if (_ref.read(selectedProjectIdProvider) != repository.projectId) {
      _ref
          .read(selectedProjectIdProvider.notifier)
          .select(repository.projectId);
    }
    _ref.read(selectedRepositoryIdProvider.notifier).select(repository.id);
  }

  /// Selects the worktree at [path] in [projectId], recording it first with a
  /// rescan when the workspace has no row for it. Null when even that finds
  /// none; a failed rescan throws.
  Future<Repository?> selectWorktree(
    String projectId,
    EnvironmentPath path,
  ) async {
    Repository? rowAt() => _ref
        .read(workspaceDataProvider)
        .repositoriesOf(projectId)
        .where((r) => Checkout(r.path) == Checkout(path))
        .firstOrNull;
    var row = rowAt();
    if (row == null) {
      await _ref
          .read(projectsControllerProvider.notifier)
          .rediscover(projectId);
      row = rowAt();
    }
    if (row != null) select(row);
    return row;
  }
}

final checkoutPickerProvider = Provider(CheckoutPicker.new);
