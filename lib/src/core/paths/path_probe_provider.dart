import 'package:riverpod/riverpod.dart';

import 'path_probe.dart';

/// Provides the filesystem seam path repair stats through. Overridden in tests
/// with a described disk.
final pathProbeProvider = Provider<PathProbe>((ref) => const LocalPathProbe());
