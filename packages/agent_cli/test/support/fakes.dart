import 'package:agent_cli/src/util/clock.dart';
import 'package:agent_cli/src/util/id_generator.dart';

/// A [Clock] that always returns a fixed instant.
class FixedClock implements Clock {
  FixedClock(this._now);
  final DateTime _now;
  @override
  DateTime nowUtc() => _now.toUtc();
}

/// A [Clock] a test moves by hand.
class MovableClock implements Clock {
  MovableClock(this.now);

  DateTime now;

  @override
  DateTime nowUtc() => now.toUtc();

  void advance(Duration by) => now = now.add(by);
}

/// An [IdGenerator] that returns predictable, sequential ids (`id-0`, `id-1`…).
class SequentialIdGenerator implements IdGenerator {
  SequentialIdGenerator([this._prefix = 'id-']);
  final String _prefix;
  int _next = 0;
  @override
  String newId() => '$_prefix${_next++}';
}
