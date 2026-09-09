import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/paths.dart';

/// Provides the filesystem seam path repair stats through. Overridden in tests
/// with a described disk.
final pathProbeProvider = Provider<PathProbe>((ref) => const LocalPathProbe());
