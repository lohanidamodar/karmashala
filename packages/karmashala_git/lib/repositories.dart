/// A repository, its checkouts, and whether they are still on disk.
///
/// `CheckoutPresenceProbe` and `LocalRepositoryDiscoveryService` are the only
/// pieces with I/O; the probe reports *unchecked* rather than *missing* for a
/// path it could not reach (CLAUDE.md §19).
library;

export 'src/repositories/data/checkout_presence_probe.dart';
export 'src/repositories/data/posix_repository_discovery.dart';
export 'src/repositories/data/repository_discovery.dart';
export 'src/repositories/domain/checkout.dart';
export 'src/repositories/domain/checkout_label.dart';
export 'src/repositories/domain/checkout_retirement.dart';
export 'src/repositories/domain/discovered_repository.dart';
export 'src/repositories/domain/repository.dart';
export 'src/repositories/domain/repository_identity.dart';
