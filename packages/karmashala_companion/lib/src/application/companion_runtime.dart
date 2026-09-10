/// The process facts the phone's own container holds. The desktop declares its
/// own over the same three types; a build is one app or the other, never both.
library;

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_core/util.dart';

/// The clock every companion reading is stamped against. Overridden in tests
/// with a fixed clock.
final companionClockProvider = Provider<Clock>((ref) => const SystemClock());

/// Ids for what this phone starts. Overridden in tests with a deterministic
/// generator.
final companionIdGeneratorProvider = Provider<IdGenerator>(
  (ref) => RandomIdGenerator(),
);

/// The log buffer the diagnostics screen reads.
final companionDiagnosticsProvider = Provider<Diagnostics>(
  (ref) => Diagnostics.instance,
);
