import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../data/checkout_presence_probe.dart';
import '../data/repository_dao.dart';

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
