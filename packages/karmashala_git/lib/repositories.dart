/// A repository, its checkouts, and whether they are still on disk.
///
/// `CheckoutPresenceProbe` is the only piece with I/O: it stats a checkout in
/// its own environment, and reports *unchecked* rather than *missing* for a
/// path it could not reach (CLAUDE.md §19).
library;

export 'src/repositories/data/checkout_presence_probe.dart';
export 'src/repositories/domain/checkout_retirement.dart';
export 'src/repositories/domain/discovered_repository.dart';
export 'src/repositories/domain/repository.dart';
export 'src/repositories/domain/repository_identity.dart';
