import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../git/application/changes_providers.dart';
import '../../git/application/git_providers.dart';
import '../../git/domain/git_worktree.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import 'checkout.dart';
import 'checkout_default.dart';
import 'picked_checkouts.dart';

/// The checkout the repository-scoped surfaces are currently describing.
final selectedCheckoutProvider = Provider<Repository?>((ref) {
  ref.watch(sessionsRevisionProvider);
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  return ref.read(repositoryDaoProvider).getById(id);
});

/// The checkouts the session the panel is following is working in, best first.
///
/// [sessionCheckouts] is the rule; this is the panel's way in to it. Empty when
/// no session is followed — a plain shell tab, or a workspace nobody has opened
/// a session in — which is what leaves the picker in its plain path order.
///
/// Costs the three indexed queries [sessionCheckouts] costs and nothing else:
/// no filesystem, no git. That is the condition of reading it from a provider
/// the side panel rebuilds on every tab switch.
///
/// The change rank inside it *reads* the delivery cache without watching it, so
/// a `git status` finishing somewhere does not silently reorder an open menu —
/// the order is recomputed when the workspace or the followed session moves,
/// which is when the user has reason to expect it to.
final sessionCheckoutsProvider = Provider<List<Repository>>((ref) {
  ref.watch(sessionsRevisionProvider);
  final sessionId = ref.watch(followedSessionProvider);
  if (sessionId == null) return const [];
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) return const [];
  return sessionCheckouts(ref, session);
});

/// What the picker offers: **the project's parent repositories** — its clones —
/// with the active session's leading, and no linked worktrees at all.
///
/// **Two levels, not one list.** One rescan took the owner's `popupbits`
/// project to 69 recorded checkouts, and the picker — a line at the top of the
/// side panel that says which repository you are looking at — became sixty-nine
/// rows in path order, of which one was the answer. Listing the session's
/// checkouts first fixed the ordering and not the shape. The owner's answer is
/// better than either: *"the picker should show parent repos; the worktrees
/// should appear in the details after selecting the parent repo"*. So this is
/// level one, short by construction — a project has a handful of clones however
/// many worktrees hang off them — and [selectedCheckoutWorktreesProvider] is
/// level two.
///
/// **Which rows are worktrees is read, never asked.** `git worktree list` is
/// the only thing that truly knows, and [checkoutLabelsProvider] already runs
/// it once per repository *family* for the panel beside this one. This reads
/// that answer through `ref.exists` and never fills it, the same rule
/// `_changeRank` holds in `checkout_default.dart` — a picker that started a git
/// process per checkout to decide what to draw would be the very cost this
/// change exists to remove. A checkout nothing has classified yet is kept, so
/// the list only ever shortens as knowledge arrives and the picker is never
/// wrongly empty.
///
/// The session's own checkouts lead, so the repository you are working in is
/// the one at the top rather than whichever sorts first. Confined to the
/// selected checkout's project: offering another project's clones would move
/// the panel out from under the user.
///
/// Watches the workspace revision, not the project list: a rescan that only
/// *adds* repositories leaves the projects and the selection equal, so the
/// picker would keep listing yesterday's clones.
final projectCheckoutsProvider = Provider<List<Repository>>((ref) {
  ref.watch(sessionsRevisionProvider);
  final selected = ref.watch(selectedCheckoutProvider);
  if (selected == null) return const [];

  final labels = ref.exists(checkoutLabelsProvider(selected.projectId))
      ? ref.watch(checkoutLabelsProvider(selected.projectId)).asData?.value
      : null;
  // Unclassified is kept: "we have not asked git yet" is not "this is a
  // worktree", and hiding a clone would leave the user unable to reach it.
  bool isParent(Repository repository) =>
      labels?[repository.id]?.isWorktree != true;

  final byId = {
    for (final repository
        in ref.read(repositoryDaoProvider).getByProject(selected.projectId))
      repository.id: repository,
  };

  /// The row this checkout should put at the top of a picker that offers only
  /// parents: itself when it is one, otherwise the repository it is a worktree
  /// of. A session working in `wt-relay` is a session working on `app`, and
  /// the picker that says so is the one whose second level then holds the
  /// worktree the agent is actually in.
  Repository? parentOf(Repository repository) {
    if (isParent(repository)) return repository;
    final owner = labels?[repository.id]?.ownerRepositoryId;
    // A worktree whose main checkout the workspace never recorded has no
    // parent to lead with, and inventing one would point the panel at a
    // repository the user does not have.
    return owner == null ? null : byId[owner];
  }

  final leading = <Repository>[];
  final led = <String>{};
  for (final checkout in ref.watch(sessionCheckoutsProvider)) {
    if (checkout.projectId != selected.projectId) continue;
    final parent = parentOf(checkout);
    if (parent == null || !led.add(parent.id)) continue;
    leading.add(parent);
  }

  final rest = byId.values.toList()
    ..sort((a, b) => a.path.path.compareTo(b.path.path));
  return [
    ...leading,
    ...rest.where((r) => !led.contains(r.id) && isParent(r)),
  ];
});

/// Level two: the linked worktrees of the repository the picker has selected,
/// for the panel body to list underneath it.
///
/// One `git worktree list`, for one repository, and only while something is
/// watching this — which is the whole point of splitting the picker in two. The
/// old shape asked about every checkout in the project to draw a list nobody
/// had opened; this asks about the one the user just chose.
///
/// The main worktree is dropped: it *is* the selected repository, and repeating
/// it as a child of itself is how the old tree ended up drawing one checkout
/// twice. Empty is a real answer — a clone with no worktrees — and is not the
/// same as git having failed, which surfaces as an error on the `AsyncValue`.
final selectedCheckoutWorktreesProvider =
    FutureProvider.autoDispose<List<GitWorktree>>((ref) async {
      ref.watch(sessionsRevisionProvider);
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

  /// The `repositories` row holding this family's **main** worktree, when the
  /// workspace has one.
  ///
  /// This is what makes the picker's two levels line up. A session working in
  /// `wt-relay` must put `app` at the top of the picker — the parent it hangs
  /// off — and containment cannot work that out, because a worktree is a
  /// *sibling* of its main checkout far more often than a child of it. Only
  /// `git worktree list` knows, and it says so in the same answer that decides
  /// [isWorktree], so carrying it costs nothing.
  ///
  /// Null for a main checkout, and for a worktree whose main checkout the
  /// workspace has not recorded.
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
      final byPath = <Checkout, String>{
        for (final repository in repositories)
          Checkout(repository.path): repository.id,
      };
      final family = <Checkout, ({String? branch, bool isMain, String? owner})>{};
      for (final repository in repositories) {
        if (family.containsKey(Checkout(repository.path))) continue;
        final List<GitWorktree> listed;
        try {
          listed = await worktrees.list(repository.path);
        } catch (_) {
          // Git could not answer: this row keeps its plain name.
          continue;
        }
        if (listed.isEmpty) continue;
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

/// Points the repository-scoped surfaces at a checkout the user picked.
///
/// Another *explicit* writer of the existing precedence rule — and, since the
/// pick is remembered against the session it was made in, one the context can
/// give back. See [PickedCheckouts] for why it has to.
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
      _ref.read(selectedProjectIdProvider.notifier).select(repository.projectId);
    }
    _ref.read(selectedRepositoryIdProvider.notifier).select(repository.id);
  }
}

final checkoutPickerProvider = Provider(CheckoutPicker.new);
