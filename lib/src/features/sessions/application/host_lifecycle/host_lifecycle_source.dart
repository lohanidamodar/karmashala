import 'package:karmashala_session_engine/karmashala_session_engine.dart';

/// One open link to a host's lifecycle feed: what it held when it answered,
/// then every change until the link ends.
class HostLifecycleFeed {
  HostLifecycleFeed({
    required this.snapshot,
    required this.events,
    required this.close,
  });

  final List<SessionFacts> snapshot;

  /// Ends when the link does, from either side.
  final Stream<SessionLifecycleEvent> events;

  /// Hangs up; the host's sessions are untouched.
  final Future<void> Function() close;
}

/// Where one host's lifecycle is read from. Injectable so a test never reaches
/// a real host.
abstract interface class HostLifecycleSource {
  /// Null when no host is listening. Throws when one answers but refuses to be
  /// watched.
  Future<HostLifecycleFeed?> open();
}
