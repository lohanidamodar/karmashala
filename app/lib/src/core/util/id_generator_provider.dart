import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/util.dart';

/// Provides the application's [IdGenerator]. Overridden in tests with a
/// deterministic generator.
final idGeneratorProvider = Provider<IdGenerator>((ref) => RandomIdGenerator());
