import 'package:chitragupta/src/core/util/clock.dart';
import 'package:chitragupta/src/core/util/id_generator.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/repositories/data/repository_discovery_service.dart';
import 'package:chitragupta/src/features/repositories/domain/discovered_repository.dart';

/// A [Clock] that always returns a fixed instant.
class FixedClock implements Clock {
  FixedClock(this._now);
  final DateTime _now;
  @override
  DateTime nowUtc() => _now.toUtc();
}

/// An [IdGenerator] that returns predictable, sequential ids (`id-0`, `id-1`…).
class SequentialIdGenerator implements IdGenerator {
  SequentialIdGenerator([this._prefix = 'id-']);
  final String _prefix;
  int _next = 0;
  @override
  String newId() => '$_prefix${_next++}';
}

/// A [RepositoryDiscoveryService] returning a preset result (or throwing a
/// preset error), so use-cases can be tested without touching the filesystem.
class FakeRepositoryDiscoveryService implements RepositoryDiscoveryService {
  FakeRepositoryDiscoveryService({this.result = const [], this.error});

  /// Repositories to return from [discover].
  List<DiscoveredRepository> result;

  /// If set, [discover] throws this instead of returning [result].
  Object? error;

  /// Records the roots discovery was invoked with.
  final List<EnvironmentPath> calls = [];

  @override
  Future<List<DiscoveredRepository>> discover(
    EnvironmentPath root, {
    int maxDepth = 5,
  }) async {
    calls.add(root);
    if (error != null) throw error!;
    return result;
  }
}
