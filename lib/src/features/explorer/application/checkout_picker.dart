import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../git/application/changes_providers.dart';
import '../../git/application/git_providers.dart';
import '../../git/domain/git_worktree.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/application/session_ui_providers.dart';
import 'checkout.dart';

/// The checkout the repository-scoped surfaces are currently describing.
final selectedCheckoutProvider = Provider<Repository?>((ref) {
  ref.watch(sessionsRevisionProvider);
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  return ref.read(repositoryDaoProvider).getById(id);
});

/// Every checkout in the project the panel is pointed at, ordered by path.
///
/// Watches the workspace revision, not the project list: a rescan that only
/// *adds* repositories leaves the projects and the selection equal, so the
/// picker would keep listing yesterday's worktrees.
final projectCheckoutsProvider = Provider<List<Repository>>((ref) {
  ref.watch(sessionsRevisionProvider);
  final selected = ref.watch(selectedCheckoutProvider);
  if (selected == null) return const [];
  final all = ref.read(repositoryDaoProvider).getByProject(selected.projectId)
    ..sort((a, b) => a.path.path.compareTo(b.path.path));
  return all;
});

/// Whether a checkout is a linked worktree, and the branch it has out.
class CheckoutLabel {
  const CheckoutLabel({required this.isWorktree, this.branch});

  final bool isWorktree;

  /// Null when detached or unreported.
  final String? branch;

  @override
  bool operator ==(Object other) =>
      other is CheckoutLabel &&
      other.isWorktree == isWorktree &&
      other.branch == branch;

  @override
  int get hashCode => Object.hash(isWorktree, branch);

  @override
  String toString() => 'CheckoutLabel(worktree: $isWorktree, branch: $branch)';
}

/// Worktree-or-not and branch for every checkout in [projectId], by repository
/// id.
///
/// One `git worktree list` per repository *family*, not per row — the command
/// reports the whole family wherever it is run. `autoDispose`, and read only
/// from the open picker, so nothing runs while the panel merely sits there.
final checkoutLabelsProvider = FutureProvider.autoDispose
    .family<Map<String, CheckoutLabel>, String>((ref, projectId) async {
      final repositories = ref
          .read(repositoryDaoProvider)
          .getByProject(projectId);
      final worktrees = ref.read(worktreeServiceProvider);

      // Keyed by [Checkout]: git reports forward slashes where the table holds
      // backslashes, and both spell one directory.
      final family = <Checkout, ({String? branch, bool isMain})>{};
      for (final repository in repositories) {
        if (family.containsKey(Checkout(repository.path))) continue;
        final List<GitWorktree> listed;
        try {
          listed = await worktrees.list(repository.path);
        } catch (_) {
          // Git could not answer: this row keeps its plain name.
          continue;
        }
        for (var i = 0; i < listed.length; i++) {
          // `git worktree list` prints the main worktree first, always.
          family.putIfAbsent(
            Checkout(listed[i].path),
            () => (branch: listed[i].branch, isMain: i == 0),
          );
        }
      }

      return {
        for (final repository in repositories)
          if (family[Checkout(repository.path)] case final entry?)
            repository.id: CheckoutLabel(
              isWorktree: !entry.isMain,
              branch: entry.branch,
            ),
      };
    });

/// Points the repository-scoped surfaces at a checkout the user picked.
///
/// Another *explicit* writer of the existing precedence rule: a pick holds
/// until the active session changes, exactly as an Explorer click does.
class CheckoutPicker {
  const CheckoutPicker(this._ref);

  final Ref _ref;

  void select(Repository repository) {
    // Only when it differs: selecting a project kicks off a CLI-store scan.
    if (_ref.read(selectedProjectIdProvider) != repository.projectId) {
      _ref.read(selectedProjectIdProvider.notifier).select(repository.projectId);
    }
    _ref.read(selectedRepositoryIdProvider.notifier).select(repository.id);
  }
}

final checkoutPickerProvider = Provider(CheckoutPicker.new);
