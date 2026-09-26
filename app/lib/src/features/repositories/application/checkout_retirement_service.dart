import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';
import '../../workspaces/data/workspace_data.dart';

/// Retires the checkouts whose directories are *provably* gone — absence is
/// proved here, with the root as witness; the server deletes only those no
/// recorded history hangs off, and names the rest.
class CheckoutRetirementService {
  const CheckoutRetirementService({
    required this.workspace,
    this.probe = const LocalCheckoutPresenceProbe(),
  });

  final WorkspaceData workspace;
  final CheckoutPresenceProbe probe;

  /// Retires every checkout of [projectId] beneath [root] whose directory is
  /// provably gone, and reports what it did and what it left alone.
  Future<CheckoutRetirementReport> retireMissingCheckouts({
    required String projectId,
    required EnvironmentPath root,
    required ExecutionEnvironment environment,
    required ExecutionEnvironment windows,
  }) async {
    final candidates = workspace
        .repositoriesOf(projectId)
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

    final gone = <Repository>[];
    final keptUnreachable = <Repository>[];
    // Asked together: a WSL project's checkouts are then one `wsl.exe` call,
    // and a share that blocks costs one deadline rather than one per checkout.
    final presences = await Future.wait([
      for (final candidate in candidates)
        _presenceOf(candidate.path, environment, windows),
    ]);
    for (final (index, candidate) in candidates.indexed) {
      final presence = presences[index];
      if (presence == CheckoutPresence.present) continue;
      if (presence == CheckoutPresence.unknown) {
        keptUnreachable.add(candidate);
        continue;
      }
      gone.add(candidate);
    }
    final records = gone.isEmpty
        ? const <String, int>{}
        : await workspace.write(
            CheckoutsRetire([for (final checkout in gone) checkout.id]),
          );

    return CheckoutRetirementReport(
      examined: candidates.length,
      retired: [
        for (final checkout in gone)
          if (records[checkout.id] == 0) checkout,
      ],
      keptReferenced: [
        for (final checkout in gone)
          if (records[checkout.id] case final kept? when kept > 0)
            ReferencedCheckout(repository: checkout, records: kept),
      ],
      keptUnreachable: keptUnreachable,
    );
  }

  Future<CheckoutPresence> _presenceOf(
    EnvironmentPath directory,
    ExecutionEnvironment environment,
    ExecutionEnvironment windows,
  ) => probe.presenceOf(directory, environment: environment, windows: windows);
}
