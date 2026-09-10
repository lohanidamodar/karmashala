import 'package:karmashala_core/util.dart';

/// The instant every fixture is dated from, so a report's `observedAt` can be
/// compared against a literal.
final testTime = DateTime.utc(2026, 1, 2, 3, 4, 5);

/// A [Clock] that always returns a fixed instant.
class FixedClock implements Clock {
  FixedClock(this._now);
  final DateTime _now;

  @override
  DateTime nowUtc() => _now.toUtc();
}
