import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import 'package:karmashala_git/repositories.dart';
import '../data/repository_dao.dart';
import '../../projects/application/wsl_path_existence.dart';
import 'checkout_retirement_service.dart';
import 'host_checkout_presence_probe.dart';

/// Repository-layer provider for Git-repository persistence.
final repositoryDaoProvider = Provider<RepositoryDao>(
  (ref) => RepositoryDao(ref.watch(databaseProvider)),
);

/// Whether a recorded checkout's directory is still on disk. Overridden in
/// tests with a stub, so a case like "the distro is stopped" can be stated
/// rather than staged.
final checkoutPresenceProbeProvider = Provider<CheckoutPresenceProbe>(
  (ref) => HostCheckoutPresenceProbe(wsl: ref.watch(wslPathExistenceProvider)),
);

/// Retires checkouts whose directories are provably gone — the rescan's other
/// half, since [ProjectService.rediscover] only ever added.
final checkoutRetirementServiceProvider = Provider<CheckoutRetirementService>(
  (ref) => CheckoutRetirementService(
    repositories: ref.watch(repositoryDaoProvider),
    probe: ref.watch(checkoutPresenceProbeProvider),
  ),
);
