import 'dart:convert';

/// The `settings.v1` key holding how many minutes a working session may go
/// with nothing new before it reads quiet.
const String kQuietAfterSetting = 'quietAfterMinutes';

/// The quiet threshold when nobody chose one: one slow test run is not
/// flagged, a hung turn is noticed the same hour.
const Duration kDefaultQuietAfter = Duration(minutes: 15);

/// The environment variable a probe shortens the threshold with, in seconds.
const String kQuietAfterVariable = 'KARMASHALA_QUIET_AFTER_SECONDS';

/// The threshold `settings.v1` ([raw]) asks for, between 1 and 240 minutes;
/// [overrideSeconds], when a positive number, wins.
Duration quietAfterFrom(String? raw, {String? overrideSeconds}) {
  final seconds = int.tryParse(overrideSeconds ?? '');
  if (seconds != null && seconds > 0) return Duration(seconds: seconds);
  try {
    final decoded = raw == null ? null : jsonDecode(raw);
    final minutes = decoded is Map ? decoded[kQuietAfterSetting] : null;
    if (minutes is num) {
      return Duration(minutes: minutes.round().clamp(1, 240));
    }
  } on FormatException {
    // Defaults.
  }
  return kDefaultQuietAfter;
}

/// [quietAfterFrom] over a settings read, re-read at most every [fresh]: the
/// status cycle asks for it every 1.2 s per session.
class QuietThreshold {
  QuietThreshold({
    required this.readSettings,
    required this.now,
    this.overrideSeconds,
    this.fresh = const Duration(seconds: 30),
  });

  final String? Function() readSettings;
  final DateTime Function() now;
  final String? overrideSeconds;
  final Duration fresh;

  Duration? _value;
  DateTime? _readAt;

  Duration call() {
    final at = now();
    final readAt = _readAt;
    if (_value case final value?
        when readAt != null && at.difference(readAt) < fresh) {
      return value;
    }
    _readAt = at;
    return _value = quietAfterFrom(
      readSettings(),
      overrideSeconds: overrideSeconds,
    );
  }
}
