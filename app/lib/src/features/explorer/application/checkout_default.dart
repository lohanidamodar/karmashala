import '../../workspaces/data/workspace_data.dart';
import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_providers.dart';
import 'package:karmashala_session/session.dart';

/// The checkout the scoped surfaces describe when the user has not picked one:
/// the strongest location the session has a *record* of — working directory,
/// worktree, subagents, launch repository — resolved to the deepest checkout.
Repository? inferredCheckoutFor(Ref ref, Session session) {
  final checkouts = sessionCheckouts(ref, session);
  return checkouts.isEmpty ? null : checkouts.first;
}

/// Every checkout [session] is working in, strongest record first — the same
/// question [inferredCheckoutFor] asks, keeping the runners-up. The launch
/// repository is last always: a guess may not outrank a recorded location.
List<Repository> sessionCheckouts(Ref ref, Session session) {
  final workspace = ref.read(workspaceDataProvider);
  final own = workspace.repository(session.repositoryId);

  final ordered = <Repository>[];
  final seen = <String>{};
  void add(Repository? repository) {
    if (repository != null && seen.add(repository.id)) ordered.add(repository);
  }

  final recorded = session.workingDirectory ?? session.worktree;
  if (recorded != null) add(checkoutContaining(workspace, recorded) ?? own);
  _subagentCheckouts(ref, session, own).forEach(add);
  final directory = own?.path;
  add(
    directory == null ? own : checkoutContaining(workspace, directory) ?? own,
  );
  return ordered;
}

/// The registered checkout containing [directory] that is deepest — a session
/// in `hub/projects/app` belongs to `app`, not the `hub` above it.
///
/// Public because the sidebar asks the same question of a live directory: a
/// second copy of this rule is how the tree and the follower would disagree.
Repository? checkoutContaining(
  WorkspaceData workspace,
  EnvironmentPath directory,
) {
  Repository? best;
  for (final repository in workspace.repositories) {
    if (!isUnder(repository.path, directory)) continue;
    if (best == null || pathDepth(repository.path) > pathDepth(best.path)) {
      best = repository;
    }
  }
  return best;
}

/// Where [parent]'s subagents are working, best first. Only *recorded*
/// directories count, and only within [own]'s project: following a subagent
/// elsewhere moves the tree out from under the user.
List<Repository> _subagentCheckouts(Ref ref, Session parent, Repository? own) {
  if (own == null) return const [];
  final children = ref.read(sessionsDataProvider).childrenOf(parent.id);
  if (children.isEmpty) return const [];
  final workspace = ref.read(workspaceDataProvider);

  final found = <String, Repository>{};
  final votes = <String, int>{};
  for (final child in children) {
    final directory = child.workingDirectory ?? child.worktree;
    if (directory == null) continue;
    final repository = checkoutContaining(workspace, directory);
    if (repository == null || repository.projectId != own.projectId) continue;
    found[repository.id] = repository;
    votes[repository.id] = (votes[repository.id] ?? 0) + 1;
  }
  if (found.isEmpty) return const [];

  // Ranked once rather than inside the comparator: a read per comparison would
  // ask Riverpod the same question O(n log n) times for one answer.
  final changes = {
    for (final entry in found.entries)
      entry.key: _changeRank(ref, entry.value.path),
  };
  return found.values.toList()..sort((a, b) {
    final byChanges = changes[b.id]!.compareTo(changes[a.id]!);
    if (byChanges != 0) return byChanges;
    final byVotes = votes[b.id]!.compareTo(votes[a.id]!);
    if (byVotes != 0) return byVotes;
    return canonicalPathKey(
      a.path.path,
    ).compareTo(canonicalPathKey(b.path.path));
  });
}

/// How a checkout ranks on "is there work here": 2 for reported changes, 1 for
/// unmeasured, 0 for clean. Reads the delivery cache, never fills it. Unknown
/// outranks clean, because nobody asking is not evidence.
int _changeRank(Ref ref, EnvironmentPath path) {
  final provider = checkoutDeliveryProvider(Checkout(path));
  if (!ref.exists(provider)) return 1;
  final dirtyFiles = ref.read(provider).asData?.value.dirtyFiles;
  if (dirtyFiles == null) return 1;
  return dirtyFiles > 0 ? 2 : 0;
}

/// Where a session started *at the project* runs: the checkout the project
/// chose, else the first row the picker would offer. A chosen id that no longer
/// names one of the project's checkouts falls back rather than refusing — a
/// retired row must not take the `+` button down with it.
Repository? projectDefaultCheckout({
  required String? defaultRepositoryId,
  required List<Repository> offered,
  required List<Repository> all,
}) {
  if (defaultRepositoryId != null) {
    for (final repository in offered) {
      if (repository.id == defaultRepositoryId) return repository;
    }
    for (final repository in all) {
      if (repository.id == defaultRepositoryId) return repository;
    }
  }
  return offered.firstOrNull ?? all.firstOrNull;
}
