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

/// Every checkout the picker can offer: the repositories discovered inside the
/// project the panel is currently pointed at, ordered by path.
///
/// Discovery already finds all of them — it keeps descending past a repository
/// it has found, and it counts a `.git` **file** as a checkout, so a nested
/// clone and a `wt-*` worktree are both rows in `repositories`. Nothing here
/// touches the filesystem: this is the table, read synchronously.
///
/// Watching the workspace revision is what makes a **rescan** show up, and it is
/// the same signal the Explorer's own tree re-reads the table on. Hanging this
/// off the project list instead would not work: a rediscovery that only *adds*
/// repositories leaves the projects equal and the selected checkout equal with
/// them, so the picker would keep listing yesterday's worktrees — which is
/// exactly the case the owner's agents create while the app is running.
final projectCheckoutsProvider = Provider<List<Repository>>((ref) {
  ref.watch(sessionsRevisionProvider);
  final selected = ref.watch(selectedCheckoutProvider);
  if (selected == null) return const [];
  final all = ref.read(repositoryDaoProvider).getByProject(selected.projectId)
    ..sort((a, b) => a.path.path.compareTo(b.path.path));
  return all;
});

/// What a picker row says about a checkout beyond its folder name: whether it is
/// a worktree of some other checkout, and the branch it has out.
///
/// Both matter for the same reason. A hub project lists `chitragupta-app` and
/// `wt-relay` side by side, and without this they are two folder names that look
/// like two clones — when one is a worktree of the other and the only thing that
/// distinguishes them is the branch.
class CheckoutLabel {
  const CheckoutLabel({required this.isWorktree, this.branch});

  /// True when git reports this directory as a linked worktree rather than the
  /// main checkout of its repository.
  final bool isWorktree;

  /// The checked-out branch, or null when detached or unreported.
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

/// Worktree-or-not and branch for every checkout in [projectId], keyed by
/// repository id.
///
/// **One `git worktree list` per repository *family*, not per row.** That
/// command, run anywhere in a family, reports the whole family — main checkout
/// first, then each linked worktree with its branch — so listing the nested
/// clone covers all fifteen `wt-*` folders beside it in one process. Rows
/// already covered by an earlier answer are skipped.
///
/// `autoDispose`, and read only from the open picker: nothing here runs while
/// the panel is merely on screen, and there is no timer behind it.
final checkoutLabelsProvider = FutureProvider.autoDispose
    .family<Map<String, CheckoutLabel>, String>((ref, projectId) async {
      final repositories = ref
          .read(repositoryDaoProvider)
          .getByProject(projectId);
      final worktrees = ref.read(worktreeServiceProvider);

      // Keyed by [Checkout] so the three spellings of one directory — the table,
      // `Session.worktree` and git's forward slashes — collapse to one entry.
      final family = <Checkout, ({String? branch, bool isMain})>{};
      for (final repository in repositories) {
        if (family.containsKey(Checkout(repository.path))) continue;
        final List<GitWorktree> listed;
        try {
          listed = await worktrees.list(repository.path);
        } catch (_) {
          // Git could not answer for this one — the row keeps its plain name
          // rather than the whole picker losing its labels.
          continue;
        }
        for (var i = 0; i < listed.length; i++) {
          // `git worktree list` always prints the main worktree first, wherever
          // in the family it was run.
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

/// Moves the repository-scoped surfaces — changes and diffs, commit and push,
/// the branch and worktree list, GitHub — to a checkout the user picked.
///
/// **The precedence rule is the one that already existed**, and this is another
/// explicit writer of it: the active session writes the selection whenever it
/// *changes*, an explicit choice writes it and then holds, because nothing
/// overwrites it until the active session changes again. A pick therefore
/// survives switching panes within the same session, and yields the moment the
/// user activates a tab belonging to a different one.
class CheckoutPicker {
  const CheckoutPicker(this._ref);

  final Ref _ref;

  void select(Repository repository) {
    // Only when it differs: `SelectedProjectController.select` kicks off a CLI
    // store scan, and picking a sibling checkout is not a project change.
    if (_ref.read(selectedProjectIdProvider) != repository.projectId) {
      _ref.read(selectedProjectIdProvider.notifier).select(repository.projectId);
    }
    _ref.read(selectedRepositoryIdProvider.notifier).select(repository.id);
  }
}

final checkoutPickerProvider = Provider(CheckoutPicker.new);
