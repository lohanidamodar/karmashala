/// A source of the current time, abstracted so a test can inject a fixed one.
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
