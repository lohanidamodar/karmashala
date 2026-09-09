import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import 'package:karmashala_git/repositories.dart';
import '../data/repository_dao.dart';
import 'checkout_retirement_service.dart';

/// Repository-layer provider for Git-repository persistence.
final repositoryDaoProvider = Provider<RepositoryDao>(
  (ref) => RepositoryDao(ref.watch(databaseProvider)),
);

/// Whether a recorded checkout's directory is still on disk. Overridden in
/// tests with a stub, so a case like "the distro is stopped" can be stated
/// rather than staged.
final checkoutPresenceProbeProvider = Provider<CheckoutPresenceProbe>(
  (ref) => const LocalCheckoutPresenceProbe(),
);

/// Retires checkouts whose directories are provably gone. The rescan's other
/// half: [ProjectService.rediscover] only ever added, so twenty-one worktrees
/// deleted from disk stayed in the table — and in every picker and panel that
/// reads it — indefinitely.
///
/// A provider so that wiring it into the rescan is one line at the call site;
/// the service itself takes its seams by constructor so its own tests can state
/// "the distro is stopped" rather than stage it.
final checkoutRetirementServiceProvider = Provider<CheckoutRetirementService>(
  (ref) => CheckoutRetirementService(
    repositories: ref.watch(repositoryDaoProvider),
    probe: ref.watch(checkoutPresenceProbeProvider),
  ),
);
