import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'id_generator.dart';

/// Provides the application's [IdGenerator]. Overridden in tests with a
/// deterministic generator.
final idGeneratorProvider = Provider<IdGenerator>((ref) => RandomIdGenerator());
