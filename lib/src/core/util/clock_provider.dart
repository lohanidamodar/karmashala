import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'clock.dart';

/// Provides the application [Clock]. Overridden in tests with a fixed clock.
final clockProvider = Provider<Clock>((ref) => const SystemClock());
