import '../../workspaces/data/workspace_data.dart';
import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import '../../git/application/changes_providers.dart';
import '../../git/application/git_providers.dart';
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
  final session = ref.read(sessionDaoProvider).getById(sessionId);
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
      final listed = await ref
          .read(worktreeServiceProvider)
          .list(selected.path);
      return [
        for (final worktree in listed.skip(1))
          if (!worktree.isBare) worktree,
      ];
    });

/// Whether a checkout is a linked worktree, the branch it has out, and which
/// recorded repository it is a worktree *of*.
class CheckoutLabel {
  const CheckoutLabel({
    required this.isWorktree,
    this.branch,
    this.ownerRepositoryId,
  });

  final bool isWorktree;

  /// Null when detached or unreported.
  final String? branch;

  /// The `repositories` row holding this family's **main** worktree. Only
  /// `git worktree list` knows it: a worktree is a *sibling* of its main
  /// checkout more often than a child, so containment cannot work it out.
  final String? ownerRepositoryId;

  @override
  bool operator ==(Object other) =>
      other is CheckoutLabel &&
      other.isWorktree == isWorktree &&
      other.branch == branch &&
      other.ownerRepositoryId == ownerRepositoryId;

  @override
  int get hashCode => Object.hash(isWorktree, branch, ownerRepositoryId);

  @override
  String toString() =>
      'CheckoutLabel(worktree: $isWorktree, branch: $branch, '
      'owner: $ownerRepositoryId)';
}

/// Worktree-or-not and branch for every checkout in [projectId] — one `git
/// worktree list` per repository *family*, grouped by `familyKey` before git is
/// asked. Rows with no key (SSH) fall back to the sequential pass.
final checkoutLabelsProvider = FutureProvider.autoDispose
    .family<Map<String, CheckoutLabel>, String>((ref, projectId) async {
      final repositories = ref
          .read(workspaceDataProvider)
          .repositoriesOf(projectId);
      final worktrees = ref.read(worktreeServiceProvider);
      final changes = ref.read(changesServiceProvider);

      // Keyed by [Checkout]: git reports forward slashes where the table holds
      // backslashes, and both spell one directory.
      final byPath = <Checkout, String>{
        for (final repository in repositories)
          Checkout(repository.path): repository.id,
      };
      final family =
          <Checkout, ({String? branch, bool isMain, String? owner})>{};

      /// Files a listing into [family], or does nothing when git could not
      /// answer — that row keeps its plain name.
      void record(List<GitWorktree>? listed) {
        if (listed == null || listed.isEmpty) return;
        // `git worktree list` prints the main worktree first, always.
        final owner = byPath[Checkout(listed.first.path)];
        for (var i = 0; i < listed.length; i++) {
          family.putIfAbsent(
            Checkout(listed[i].path),
            () => (
              branch: listed[i].branch,
              isMain: i == 0,
              owner: i == 0 ? null : owner,
            ),
          );
        }
      }

      Future<List<GitWorktree>?> listOrNull(EnvironmentPath path) async {
        try {
          return await worktrees.list(path);
        } catch (_) {
          return null;
        }
      }

      // No process yet: this is a `typeOf` per row, and for a worktree one
      // further read of the pointer file beside it.
      final keys = await Future.wait([
        for (final repository in repositories)
          changes.familyKey(repository.path).catchError((_) => null),
      ]);

      final representatives = <String, EnvironmentPath>{};
      final unkeyed = <Repository>[];
      for (var i = 0; i < repositories.length; i++) {
        final key = keys[i];
        if (key == null) {
          unkeyed.add(repositories[i]);
          continue;
        }
        representatives.putIfAbsent(key, () => repositories[i].path);
      }

      // One process per family, all at once.
      for (final listed in await Future.wait([
        for (final path in representatives.values) listOrNull(path),
      ])) {
        record(listed);
      }

      // And the rows nothing could be read about: in order, skipping whatever
      // is already covered.
      for (final repository in unkeyed) {
        if (family.containsKey(Checkout(repository.path))) continue;
        record(await listOrNull(repository.path));
      }

      return {
        for (final repository in repositories)
          if (family[Checkout(repository.path)] case final entry?)
            repository.id: CheckoutLabel(
              isWorktree: !entry.isMain,
              branch: entry.branch,
              ownerRepositoryId: entry.owner,
            ),
      };
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
}

final checkoutPickerProvider = Provider(CheckoutPicker.new);
