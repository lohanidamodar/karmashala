import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../explorer/application/checkout.dart';
import '../data/checkout_presence_probe.dart';
import '../data/repository_dao.dart';
import '../domain/checkout_retirement.dart';
import '../domain/repository.dart';

/// Retires the checkouts a project recorded whose directories have genuinely
/// gone away.
///
/// **Why this exists.** Discovery only ever added. A workspace that deletes
/// twenty-one merged worktrees in an afternoon keeps twenty-one rows pointing
/// at nothing, and each of them is charged for: six `git` subprocesses per
/// recorded checkout on every refresh, on WSL paths over 9p where a single
/// `stat` costs a millisecond, plus a card in the Explorer for a folder that is
/// not there. Rescan was the obvious place to notice, and the only thing it
/// could not do.
///
/// **Why it is careful.** Deleting a `repositories` row cascades into
/// `sessions`, `session_repositories`, `imported_sessions` and
/// `fanout_comparisons`. The cost of being wrong is therefore not a missing
/// row in a picker — it is the user's session history, deleted by a
/// housekeeping pass they did not ask for. So the pass gives away nothing it
/// cannot prove:
///
/// 1. **absence is proved, not inferred.** A checkout is retired only when a
///    filesystem that answered said the directory is not there
///    ([CheckoutPresence.absent]); anything the probe could not reach is kept.
///    Not being in the scan result means nothing on its own — discovery skips
///    unreadable directories, skips symlinks, stops at `maxDepth` and ignores
///    `node_modules` and friends, so "not found" and "not there" are different
///    facts and only the second one is here.
/// 2. **the root is the witness.** Every child of a stopped distro or an
///    unmounted drive reads as absent, and no per-path check can tell that
///    apart from a deletion. So nothing is retired at all unless the project
///    root itself answered *present* — the one directory we know was there,
///    since the scan that leads here begins by reading it.
/// 3. **history outranks tidiness.** A checkout that is genuinely gone but
///    still referenced is kept and *named*, so the user is told rather than
///    finding transcripts missing later.
/// 4. **it minds its own scan.** Only rows under the root being rescanned are
///    candidates, compared within one environment — `/src/demo` in a distro is
///    not `C:\src\demo`, however the strings look.
class CheckoutRetirementService {
  const CheckoutRetirementService({
    required this.repositories,
    this.probe = const LocalCheckoutPresenceProbe(),
  });

  final RepositoryDao repositories;
  final CheckoutPresenceProbe probe;

  /// Retires every checkout of [projectId] beneath [root] whose directory is
  /// provably gone, and reports what it did and what it left alone.
  ///
  /// [environment] is the environment [root] and the project's rows are written
  /// in; [windows] is the host the check actually runs on, as in
  /// `ProjectService.rediscover`, which scans on the host and records in the
  /// project's environment.
  Future<CheckoutRetirementReport> retireMissingCheckouts({
    required String projectId,
    required EnvironmentPath root,
    required ExecutionEnvironment environment,
    required ExecutionEnvironment windows,
  }) async {
    final candidates = repositories
        .getByProject(projectId)
        .where((repository) => isUnder(root, repository.path))
        .toList();
    if (candidates.isEmpty) return CheckoutRetirementReport.nothing;

    if (await _presenceOf(root, environment, windows) !=
        CheckoutPresence.present) {
      return CheckoutRetirementReport(
        examined: candidates.length,
        rootReachable: false,
        keptUnreachable: candidates,
      );
    }

    final retired = <Repository>[];
    final keptReferenced = <ReferencedCheckout>[];
    final keptUnreachable = <Repository>[];
    for (final candidate in candidates) {
      final presence = await _presenceOf(candidate.path, environment, windows);
      if (presence == CheckoutPresence.present) continue;
      if (presence == CheckoutPresence.unknown) {
        keptUnreachable.add(candidate);
        continue;
      }
      final records = repositories.historyReferenceCount(candidate.id);
      if (records > 0) {
        keptReferenced.add(
          ReferencedCheckout(repository: candidate, records: records),
        );
        continue;
      }
      repositories.delete(candidate.id);
      retired.add(candidate);
    }

    return CheckoutRetirementReport(
      examined: candidates.length,
      retired: retired,
      keptReferenced: keptReferenced,
      keptUnreachable: keptUnreachable,
    );
  }

  Future<CheckoutPresence> _presenceOf(
    EnvironmentPath directory,
    ExecutionEnvironment environment,
    ExecutionEnvironment windows,
  ) => probe.presenceOf(directory, environment: environment, windows: windows);
}
