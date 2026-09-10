import 'package:agent_cli/process.dart';
import '../../explorer/application/checkout.dart';
import 'package:karmashala_git/repositories.dart';
import '../data/repository_dao.dart';

/// Retires the checkouts whose directories are *provably* gone. Deleting a row
/// cascades into session history, so absence is proved and the root is witness.
class CheckoutRetirementService {
  const CheckoutRetirementService({
    required this.repositories,
    this.probe = const LocalCheckoutPresenceProbe(),
  });

  final RepositoryDao repositories;
  final CheckoutPresenceProbe probe;

  /// Retires every checkout of [projectId] beneath [root] whose directory is
  /// provably gone, and reports what it did and what it left alone.
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
