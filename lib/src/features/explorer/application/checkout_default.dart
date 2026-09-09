import 'package:riverpod/riverpod.dart';

import '../../environments/domain/environment_path.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/data/repository_dao.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/domain/session.dart';
import 'checkout.dart';

/// The checkout the repository-scoped surfaces describe for a session **when
/// the user has not picked one**.
///
/// **The bug.** A session's working directory used to be fixed at launch, and
/// the rule was "the deepest registered checkout containing it". For a hub
/// project that answers *the hub* for every session started there, while the
/// work happens in a clone three folders down and in the `wt-*` worktrees
/// beside it. The owner reported the Changes and GitHub panels describing the
/// wrong checkout three times, and picking one was only half the fix: a default
/// that is wrong every time is a default nobody should have to correct.
///
/// **The rule.** Take the strongest location this session has an actual
/// *record* of, then resolve it the way the tree already does — the deepest
/// registered checkout containing it, which is also what `placeSessions` uses
/// to decide which Explorer row a session is drawn on, so the row and the panel
/// cannot disagree. Strongest first:
///
/// 1. **the directory the agent runs in** — `Session.workingDirectory`, schema
///    v22. For a session adopted out of a terminal tab this is an observation
///    of the live process rather than a launch-time guess, which makes it the
///    strongest thing here;
/// 2. **the worktree the app cut for this session** — where a worktree session
///    must be;
/// 3. **where this session's subagents work** — see [_subagentCheckouts]. The
///    signal that actually explains the report: the owner's own shell
///    legitimately stays in the hub, and it is the agents it spawns that move;
/// 4. **the session's own repository**, which is the launch-time guess and the
///    only answer this had before.
///
/// A weaker signal never overrules a stronger one. A session that recorded its
/// own directory is described by that directory even when every subagent it
/// started is somewhere else, because the panel describes the session you are
/// looking at, not the ones it delegated to.
///
/// **Cost.** This runs every time the active session changes, which at a
/// hundred panes is constant, so nothing in it touches the filesystem or starts
/// a process: three indexed queries and a read of a cache somebody else filled.
///
/// Deliberately not `sessionWorkingDirectoryOf`, whose third step is the
/// repository root — that is the guess this function exists to improve on, and
/// folding it in would hide steps 1 and 2 behind it.
Repository? inferredCheckoutFor(Ref ref, Session session) {
  final checkouts = sessionCheckouts(ref, session);
  return checkouts.isEmpty ? null : checkouts.first;
}

/// Every checkout [session] is working in, **strongest record first**.
///
/// The same question [inferredCheckoutFor] asks, answered without throwing the
/// runners-up away — because "which worktrees is this session working on" is
/// what the right-hand panel's picker wants to lead with, and a rule that
/// disagreed with the default it also computes would be two rules.
///
/// The order *is* the ranking, and it reads down the certainty ladder above:
///
/// 1. **the location the session has a record of** — its working directory or
///    the worktree the app cut it, resolved to the deepest registered checkout
///    containing it. Absent when it has neither;
/// 2. **where its subagents work**, ranked between themselves by
///    [_subagentCheckouts];
/// 3. **the repository it was launched against**, last and always. That is a
///    guess rather than a record — which is exactly why it may not outrank a
///    subagent that actually said where it is — but it is still where the
///    session sits, so it belongs in the group rather than out of it.
///
/// Distinct checkouts only: a session whose own directory is also the one all
/// of its subagents named is one entry, not three.
List<Repository> sessionCheckouts(Ref ref, Session session) {
  final repositories = ref.read(repositoryDaoProvider);
  final own = repositories.getById(session.repositoryId);

  final ordered = <Repository>[];
  final seen = <String>{};
  void add(Repository? repository) {
    if (repository != null && seen.add(repository.id)) ordered.add(repository);
  }

  final recorded = session.workingDirectory ?? session.worktree;
  if (recorded != null) add(_deepestContaining(repositories, recorded) ?? own);
  _subagentCheckouts(ref, session, own).forEach(add);
  final directory = own?.path;
  add(
    directory == null
        ? own
        : _deepestContaining(repositories, directory) ?? own,
  );
  return ordered;
}

/// The registered checkout that contains [directory] and is deepest — a session
/// in `hub/projects/app` belongs to `app`, not to the `hub` above it. Null when
/// nothing contains it: a different environment, or a directory outside every
/// checkout the workspace knows.
Repository? _deepestContaining(
  RepositoryDao repositories,
  EnvironmentPath directory,
) {
  Repository? best;
  for (final repository in repositories.getAll()) {
    if (!isUnder(repository.path, directory)) continue;
    if (best == null || pathDepth(repository.path) > pathDepth(best.path)) {
      best = repository;
    }
  }
  return best;
}

/// Where [parent]'s subagents are working, best first, or empty when they say
/// nothing.
///
/// A subagent the app started is a session row of its own — `open_new_session`
/// goes through the same launcher as the New-session dialog — so since schema
/// v22 it records the directory it runs in. Only *recorded* directories count:
/// a child that recorded none carries the same launch-time guess as its parent
/// and would only vote for the answer we already have.
///
/// Confined to [own]'s project. Following a subagent into another project would
/// move the Explorer's tree out from under the user, which is a larger surprise
/// than the wrong checkout inside the right project — and the picker has the
/// same rule.
///
/// **When they disagree**, and with several worktrees in flight they will:
///
/// 1. **uncommitted work** — the checkout with changes is the one being worked
///    in (see [_changeRank]);
/// 2. **how many subagents named it**;
/// 3. **the path itself**, so the answer never depends on the order the table
///    happened to return the rows in.
List<Repository> _subagentCheckouts(Ref ref, Session parent, Repository? own) {
  if (own == null) return const [];
  final children = ref.read(sessionDaoProvider).childrenOf(parent.id);
  if (children.isEmpty) return const [];
  final repositories = ref.read(repositoryDaoProvider);

  final found = <String, Repository>{};
  final votes = <String, int>{};
  for (final child in children) {
    final directory = child.workingDirectory ?? child.worktree;
    if (directory == null) continue;
    final repository = _deepestContaining(repositories, directory);
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

/// How a checkout ranks on "is there work in progress here": 2 for changes git
/// has already reported, 1 for a checkout nothing has measured, 0 for one git
/// called clean.
///
/// **Reads the cache and never fills it.** `checkoutDeliveryProvider` is what
/// the Explorer's rows and the delivery strip already watch, so by the time a
/// tab switch asks this the answer is usually sitting there; *asking* for it
/// would start a `git status` per candidate on a path that runs on every tab
/// switch, which is the one thing this tie-break may not cost.
///
/// Unknown outranks clean deliberately. Git saying "nothing here" is evidence
/// against a checkout; nobody having asked is not evidence of anything.
int _changeRank(Ref ref, EnvironmentPath path) {
  final provider = checkoutDeliveryProvider(Checkout(path));
  if (!ref.exists(provider)) return 1;
  final dirtyFiles = ref.read(provider).asData?.value.dirtyFiles;
  if (dirtyFiles == null) return 1;
  return dirtyFiles > 0 ? 2 : 0;
}
