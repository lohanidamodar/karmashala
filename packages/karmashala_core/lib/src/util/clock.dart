/// A source of the current time, abstracted so timestamps are deterministic in
/// tests (inject a fixed clock) instead of reading the wall clock directly.
abstract interface class Clock {
  /// The current instant, in UTC.
  DateTime nowUtc();
}

/// Default [Clock] backed by the system wall clock.
class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}
