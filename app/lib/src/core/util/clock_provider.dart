import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/util.dart';

/// Provides the application [Clock]. Overridden in tests with a fixed clock.
final clockProvider = Provider<Clock>((ref) => const SystemClock());
